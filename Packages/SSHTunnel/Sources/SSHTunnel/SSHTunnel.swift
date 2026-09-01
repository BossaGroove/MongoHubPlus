@preconcurrency import Citadel
import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// How the tunnel authenticates to the SSH host.
public enum SSHTunnelAuthentication: Sendable {
    case password(String)
    /// OpenSSH-format private key text (ed25519 or RSA), optional passphrase.
    case privateKey(openSSHKey: String, passphrase: String?)
}

public struct SSHTunnelConfiguration: Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var authentication: SSHTunnelAuthentication
    public var connectTimeoutSeconds: Int

    public init(
        host: String, port: Int = 22, username: String,
        authentication: SSHTunnelAuthentication, connectTimeoutSeconds: Int = 15
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.authentication = authentication
        self.connectTimeoutSeconds = connectTimeoutSeconds
    }
}

public struct SSHForwardTarget: Hashable, Sendable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    public var key: String { "\(host):\(port)" }
}

public struct SSHTunnelError: Error, CustomStringConvertible, Sendable {
    public let message: String

    init(_ message: String) { self.message = message }

    public var description: String { message }
}

/// A local port forwarder over SSH (replaces legacy MongoHub's
/// `/usr/bin/ssh -L` subprocess — feature-spec 2.8): one local listener per
/// target, each accepted connection piped through an SSH direct-tcpip
/// channel. Host keys are verified trust-on-first-use; the prompt callback
/// decides on unknown or changed keys.
public actor SSHTunnel {
    /// Asked to approve an unknown (`changed == false`) or changed
    /// (`changed == true`) host key. Return true to trust it.
    public typealias HostKeyPrompt = @Sendable (_ fingerprint: String, _ changed: Bool) async -> Bool

    private let configuration: SSHTunnelConfiguration
    private let prompt: HostKeyPrompt?
    private var trustedHostKey: Data?
    private var client: SSHClient?
    private var listeners: [Channel] = []
    private var reconnectAttempt = 0

    /// The host key approved during this session — persist it for TOFU.
    public private(set) var approvedHostKey: Data?

    public init(
        configuration: SSHTunnelConfiguration,
        knownHostKey: Data? = nil,
        onHostKeyPrompt: HostKeyPrompt? = nil
    ) {
        self.configuration = configuration
        self.prompt = onHostKeyPrompt
        self.trustedHostKey = knownHostKey
    }

    // MARK: - Lifecycle

    /// Connects (verifying the host key) and opens one local listener per
    /// target. Returns `"host:port" → local port`.
    public func start(forwarding targets: [SSHForwardTarget]) async throws -> [String: Int] {
        _ = try await ensureClient()

        var mapping: [String: Int] = [:]
        for target in targets {
            let listener = try await makeListener(for: target)
            listeners.append(listener)
            guard let port = listener.localAddress?.port else {
                throw SSHTunnelError("Could not determine the forwarded local port")
            }
            mapping[target.key] = port
        }
        return mapping
    }

    public func stop() async {
        for listener in listeners {
            try? await listener.close()
        }
        listeners.removeAll()
        let closing = client
        client = nil
        if let closing {
            try? await closing.close()
        }
    }

    // MARK: - SSH client (reconnect with backoff)

    private func ensureClient() async throws -> SSHClient {
        if let client { return client }

        var lastError: any Error = SSHTunnelError("Could not connect")
        for delay in [0.0, 0.5, 1.0, 2.0, 4.0] {
            if delay > 0 {
                try await Task.sleep(for: .seconds(delay))
            }
            do {
                let client = try await connectClient()
                self.client = client
                reconnectAttempt = 0
                return client
            } catch let error as HostKeyRejectedError {
                throw SSHTunnelError(error.message)  // never retry a rejected key
            } catch {
                lastError = error
            }
        }
        throw SSHTunnelError("SSH connection failed: \(lastError)")
    }

    private func connectClient() async throws -> SSHClient {
        let validator = TOFUHostKeyValidator(trusted: trustedHostKey, prompt: prompt)
        let client = try await SSHClient.connect(
            host: configuration.host,
            port: configuration.port,
            authenticationMethod: try Self.authenticationMethod(for: configuration),
            hostKeyValidator: .custom(validator),
            reconnect: .never,
            connectTimeout: .seconds(Int64(configuration.connectTimeoutSeconds))
        )
        if let approved = validator.approvedKey {
            trustedHostKey = approved
            approvedHostKey = approved
        }
        client.onDisconnect { [weak self] in
            Task { await self?.clientDisconnected() }
        }
        return client
    }

    private func clientDisconnected() {
        client = nil
    }

    static func authenticationMethod(
        for configuration: SSHTunnelConfiguration
    ) throws -> SSHAuthenticationMethod {
        switch configuration.authentication {
        case .password(let password):
            return .passwordBased(username: configuration.username, password: password)
        case .privateKey(let keyText, let passphrase):
            let decryptionKey = passphrase.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
            let type: SSHKeyType
            do {
                type = try SSHKeyDetection.detectPrivateKeyType(from: keyText)
            } catch {
                throw SSHTunnelError("Unrecognized private key format: \(error)")
            }
            switch type {
            case .ed25519:
                let key = try Curve25519.Signing.PrivateKey(
                    sshEd25519: keyText, decryptionKey: decryptionKey)
                return .ed25519(username: configuration.username, privateKey: key)
            case .rsa:
                let key = try Insecure.RSA.PrivateKey(
                    sshRsa: keyText, decryptionKey: decryptionKey)
                return .rsa(username: configuration.username, privateKey: key)
            default:
                throw SSHTunnelError(
                    "\(type) keys are not supported yet — use an ed25519 or RSA key")
            }
        }
    }

    // MARK: - Forwarding

    /// Opens an SSH direct-tcpip channel to `target`, piping it to `local`.
    fileprivate func openChannel(to target: SSHForwardTarget, pipingTo local: Channel) async throws -> Channel {
        func create(_ client: SSHClient) async throws -> Channel {
            try await client.createDirectTCPIPChannel(
                using: SSHChannelType.DirectTCPIP(
                    targetHost: target.host,
                    targetPort: target.port,
                    originatorAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 0))
            ) { channel in
                // Citadel already adds its SSHChannelData↔ByteBuffer codec.
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(PipeHandler(peer: local))
                }
            }
        }
        do {
            return try await create(try await ensureClient())
        } catch {
            // The client may have died since the listener was created —
            // reconnect once (with backoff) and retry.
            client = nil
            return try await create(try await ensureClient())
        }
    }

    private func makeListener(for target: SSHForwardTarget) async throws -> Channel {
        let tunnel = self
        return try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        LocalConnectionHandler(tunnel: tunnel, target: target))
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
    }
}

// MARK: - Channel plumbing

/// On accept: open the SSH channel, then wire both directions and start
/// reading (`autoRead` was off until the pipe exists).
private final class LocalConnectionHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let tunnel: SSHTunnel
    private let target: SSHForwardTarget

    init(tunnel: SSHTunnel, target: SSHForwardTarget) {
        self.tunnel = tunnel
        self.target = target
    }

    func channelActive(context: ChannelHandlerContext) {
        let local = context.channel
        let tunnel = tunnel
        let target = target
        Task {
            do {
                let ssh = try await tunnel.openChannel(to: target, pipingTo: local)
                try await local.eventLoop.submit {
                    try local.pipeline.syncOperations.addHandler(PipeHandler(peer: ssh))
                }.get()
                try await local.setOption(ChannelOptions.autoRead, value: true)
            } catch {
                local.close(promise: nil)
            }
        }
        context.fireChannelActive()
    }
}

/// One-directional byte pipe: everything read here is written to `peer`;
/// closing one side closes the other.
private final class PipeHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let peer: Channel

    init(peer: Channel) {
        self.peer = peer
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        peer.writeAndFlush(unwrapInboundIn(data), promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer.close(mode: .all, promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        peer.close(mode: .all, promise: nil)
        context.close(promise: nil)
    }
}

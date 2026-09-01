import Citadel
import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Testing

@testable import SSHTunnel

/// Fully hermetic: an in-process Citadel SSH server (password auth,
/// direct-tcpip enabled) plus an in-process TCP echo server as the target.
/// The tunnel forwards a local port through SSH to the echo server.
struct SSHTunnelTests {
    final class TestAuthDelegate: NIOSSHServerUserAuthenticationDelegate {
        let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .password

        func requestReceived(
            request: NIOSSHUserAuthenticationRequest,
            responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
        ) {
            if case .password(let payload) = request.request,
                request.username == "tester", payload.password == "secret"
            {
                responsePromise.succeed(.success)
            } else {
                responsePromise.succeed(.failure)
            }
        }
    }

    /// Echoes every received byte back.
    final class EchoHandler: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            context.writeAndFlush(data, promise: nil)
        }
    }

    static func startEchoServer() async throws -> Channel {
        try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(EchoHandler())
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
    }

    static func startSSHServer(port: Int) async throws -> SSHServer {
        let server = try await SSHServer.host(
            host: "127.0.0.1",
            port: port,
            hostKeys: [NIOSSHPrivateKey(ed25519Key: .init())],
            authenticationDelegate: TestAuthDelegate())
        server.enableDirectTCPIP(withDelegate: TestForwardingDelegate())
        return server
    }

    @Test func forwardsBytesEndToEnd() async throws {
        let echo = try await Self.startEchoServer()
        let echoPort = echo.localAddress!.port!
        let sshPort = 42_022
        let server = try await Self.startSSHServer(port: sshPort)

        let promptCalls = PromptRecorder()
        let tunnel = SSHTunnel(
            configuration: .init(
                host: "127.0.0.1", port: sshPort, username: "tester",
                authentication: .password("secret")),
            knownHostKey: nil,
            onHostKeyPrompt: { fingerprint, changed in
                await promptCalls.record(fingerprint: fingerprint, changed: changed)
                return true
            })

        let mapping = try await tunnel.start(forwarding: [
            SSHForwardTarget(host: "127.0.0.1", port: echoPort)
        ])
        let localPort = try #require(mapping["127.0.0.1:\(echoPort)"])

        // TOFU: unknown key prompted once, not flagged as changed.
        #expect(await promptCalls.calls.count == 1)
        #expect(await promptCalls.calls.first?.changed == false)
        #expect(await promptCalls.calls.first?.fingerprint.hasPrefix("SHA256:") == true)
        let approved = await tunnel.approvedHostKey
        #expect(approved != nil)

        // Round trip bytes through local port → SSH → echo server.
        let response = try await Self.sendAndReceive(
            port: localPort, payload: Data("hello through the tunnel".utf8))
        #expect(response == Data("hello through the tunnel".utf8))

        // Second connection through the same tunnel still works.
        let second = try await Self.sendAndReceive(port: localPort, payload: Data([0x00, 0xFF, 0x42]))
        #expect(second == Data([0x00, 0xFF, 0x42]))

        await tunnel.stop()

        // Reconnect with the stored key: no prompt this time.
        let tunnel2 = SSHTunnel(
            configuration: .init(
                host: "127.0.0.1", port: sshPort, username: "tester",
                authentication: .password("secret")),
            knownHostKey: approved,
            onHostKeyPrompt: { _, _ in
                await promptCalls.record(fingerprint: "unexpected", changed: false)
                return true
            })
        _ = try await tunnel2.start(forwarding: [
            SSHForwardTarget(host: "127.0.0.1", port: echoPort)
        ])
        #expect(await promptCalls.calls.count == 1)
        await tunnel2.stop()

        // A *changed* (wrong) stored key prompts with changed == true.
        let tunnel3 = SSHTunnel(
            configuration: .init(
                host: "127.0.0.1", port: sshPort, username: "tester",
                authentication: .password("secret")),
            knownHostKey: Data([1, 2, 3]),
            onHostKeyPrompt: { fingerprint, changed in
                await promptCalls.record(fingerprint: fingerprint, changed: changed)
                return false  // reject
            })
        await #expect(throws: SSHTunnelError.self) {
            _ = try await tunnel3.start(forwarding: [
                SSHForwardTarget(host: "127.0.0.1", port: echoPort)
            ])
        }
        #expect(await promptCalls.calls.last?.changed == true)
        await tunnel3.stop()

        try await server.close()
        try await echo.close()
    }

    @Test func rejectsBadCredentials() async throws {
        let sshPort = 42_023
        let server = try await Self.startSSHServer(port: sshPort)

        let tunnel = SSHTunnel(
            configuration: .init(
                host: "127.0.0.1", port: sshPort, username: "tester",
                authentication: .password("wrong")),
            onHostKeyPrompt: { _, _ in true })
        await #expect(throws: SSHTunnelError.self) {
            _ = try await tunnel.start(forwarding: [SSHForwardTarget(host: "127.0.0.1", port: 1)])
        }
        await tunnel.stop()
        try await server.close()
    }

    /// A correct server-side direct-tcpip forwarder for the test server
    /// (Citadel's demo DirectTCPIPForwardingDelegate mis-wires its proxies).
    struct TestForwardingDelegate: DirectTCPIPDelegate {
        /// The server child already carries Citadel's codec; inbound arrives
        /// as IOData and writes take ByteBuffer.
        final class SSHSidePipe: ChannelInboundHandler {
            typealias InboundIn = IOData
            let peer: Channel
            init(peer: Channel) { self.peer = peer }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                if case .byteBuffer(let buffer) = unwrapInboundIn(data) {
                    peer.writeAndFlush(buffer, promise: nil)
                }
            }

            func channelInactive(context: ChannelHandlerContext) {
                peer.close(mode: .all, promise: nil)
                context.fireChannelInactive()
            }
        }

        final class RemoteSidePipe: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer
            let peer: Channel
            init(peer: Channel) { self.peer = peer }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                peer.writeAndFlush(unwrapInboundIn(data), promise: nil)
            }

            func channelInactive(context: ChannelHandlerContext) {
                peer.close(mode: .all, promise: nil)
                context.fireChannelInactive()
            }
        }

        func initializeDirectTCPIPChannel(
            _ channel: Channel, request: SSHChannelType.DirectTCPIP, context: SSHContext
        ) -> EventLoopFuture<Void> {
            ClientBootstrap(group: channel.eventLoop)
                .connect(host: request.targetHost, port: request.targetPort)
                .flatMap { remote in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(SSHSidePipe(peer: remote))
                        try remote.pipeline.syncOperations.addHandler(RemoteSidePipe(peer: channel))
                    }
                }
        }
    }

    // MARK: - Helpers

    actor PromptRecorder {
        struct Call {
            let fingerprint: String
            let changed: Bool
        }
        private(set) var calls: [Call] = []

        func record(fingerprint: String, changed: Bool) {
            calls.append(Call(fingerprint: fingerprint, changed: changed))
        }
    }

    /// Collects exactly `payload.count` echoed bytes.
    final class CollectHandler: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        private let expected: Int
        private let promise: EventLoopPromise<Data>
        private var received = Data()

        init(expected: Int, promise: EventLoopPromise<Data>) {
            self.expected = expected
            self.promise = promise
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data)
            if let bytes = buffer.readData(length: buffer.readableBytes) {
                received.append(bytes)
            }
            if received.count >= expected {
                promise.succeed(received)
            }
        }

        func errorCaught(context: ChannelHandlerContext, error: any Error) {
            promise.fail(error)
        }
    }

    static func sendAndReceive(port: Int, payload: Data) async throws -> Data {
        let group = MultiThreadedEventLoopGroup.singleton
        let promise = group.next().makePromise(of: Data.self)
        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        CollectHandler(expected: payload.count, promise: promise))
                }
            }
            .connect(host: "127.0.0.1", port: port)
            .get()
        var buffer = channel.allocator.buffer(capacity: payload.count)
        buffer.writeBytes(payload)
        try await channel.writeAndFlush(buffer)
        let result = try await withTimeout(seconds: 10) {
            try await promise.futureResult.get()
        }
        try? await channel.close()
        return result
    }

    static func withTimeout<T: Sendable>(
        seconds: Int, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw SSHTunnelError("Timed out")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

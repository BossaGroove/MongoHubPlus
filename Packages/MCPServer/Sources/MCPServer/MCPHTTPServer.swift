import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix

public enum MCPServerError: Error, Equatable, CustomStringConvertible {
    case portInUse(Int)
    case bindFailed(String)

    public var description: String {
        switch self {
        case .portInUse(let port): return "Port \(port) is already in use."
        case .bindFailed(let reason): return reason
        }
    }
}

/// Serves an `MCPEndpoint` over HTTP on the loopback interface.
///
/// One request per connection (`Connection: close`): a stopped server then
/// has no kept-alive connection left that could still be answered.
public final class MCPHTTPServer: Sendable {
    /// Requests bigger than this are refused with 413 before they reach the
    /// endpoint.
    public static let maxBodyBytes = 1 << 20

    /// The port actually bound (useful when asked for port 0).
    public let port: Int

    private typealias Connection = NIOAsyncChannel<NIOHTTPServerRequestFull, HTTPServerResponsePart>

    private let serverChannel: NIOAsyncChannel<Connection, Never>
    private let stopped = NIOLockedValueBox(false)
    private let runTask = NIOLockedValueBox<Task<Void, Never>?>(nil)

    private init(serverChannel: NIOAsyncChannel<Connection, Never>, port: Int) {
        self.serverChannel = serverChannel
        self.port = port
    }

    /// Binds to `host:port` (port 0 picks a free one) and starts answering.
    /// `makeEndpoint` receives the bound port.
    public static func start(
        host: String = "127.0.0.1", port: Int,
        makeEndpoint: @Sendable (_ boundPort: Int) -> MCPEndpoint
    ) async throws -> MCPHTTPServer {
        let serverChannel: NIOAsyncChannel<Connection, Never>
        do {
            serverChannel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .bind(host: host, port: port) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                        try channel.pipeline.syncOperations.addHandler(
                            NIOHTTPServerRequestAggregator(maxContentLength: maxBodyBytes))
                        return try Connection(wrappingChannelSynchronously: channel)
                    }
                }
        } catch let error as IOError where error.errnoCode == EADDRINUSE {
            throw MCPServerError.portInUse(port)
        } catch {
            throw MCPServerError.bindFailed(String(describing: error))
        }

        let boundPort = serverChannel.channel.localAddress?.port ?? port
        let server = MCPHTTPServer(serverChannel: serverChannel, port: boundPort)
        let endpoint = makeEndpoint(boundPort)
        let task = Task { [server] in
            await server.acceptLoop(endpoint)
        }
        server.runTask.withLockedValue { $0 = task }
        return server
    }

    /// Stops accepting connections. A request already being answered
    /// finishes; any request after this gets 503.
    public func stop() async {
        stopped.withLockedValue { $0 = true }
        try? await serverChannel.channel.close()
        runTask.withLockedValue { $0 }?.cancel()
    }

    private func acceptLoop(_ endpoint: MCPEndpoint) async {
        await withDiscardingTaskGroup { group in
            do {
                try await serverChannel.executeThenClose { inbound in
                    for try await connection in inbound {
                        group.addTask { [self] in
                            await serve(connection, endpoint)
                        }
                    }
                }
            } catch {
                // The server channel closed (stop) or failed; either way
                // there is nothing left to accept.
            }
        }
    }

    private func serve(_ connection: Connection, _ endpoint: MCPEndpoint) async {
        do {
            try await connection.executeThenClose { inbound, outbound in
                for try await request in inbound {
                    let response: MCPHTTPResponse
                    if stopped.withLockedValue({ $0 }) {
                        response = MCPHTTPResponse(status: 503)
                    } else {
                        response = await endpoint.respond(
                            to: MCPHTTPRequest(
                                method: request.head.method.rawValue,
                                target: request.head.uri,
                                headers: request.head.headers.map { ($0.name, $0.value) },
                                body: request.body.map { Data($0.readableBytesView) } ?? Data()))
                    }

                    var headers = HTTPHeaders()
                    for (name, value) in response.headers.sorted(by: { $0.key < $1.key }) {
                        headers.add(name: name, value: value)
                    }
                    headers.replaceOrAdd(name: "Content-Length", value: "\(response.body.count)")
                    headers.replaceOrAdd(name: "Connection", value: "close")
                    try await outbound.write(
                        .head(
                            HTTPResponseHead(
                                version: request.head.version,
                                status: HTTPResponseStatus(statusCode: response.status),
                                headers: headers)))
                    if !response.body.isEmpty {
                        try await outbound.write(
                            .body(.byteBuffer(ByteBuffer(bytes: response.body))))
                    }
                    try await outbound.write(.end(nil))
                    break
                }
            }
        } catch {
            // The client went away mid-request; nothing to answer.
        }
    }
}

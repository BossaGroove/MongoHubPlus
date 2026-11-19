import Foundation
import Testing

@testable import MCPServer

/// Real sockets on the loopback interface.
@Suite("MCP HTTP server", .serialized)
struct MCPHTTPServerTests {
    private static let token = "socket-test-token"

    private static func startServer(port: Int = 0) async throws -> MCPHTTPServer {
        try await MCPHTTPServer.start(port: port) { boundPort in
            MCPEndpoint(
                port: boundPort, token: token,
                dispatcher: MCPDispatcher(serverName: "S", serverVersion: "1", tools: []))
        }
    }

    private static func post(
        _ body: Data, to port: Int, token: String = token
    ) async throws -> (Int, Data) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        let (data, response) = try await URLSession(configuration: configuration).data(
            for: request)
        return ((response as! HTTPURLResponse).statusCode, data)
    }

    @Test func answersOverARealSocket() async throws {
        let server = try await Self.startServer()
        #expect(server.port > 0)
        let (status, data) = try await Self.post(
            Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8), to: server.port)
        #expect(status == 200)
        #expect(try JSONValue.decode(data) == ["jsonrpc": "2.0", "id": 1, "result": [:]])

        // A second request on a new connection works too.
        let (again, _) = try await Self.post(
            Data(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#.utf8), to: server.port)
        #expect(again == 200)
        await server.stop()
    }

    @Test func rejectsAWrongTokenOverARealSocket() async throws {
        let server = try await Self.startServer()
        let (status, _) = try await Self.post(
            Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8), to: server.port,
            token: "wrong")
        #expect(status == 401)
        await server.stop()
    }

    @Test func refusesAnOversizedBody() async throws {
        let server = try await Self.startServer()
        let body = Data(repeating: UInt8(ascii: " "), count: MCPHTTPServer.maxBodyBytes + 1)
        // The server answers 413 and closes the connection, usually while the
        // client is still uploading, so the client may see a reset instead of
        // the status. Either way the request is refused.
        do {
            let (status, _) = try await Self.post(body, to: server.port)
            #expect(status == 413)
        } catch let error as URLError {
            #expect(error.code == .networkConnectionLost)
        }
        await server.stop()
    }

    @Test func stopsListening() async throws {
        let server = try await Self.startServer()
        let port = server.port
        await server.stop()
        await #expect(throws: (any Error).self) {
            _ = try await Self.post(
                Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8), to: port)
        }
    }

    @Test func reportsAPortInUse() async throws {
        let first = try await Self.startServer()
        await #expect(throws: MCPServerError.portInUse(first.port)) {
            _ = try await Self.startServer(port: first.port)
        }
        await first.stop()
    }
}

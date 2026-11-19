import Foundation
import Testing

@testable import MCPServer

private let echoTool = MCPTool(
    name: "echo", title: "Echo", description: "Returns its arguments.",
    inputSchema: ["type": "object"], readOnly: true,
    run: { arguments in
        .success(String(decoding: JSONValue.object(arguments).encoded(), as: UTF8.self))
    }
)

private let failingTool = MCPTool(
    name: "fail", title: "Fail", description: "Always fails.",
    inputSchema: ["type": "object"], readOnly: false,
    run: { _ in .failure("it broke") }
)

private func dispatcher() -> MCPDispatcher {
    MCPDispatcher(
        serverName: "Test Server", serverVersion: "1.2.3", instructions: "Be careful.",
        tools: [echoTool, failingTool])
}

private func send(_ json: String, to dispatcher: MCPDispatcher = dispatcher()) async throws
    -> JSONValue?
{
    guard let data = await dispatcher.handle(body: Data(json.utf8)) else { return nil }
    return try JSONValue.decode(data)
}

@Suite("MCP dispatcher")
struct MCPDispatcherTests {
    @Test func initializeAgreesOnASupportedVersion() async throws {
        let response = try #require(
            await send(
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-code","version":"2.1"}}}"#
            ))
        #expect(response["id"] == 1)
        let result = try #require(response["result"])
        #expect(result["protocolVersion"] == "2025-06-18")
        #expect(result["serverInfo"] == ["name": "Test Server", "version": "1.2.3"])
        #expect(result["capabilities"] == ["tools": ["listChanged": false]])
        #expect(result["instructions"] == "Be careful.")
    }

    @Test func initializeOffersTheNewestVersionForAnUnknownOne() async throws {
        let response = try #require(
            await send(
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#
            ))
        #expect(
            response["result"]?["protocolVersion"]
                == .string(MCPDispatcher.supportedProtocolVersions[0]))
    }

    @Test func initializeLogsTheClient() async throws {
        let events = LockedEvents()
        let dispatcher = MCPDispatcher(
            serverName: "S", serverVersion: "1", tools: [], log: { events.append($0) })
        _ = try await send(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"claude-code","version":"2.1"}}}"#,
            to: dispatcher)
        #expect(
            events.all == [MCPLogEvent(.info, "claude-code 2.1 connected (protocol 2025-06-18)")])
    }

    @Test func notificationsGetNoResponse() async throws {
        #expect(try await send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
    }

    @Test func clientResponsesGetNoResponse() async throws {
        #expect(try await send(#"{"jsonrpc":"2.0","id":7,"result":{}}"#) == nil)
    }

    @Test func pingAnswersEmpty() async throws {
        let response = try #require(await send(#"{"jsonrpc":"2.0","id":"a","method":"ping"}"#))
        #expect(response == ["jsonrpc": "2.0", "id": "a", "result": [:]])
    }

    @Test func toolsListDescribesEveryTool() async throws {
        let response = try #require(await send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        let tools = try #require(response["result"]?["tools"])
        #expect(
            tools == [
                [
                    "name": "echo", "title": "Echo", "description": "Returns its arguments.",
                    "inputSchema": ["type": "object"],
                    "annotations": ["title": "Echo", "readOnlyHint": true],
                ],
                [
                    "name": "fail", "title": "Fail", "description": "Always fails.",
                    "inputSchema": ["type": "object"],
                    "annotations": ["title": "Fail", "readOnlyHint": false],
                ],
            ])
    }

    @Test func toolsCallRunsTheToolWithItsArguments() async throws {
        let response = try #require(
            await send(
                #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"x":1}}}"#
            ))
        #expect(
            response["result"]
                == ["content": [["type": "text", "text": #"{"x":1}"#]], "isError": false])
    }

    @Test func toolsCallWithoutArgumentsPassesAnEmptyObject() async throws {
        let response = try #require(
            await send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo"}}"#))
        #expect(response["result"]?["content"] == [["type": "text", "text": "{}"]])
    }

    @Test func aFailingToolIsAResultNotAProtocolError() async throws {
        let response = try #require(
            await send(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"fail"}}"#))
        #expect(
            response["result"]
                == ["content": [["type": "text", "text": "it broke"]], "isError": true])
        #expect(response["error"] == nil)
    }

    @Test func anUnknownToolIsInvalidParams() async throws {
        let response = try #require(
            await send(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"nope"}}"#))
        #expect(response["error"] == ["code": -32602, "message": "Unknown tool: nope"])
    }

    @Test func nonObjectArgumentsAreInvalidParams() async throws {
        let response = try #require(
            await send(
                #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"echo","arguments":[1]}}"#
            ))
        #expect(response["error"]?["code"] == -32602)
    }

    @Test func anUnknownMethodIsMethodNotFound() async throws {
        let response = try #require(
            await send(#"{"jsonrpc":"2.0","id":6,"method":"resources/list"}"#))
        #expect(
            response["error"] == ["code": -32601, "message": "Method not found: resources/list"])
    }

    @Test func malformedJSONIsAParseError() async throws {
        let response = try #require(await send("{not json"))
        #expect(response["id"] == .null)
        #expect(response["error"]?["code"] == -32700)
    }

    @Test func aMissingVersionIsAnInvalidRequest() async throws {
        let response = try #require(await send(#"{"id":1,"method":"ping"}"#))
        #expect(response["id"] == 1)
        #expect(response["error"]?["code"] == -32600)
    }

    @Test func aNullIdIsAnInvalidRequest() async throws {
        let response = try #require(await send(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#))
        #expect(response["error"]?["code"] == -32600)
    }

    @Test func aBatchAnswersOnlyItsRequests() async throws {
        let response = try #require(
            await send(
                #"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"}]"#
            ))
        #expect(response == [["jsonrpc": "2.0", "id": 1, "result": [:]]])
    }

    @Test func aBatchOfNotificationsGetsNoResponse() async throws {
        #expect(
            try await send(#"[{"jsonrpc":"2.0","method":"notifications/initialized"}]"#) == nil)
    }

    @Test func anEmptyBatchIsAnInvalidRequest() async throws {
        let response = try #require(await send("[]"))
        #expect(response["error"]?["code"] == -32600)
    }
}

final class LockedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [MCPLogEvent] = []

    func append(_ event: MCPLogEvent) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }

    var all: [MCPLogEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

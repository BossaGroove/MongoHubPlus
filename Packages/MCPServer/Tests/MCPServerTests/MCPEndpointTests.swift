import Foundation
import Testing

@testable import MCPServer

private let token = "test-token-123"
private let ping = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)

private func endpoint(log: @escaping @Sendable (MCPLogEvent) -> Void = { _ in }) -> MCPEndpoint {
    MCPEndpoint(
        port: 47017, token: token,
        dispatcher: MCPDispatcher(serverName: "S", serverVersion: "1", tools: [], log: log))
}

private func request(
    method: String = "POST", target: String = "/mcp", body: Data = ping,
    _ overrides: [String: String?] = [:]
) -> MCPHTTPRequest {
    var headers: [String: String] = [
        "Host": "127.0.0.1:47017",
        "Authorization": "Bearer \(token)",
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    ]
    for (name, value) in overrides {
        headers[name] = value
    }
    return MCPHTTPRequest(
        method: method, target: target, headers: headers.map { ($0.key, $0.value) }, body: body)
}

@Suite("MCP endpoint")
struct MCPEndpointTests {
    @Test func anAuthorizedPostIsAnswered() async throws {
        let response = await endpoint().respond(to: request())
        #expect(response.status == 200)
        #expect(response.headers["Content-Type"] == "application/json")
        #expect(try JSONValue.decode(response.body) == ["jsonrpc": "2.0", "id": 1, "result": [:]])
    }

    @Test func localhostIsAcceptedAsTheHost() async {
        let response = await endpoint().respond(to: request(["Host": "localhost:47017"]))
        #expect(response.status == 200)
    }

    @Test func theBearerSchemeIsCaseInsensitive() async {
        let response = await endpoint().respond(to: request(["Authorization": "bearer \(token)"]))
        #expect(response.status == 200)
    }

    @Test func aNotificationIsAccepted() async {
        let body = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        let response = await endpoint().respond(to: request(body: body))
        #expect(response.status == 202)
        #expect(response.body.isEmpty)
    }

    @Test func aMissingTokenIsUnauthorized() async {
        let events = LockedEvents()
        let response = await endpoint(log: { events.append($0) })
            .respond(to: request(["Authorization": nil]))
        #expect(response.status == 401)
        #expect(response.headers["WWW-Authenticate"] != nil)
        #expect(events.all.map(\.level) == [.warning])
    }

    @Test func aWrongTokenIsUnauthorized() async {
        let response = await endpoint().respond(to: request(["Authorization": "Bearer nope"]))
        #expect(response.status == 401)
    }

    @Test func anotherSchemeIsUnauthorized() async {
        let response = await endpoint().respond(to: request(["Authorization": "Basic \(token)"]))
        #expect(response.status == 401)
    }

    @Test func anotherPathIsNotFound() async {
        let response = await endpoint().respond(to: request(target: "/other"))
        #expect(response.status == 404)
    }

    @Test func aQueryStringIsIgnored() async {
        let response = await endpoint().respond(to: request(target: "/mcp?x=1"))
        #expect(response.status == 200)
    }

    @Test func aForeignHostIsForbidden() async {
        // DNS rebinding: a page on evil.example resolved to 127.0.0.1.
        let response = await endpoint().respond(to: request(["Host": "evil.example:47017"]))
        #expect(response.status == 403)
    }

    @Test func anotherPortInTheHostIsForbidden() async {
        let response = await endpoint().respond(to: request(["Host": "127.0.0.1:80"]))
        #expect(response.status == 403)
    }

    @Test func aMissingHostIsForbidden() async {
        let response = await endpoint().respond(to: request(["Host": nil]))
        #expect(response.status == 403)
    }

    @Test func aForeignOriginIsForbidden() async {
        let response = await endpoint().respond(to: request(["Origin": "https://evil.example"]))
        #expect(response.status == 403)
    }

    @Test func aLocalOriginIsAllowed() async {
        let response = await endpoint().respond(to: request(["Origin": "http://127.0.0.1:47017"]))
        #expect(response.status == 200)
    }

    @Test func getIsNotAllowed() async {
        let response = await endpoint().respond(to: request(method: "GET", body: Data()))
        #expect(response.status == 405)
        #expect(response.headers["Allow"] == "POST")
    }

    @Test func authorizationIsCheckedBeforeTheMethod() async {
        let response = await endpoint().respond(
            to: request(method: "GET", body: Data(), ["Authorization": nil]))
        #expect(response.status == 401)
    }

    @Test func anUnsupportedProtocolVersionHeaderIsABadRequest() async {
        let response = await endpoint().respond(to: request(["MCP-Protocol-Version": "1999-01-01"]))
        #expect(response.status == 400)
    }

    @Test func aSupportedProtocolVersionHeaderIsAccepted() async {
        let response = await endpoint().respond(to: request(["MCP-Protocol-Version": "2025-06-18"]))
        #expect(response.status == 200)
    }

    @Test func constantTimeEqualMatchesOnlyIdenticalStrings() {
        #expect(MCPEndpoint.constantTimeEqual("abc", "abc"))
        #expect(!MCPEndpoint.constantTimeEqual("abc", "abd"))
        #expect(!MCPEndpoint.constantTimeEqual("abc", "abcd"))
        #expect(!MCPEndpoint.constantTimeEqual("", "a"))
    }
}

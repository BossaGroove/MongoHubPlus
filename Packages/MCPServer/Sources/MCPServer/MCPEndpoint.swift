import Foundation

/// An HTTP request as the endpoint sees it, independent of the networking
/// library.
public struct MCPHTTPRequest: Sendable {
    public var method: String
    /// The request target: path plus any query.
    public var target: String
    public var headers: [(name: String, value: String)]
    public var body: Data

    public init(
        method: String, target: String, headers: [(name: String, value: String)], body: Data
    ) {
        self.method = method
        self.target = target
        self.headers = headers
        self.body = body
    }

    /// First value of a header, matched case-insensitively.
    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public struct MCPHTTPResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// The MCP Streamable HTTP endpoint: checks who is asking, then hands the
/// body to the dispatcher.
///
/// Only POST is served, and every answer is a single JSON response; the
/// optional server-to-client event stream (GET) isn't offered.
public struct MCPEndpoint: Sendable {
    public static let path = "/mcp"

    /// The port the server is bound to; the Host and Origin checks need it.
    public var port: Int
    public var token: String
    public var dispatcher: MCPDispatcher

    public init(port: Int, token: String, dispatcher: MCPDispatcher) {
        self.port = port
        self.token = token
        self.dispatcher = dispatcher
    }

    public func respond(to request: MCPHTTPRequest) async -> MCPHTTPResponse {
        let path = request.target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        guard path == Self.path else {
            return reject(404, "Not found. The MCP endpoint is \(Self.path).")
        }

        // DNS-rebinding protection (required by the MCP spec for local
        // servers): a web page that resolves its own domain to 127.0.0.1
        // still sends its own Host and Origin.
        let localOrigins = ["127.0.0.1:\(port)", "localhost:\(port)"]
        guard let host = request.header("Host"), localOrigins.contains(host.lowercased()) else {
            return reject(403, "Forbidden host", log: "Rejected a request with a foreign Host")
        }
        if let origin = request.header("Origin"),
            !localOrigins.map({ "http://\($0)" }).contains(origin.lowercased())
        {
            return reject(403, "Forbidden origin", log: "Rejected a request from \(origin)")
        }

        guard let authorization = request.header("Authorization"),
            let presented = Self.bearerToken(authorization),
            Self.constantTimeEqual(presented, token)
        else {
            return MCPHTTPResponse(
                status: 401,
                headers: [
                    "Content-Type": "application/json",
                    "WWW-Authenticate": #"Bearer realm="MongoHub Plus""#,
                ],
                body: errorBody(
                    "Missing or wrong token. Copy the command from MongoHub Plus Settings ▸ MCP again."
                )
            ).logged(dispatcher, "Rejected a request with a missing or wrong token")
        }

        guard request.method == "POST" else {
            return MCPHTTPResponse(
                status: 405, headers: ["Allow": "POST", "Content-Type": "application/json"],
                body: errorBody("Method not allowed"))
        }

        if let version = request.header("MCP-Protocol-Version"),
            !MCPDispatcher.supportedProtocolVersions.contains(version)
        {
            return reject(400, "Unsupported MCP protocol version: \(version)")
        }

        guard let body = await dispatcher.handle(body: request.body) else {
            return MCPHTTPResponse(status: 202)
        }
        return MCPHTTPResponse(
            status: 200, headers: ["Content-Type": "application/json"], body: body)
    }

    private func reject(_ status: Int, _ message: String, log: String? = nil) -> MCPHTTPResponse {
        let response = MCPHTTPResponse(
            status: status, headers: ["Content-Type": "application/json"],
            body: errorBody(message))
        guard let log else { return response }
        return response.logged(dispatcher, log)
    }

    private func errorBody(_ message: String) -> Data {
        MCPDispatcher.errorResponse(id: .null, code: -32000, message: message).encoded()
    }

    static func bearerToken(_ authorization: String) -> String? {
        let parts = authorization.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].caseInsensitiveCompare("Bearer") == .orderedSame else {
            return nil
        }
        return parts[1].trimmingCharacters(in: .whitespaces)
    }

    /// Compares without returning early, so the time taken doesn't reveal
    /// how much of a guessed token was right.
    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let a = Array(a.utf8)
        let b = Array(b.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices {
            difference |= a[index] ^ b[index]
        }
        return difference == 0
    }
}

extension MCPHTTPResponse {
    fileprivate func logged(_ dispatcher: MCPDispatcher, _ message: String) -> MCPHTTPResponse {
        dispatcher.log(MCPLogEvent(.warning, message))
        return self
    }
}

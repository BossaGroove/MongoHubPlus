import Foundation

/// One tool the server offers. The app defines the tools; this package only
/// lists and calls them.
public struct MCPTool: Sendable {
    public var name: String
    /// Human-readable name, shown by clients that support it.
    public var title: String
    public var description: String
    /// JSON Schema for the arguments object.
    public var inputSchema: JSONValue
    /// Sent as the `readOnlyHint` annotation.
    public var readOnly: Bool
    public var run: @Sendable (_ arguments: [String: JSONValue]) async -> MCPToolResult

    public init(
        name: String, title: String, description: String, inputSchema: JSONValue,
        readOnly: Bool,
        run: @escaping @Sendable (_ arguments: [String: JSONValue]) async -> MCPToolResult
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.readOnly = readOnly
        self.run = run
    }
}

/// What a tool call returns: one text block. `isError` marks a failure the
/// model should see and can react to (as opposed to a protocol error).
public struct MCPToolResult: Sendable, Equatable {
    public var text: String
    public var isError: Bool

    public static func success(_ text: String) -> MCPToolResult {
        MCPToolResult(text: text, isError: false)
    }

    public static func failure(_ text: String) -> MCPToolResult {
        MCPToolResult(text: text, isError: true)
    }
}

/// Activity the server reports to the app's log.
public struct MCPLogEvent: Sendable, Equatable {
    public enum Level: String, Sendable {
        case info, warning
    }

    public var level: Level
    public var message: String

    public init(_ level: Level, _ message: String) {
        self.level = level
        self.message = message
    }
}

/// JSON-RPC 2.0 message handling for MCP, independent of the transport:
/// takes a request body, returns a response body.
///
/// Stateless: no sessions, nothing remembered between requests. The tool
/// list is fixed for the server's lifetime.
public struct MCPDispatcher: Sendable {
    /// Newest first. A client asking for one of these gets it back; any
    /// other request gets the newest, and the client decides whether to
    /// continue.
    public static let supportedProtocolVersions = [
        "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05",
    ]

    public var serverName: String
    public var serverVersion: String
    public var instructions: String?
    public var tools: [MCPTool]
    public var log: @Sendable (MCPLogEvent) -> Void

    public init(
        serverName: String, serverVersion: String, instructions: String? = nil,
        tools: [MCPTool], log: @escaping @Sendable (MCPLogEvent) -> Void = { _ in }
    ) {
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.instructions = instructions
        self.tools = tools
        self.log = log
    }

    /// Returns the response body, or nil when nothing is owed (the body held
    /// only notifications or client responses).
    public func handle(body: Data) async -> Data? {
        let message: JSONValue
        do {
            message = try JSONValue.decode(body)
        } catch {
            return Self.errorResponse(id: .null, code: -32700, message: "Parse error").encoded()
        }

        switch message {
        case .array(let batch):
            // Batches were removed in protocol 2025-06-18 but are still
            // valid for 2025-03-26 clients.
            guard !batch.isEmpty else {
                return Self.errorResponse(id: .null, code: -32600, message: "Empty batch")
                    .encoded()
            }
            var responses: [JSONValue] = []
            for element in batch {
                if let response = await handle(message: element) {
                    responses.append(response)
                }
            }
            return responses.isEmpty ? nil : JSONValue.array(responses).encoded()
        case .object:
            return await handle(message: message)?.encoded()
        default:
            return Self.errorResponse(id: .null, code: -32600, message: "Invalid request")
                .encoded()
        }
    }

    private func handle(message: JSONValue) async -> JSONValue? {
        guard let object = message.objectValue else {
            return Self.errorResponse(id: .null, code: -32600, message: "Invalid request")
        }
        let id = object["id"]
        guard object["jsonrpc"] == "2.0" else {
            return Self.errorResponse(id: id ?? .null, code: -32600, message: "Invalid request")
        }
        guard let method = object["method"]?.stringValue else {
            // A response to a server request. This server never sends any.
            return nil
        }
        guard let id else {
            // A notification (initialized, cancelled, …): nothing to answer.
            return nil
        }
        switch id {
        case .string, .int: break
        default:
            return Self.errorResponse(
                id: .null, code: -32600, message: "Request id must be a string or a number")
        }

        let params = object["params"]?.objectValue ?? [:]
        switch method {
        case "initialize":
            return Self.resultResponse(id: id, result: initialize(params))
        case "ping":
            return Self.resultResponse(id: id, result: [:])
        case "tools/list":
            return Self.resultResponse(id: id, result: ["tools": .array(tools.map(Self.describe))])
        case "tools/call":
            return await callTool(id: id, params: params)
        default:
            return Self.errorResponse(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func initialize(_ params: [String: JSONValue]) -> JSONValue {
        let requested = params["protocolVersion"]?.stringValue
        let version =
            requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil }
            ?? Self.supportedProtocolVersions[0]
        let client = params["clientInfo"]
        let clientName = client?["name"]?.stringValue ?? "unknown client"
        let clientVersion = client?["version"]?.stringValue.map { " \($0)" } ?? ""
        log(MCPLogEvent(.info, "\(clientName)\(clientVersion) connected (protocol \(version))"))

        var result: [String: JSONValue] = [
            "protocolVersion": .string(version),
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": .string(serverName), "version": .string(serverVersion)],
        ]
        if let instructions {
            result["instructions"] = .string(instructions)
        }
        return .object(result)
    }

    private func callTool(id: JSONValue, params: [String: JSONValue]) async -> JSONValue {
        guard let name = params["name"]?.stringValue else {
            return Self.errorResponse(id: id, code: -32602, message: "Missing tool name")
        }
        guard let tool = tools.first(where: { $0.name == name }) else {
            log(MCPLogEvent(.warning, "Unknown tool requested: \(name)"))
            return Self.errorResponse(id: id, code: -32602, message: "Unknown tool: \(name)")
        }
        let arguments: [String: JSONValue]
        switch params["arguments"] {
        case nil, .null?: arguments = [:]
        case .object(let object)?: arguments = object
        default:
            return Self.errorResponse(
                id: id, code: -32602, message: "Tool arguments must be an object")
        }

        log(MCPLogEvent(.info, "Tool call: \(name)"))
        let result = await tool.run(arguments)
        if result.isError {
            log(MCPLogEvent(.warning, "Tool \(name) failed: \(result.text)"))
        }
        return Self.resultResponse(
            id: id,
            result: [
                "content": [["type": "text", "text": .string(result.text)]],
                "isError": .bool(result.isError),
            ])
    }

    private static func describe(_ tool: MCPTool) -> JSONValue {
        [
            "name": .string(tool.name),
            "title": .string(tool.title),
            "description": .string(tool.description),
            "inputSchema": tool.inputSchema,
            "annotations": ["title": .string(tool.title), "readOnlyHint": .bool(tool.readOnly)],
        ]
    }

    static func resultResponse(id: JSONValue, result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func errorResponse(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .int(code), "message": .string(message)]]
    }
}

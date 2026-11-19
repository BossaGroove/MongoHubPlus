import Foundation
import MCPServer

/// The tools the MCP server offers, added one at a time (internal
/// mcp-tools.md). Every tool runs its app work on the main actor.
enum MCPTools {
    static let all: [MCPTool] = [listConnections]

    // MARK: - list_connections

    private struct ConnectionSummary: Sendable {
        let id: UUID
        let name: String
        let type: String
        let access: String
    }

    static let listConnections = MCPTool(
        name: "list_connections",
        title: "List connections",
        description: """
            Lists the connections saved in MongoHub Plus, in the order the app shows them. \
            Each has an id, a name, a type (standalone, replicaSet, shardedCluster, srv for a \
            DNS seed list as Atlas uses, or connectionString) and access: what the user lets \
            assistants do with it. access is off (no tool can use the connection), readOnly, \
            or readWrite (reads and inserts; updates and deletes only ever become pending \
            actions the user applies in the app). Only the user can change access, in the \
            app's connection editor. Hosts, connection strings and passwords are never \
            included.
            """,
        inputSchema: [
            "type": "object",
            "properties": [:],
            "additionalProperties": false,
        ],
        readOnly: true,
        run: { _ in
            let connections = await MainActor.run {
                ConnectionStore.shared.connections.map {
                    ConnectionSummary(
                        id: $0.id, name: $0.alias, type: $0.kind.rawValue,
                        access: $0.effectiveAssistantAccess.rawValue)
                }
            }
            let result: JSONValue = [
                "connections": .array(
                    connections.map {
                        [
                            "id": .string($0.id.uuidString),
                            "name": .string($0.name),
                            "type": .string($0.type),
                            "access": .string($0.access),
                        ]
                    })
            ]
            return .success(String(decoding: result.encoded(pretty: true), as: UTF8.self))
        })
}

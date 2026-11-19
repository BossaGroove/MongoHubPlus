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
    }

    static let listConnections = MCPTool(
        name: "list_connections",
        title: "List connections",
        description: """
            Lists the connections saved in MongoHub Plus, in the order the app shows them. \
            Each has an id, a name and a type: standalone, replicaSet, shardedCluster, srv \
            (a DNS seed list, as Atlas uses) or connectionString. Hosts, connection strings \
            and passwords are never included.
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
                    ConnectionSummary(id: $0.id, name: $0.alias, type: $0.kind.rawValue)
                }
            }
            let result: JSONValue = [
                "connections": .array(
                    connections.map {
                        [
                            "id": .string($0.id.uuidString),
                            "name": .string($0.name),
                            "type": .string($0.type),
                        ]
                    })
            ]
            return .success(String(decoding: result.encoded(pretty: true), as: UTF8.self))
        })
}

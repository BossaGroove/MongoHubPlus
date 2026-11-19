import BSON
import Foundation
import MCPServer

/// The tools the MCP server offers, added one at a time (internal
/// mcp-tools.md). Every tool runs its app work on the main actor; tools
/// that touch a database go through `MCPConnections`, which checks the
/// connection's AI Access first.
enum MCPTools {
    static let all: [MCPTool] = [listConnections, listDatabases]

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

    // MARK: - list_databases

    static let listDatabases = MCPTool(
        name: "list_databases",
        title: "List databases",
        description: """
            Lists the databases on one of the user's saved connections, with each one's size \
            on disk in bytes and whether it is empty. The connection's access must be readOnly \
            or readWrite. A database user without the right to list every database gets only \
            the databases it may use.
            """,
        inputSchema: [
            "type": "object",
            "properties": ["connection": MCPConnections.connectionArgumentSchema],
            "required": ["connection"],
            "additionalProperties": false,
        ],
        readOnly: true,
        run: { arguments in
            await MCPConnections.run(arguments, need: .read) { connection, session in
                let reply = try await session.runCommand(["listDatabases": 1], onDatabase: "admin")
                guard let databases = reply["databases"] as? Document else {
                    return .failure("The server's listDatabases reply had no databases list.")
                }
                let entries: [JSONValue] = databases.values.compactMap { value in
                    guard let database = value as? Document,
                        let name = database["name"] as? String
                    else { return nil }
                    var entry: [String: JSONValue] = ["name": .string(name)]
                    if let size = integer(database["sizeOnDisk"]) {
                        entry["sizeOnDisk"] = .int(size)
                    }
                    if let empty = database["empty"] as? Bool {
                        entry["empty"] = .bool(empty)
                    }
                    return .object(entry)
                }
                let result: JSONValue = [
                    "connection": .string(connection.alias),
                    "databases": .array(entries),
                ]
                return .success(String(decoding: result.encoded(pretty: true), as: UTF8.self))
            }
        })

    /// A BSON number as an Int (servers send sizes as int32, int64 or double).
    private static func integer(_ value: Primitive?) -> Int? {
        switch value {
        case let value as Int: return value
        case let value as Int32: return Int(value)
        case let value as Double where value.isFinite: return Int(value)
        default: return nil
        }
    }
}

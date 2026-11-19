import BSON
import ExtendedJSON
import Foundation
import MCPServer
import MongoService

/// The tools the MCP server offers, added one at a time (internal
/// mcp-tools.md). Every tool runs its app work on the main actor; tools
/// that touch a database go through `MCPConnections`, which checks the
/// connection's AI Access first.
enum MCPTools {
    static let all: [MCPTool] = [listConnections, listDatabases, listCollections, find]

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

    // MARK: - list_collections

    static let listCollections = MCPTool(
        name: "list_collections",
        title: "List collections",
        description: """
            Lists the collections in one database on one of the user's saved connections, \
            with each one's type: collection, view or timeseries. The connection's access \
            must be readOnly or readWrite. A database that doesn't exist has no collections.
            """,
        inputSchema: [
            "type": "object",
            "properties": [
                "connection": MCPConnections.connectionArgumentSchema,
                "database": ["type": "string", "description": "The database name."],
            ],
            "required": ["connection", "database"],
            "additionalProperties": false,
        ],
        readOnly: true,
        run: { arguments in
            guard let database = nonEmptyString(arguments["database"]) else {
                return .failure("database is required: a database name from list_databases.")
            }
            return await MCPConnections.run(arguments, need: .read) { connection, session in
                // nameOnly still returns the type and needs fewer privileges;
                // authorizedCollections lets a limited user see its own.
                let entries = try await session.collectCursor(
                    command: [
                        "listCollections": 1, "nameOnly": true, "authorizedCollections": true,
                    ],
                    onDatabase: database)
                let collections: [JSONValue] =
                    entries
                    .compactMap { entry -> (name: String, type: String)? in
                        guard let name = entry["name"] as? String else { return nil }
                        return (name, entry["type"] as? String ?? "collection")
                    }
                    .sorted { $0.name < $1.name }
                    .map { ["name": .string($0.name), "type": .string($0.type)] }
                let result: JSONValue = [
                    "connection": .string(connection.alias),
                    "database": .string(database),
                    "collections": .array(collections),
                ]
                return .success(String(decoding: result.encoded(pretty: true), as: UTF8.self))
            }
        })

    // MARK: - find

    /// Limits agreed with the owner (internal mcp-tools.md §7, step 5).
    enum FindLimits {
        static let defaultLimit = 20
        static let maxLimit = 100
        static let maxTimeMS = 10_000
        static let maxOutputBytes = 200_000
    }

    static let find = MCPTool(
        name: "find",
        title: "Find documents",
        description: """
            Finds documents in a collection on one of the user's saved connections. The \
            connection's access must be readOnly or readWrite.

            filter, projection and sort are text in MongoDB Extended JSON or mongosh syntax, \
            read exactly as the app's Find pane reads them, for example \
            {status: "shipped", placedAt: {$gte: ISODate("2026-10-01T00:00:00Z")}} or \
            {customerId: ObjectId("…")}. Pass them as text, never as JSON objects: key order \
            and BSON types matter. Without a sort, documents are sorted by _id, as in the app.

            Returns at most \(FindLimits.maxLimit) documents per call (default \
            \(FindLimits.defaultLimit)); page with skip. hasMore says whether more documents \
            match. The server stops a query after \(FindLimits.maxTimeMS / 1000) seconds. \
            Documents are MongoDB Extended JSON v2 with exact BSON types ($oid, $date, \
            $numberLong, $numberDecimal, …) in their stored field order. Output over about \
            \(FindLimits.maxOutputBytes / 1000) KB is cut at the last whole document \
            (truncated: true); use a projection or a smaller limit.
            """,
        inputSchema: [
            "type": "object",
            "properties": [
                "connection": MCPConnections.connectionArgumentSchema,
                "database": ["type": "string", "description": "The database name."],
                "collection": ["type": "string", "description": "The collection name."],
                "filter": [
                    "type": "string",
                    "description":
                        "The query filter, as Extended JSON or mongosh text. Omit for every document.",
                ],
                "projection": [
                    "type": "string",
                    "description":
                        "Fields to return, as Extended JSON or mongosh text, e.g. {name: 1, email: 1}.",
                ],
                "sort": [
                    "type": "string",
                    "description":
                        "Sort order, as Extended JSON or mongosh text, e.g. {placedAt: -1}. Defaults to _id.",
                ],
                "skip": ["type": "integer", "minimum": 0],
                "limit": ["type": "integer", "minimum": 1, "maximum": .int(FindLimits.maxLimit)],
            ],
            "required": ["connection", "database", "collection"],
            "additionalProperties": false,
        ],
        readOnly: true,
        run: { arguments in
            let query: FindQuery
            do {
                query = try FindQuery(arguments)
            } catch let refusal as MCPConnections.Refusal {
                return .failure(refusal.message)
            } catch {
                return .failure(String(describing: error))
            }
            return await MCPConnections.run(arguments, need: .read) { connection, session in
                let documents: [Document]
                do {
                    // One more than asked for, to tell whether more match.
                    documents = try await session.find(
                        database: query.database, collection: query.collection,
                        filter: query.filter,
                        options: .init(
                            projection: query.projection, sort: query.sort, skip: query.skip,
                            limit: query.limit + 1, maxTimeMS: FindLimits.maxTimeMS),
                        token: OperationToken())
                } catch let error as MongoServiceError where error.code == 50 {
                    return .failure(
                        "The query ran longer than \(FindLimits.maxTimeMS / 1000) seconds, so the server stopped it. Narrow the filter or filter on an indexed field."
                    )
                }
                return render(query, connection: connection.alias, documents: documents)
            }
        })

    /// The find arguments, parsed and checked before connecting.
    struct FindQuery: Sendable {
        var database: String
        var collection: String
        var filterText: String
        var filter: Document
        var projection: Document?
        var sortText: String
        var sort: Document
        var skip: Int
        var limit: Int

        init(_ arguments: [String: JSONValue]) throws {
            func fail(_ message: String) -> MCPConnections.Refusal {
                MCPConnections.Refusal(message: message)
            }
            guard let database = nonEmptyString(arguments["database"]) else {
                throw fail("database is required: a database name from list_databases.")
            }
            guard let collection = nonEmptyString(arguments["collection"]) else {
                throw fail("collection is required: a collection name from list_collections.")
            }
            self.database = database
            self.collection = collection

            func text(_ name: String) throws -> String? {
                switch arguments[name] {
                case nil, .null?: return nil
                case .string(let value)?:
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                default:
                    throw fail(
                        "\(name) must be text in Extended JSON or mongosh syntax, such as {status: \"shipped\"}, not a JSON object: key order and BSON types would be lost."
                    )
                }
            }
            func document(_ name: String, _ text: String) throws -> Document {
                do {
                    return try ExtendedJSON.parseDocument(text)
                } catch {
                    throw fail("\(name) isn't valid Extended JSON or mongosh syntax: \(error)")
                }
            }
            func integer(_ name: String, default fallback: Int) throws -> Int {
                switch arguments[name] {
                case nil, .null?: return fallback
                case .int(let value)?: return value
                case .double(let value)? where value.rounded() == value: return Int(value)
                default: throw fail("\(name) must be a whole number.")
                }
            }

            // The Find pane's rules (QueryNormalizer, default _id sort).
            filterText = QueryNormalizer.normalizeCriteria(
                try text("filter") ?? "", emptyIsValid: false)
            filter = try document("filter", filterText)
            if let projectionText = try text("projection") {
                projection = try document(
                    "projection",
                    QueryNormalizer.normalizeCriteria(projectionText, emptyIsValid: false))
            }
            if let sortText = try text("sort") {
                self.sortText = QueryNormalizer.normalizeCriteria(sortText, emptyIsValid: false)
            } else {
                self.sortText = Preferences.defaultSortAscending ? "{_id: 1}" : "{_id: -1}"
            }
            sort = try document("sort", self.sortText)

            skip = try integer("skip", default: 0)
            guard skip >= 0 else { throw fail("skip can't be negative.") }
            limit = try integer("limit", default: FindLimits.defaultLimit)
            guard (1...FindLimits.maxLimit).contains(limit) else {
                throw fail("limit must be between 1 and \(FindLimits.maxLimit).")
            }
        }
    }

    /// Builds the result text by hand: documents must keep their field order
    /// and exact types, so they're written by the Extended JSON serializer and
    /// never pass through an unordered JSON object.
    private static func render(
        _ query: FindQuery, connection: String, documents: [Document]
    ) -> MCPToolResult {
        let format = EJSONFormat(mode: .editor, pretty: false, keyOrder: .document)
        var written: [String] = []
        var bytes = 0
        var truncated = false
        for document in documents.prefix(query.limit) {
            let text: String
            do {
                text = try ExtendedJSON.stringify(document, format: format)
            } catch {
                return .failure(
                    "Document \(written.count + 1) couldn't be written as Extended JSON: \(error)")
            }
            if bytes + text.utf8.count > FindLimits.maxOutputBytes {
                guard !written.isEmpty else {
                    return .failure(
                        "The first document is larger than \(FindLimits.maxOutputBytes / 1000) KB. Use a projection to return fewer fields."
                    )
                }
                truncated = true
                break
            }
            written.append(text)
            bytes += text.utf8.count
        }

        func string(_ value: String) -> String {
            String(decoding: JSONValue.string(value).encoded(), as: UTF8.self)
        }
        var lines = [
            "{",
            "  \"connection\": \(string(connection)),",
            "  \"database\": \(string(query.database)),",
            "  \"collection\": \(string(query.collection)),",
            "  \"filter\": \(string(query.filterText)),",
            "  \"sort\": \(string(query.sortText)),",
            "  \"skip\": \(query.skip),",
            "  \"limit\": \(query.limit),",
            "  \"returned\": \(written.count),",
            "  \"hasMore\": \(documents.count > query.limit || truncated),",
            "  \"truncated\": \(truncated),",
        ]
        if written.isEmpty {
            lines.append("  \"documents\": []")
        } else {
            lines.append("  \"documents\": [")
            lines.append(
                written.map { "    " + $0 }.joined(separator: ",\n"))
            lines.append("  ]")
        }
        lines.append("}")
        return .success(lines.joined(separator: "\n"))
    }

    private static func nonEmptyString(_ value: JSONValue?) -> String? {
        guard let string = value?.stringValue?.trimmingCharacters(in: .whitespaces),
            !string.isEmpty
        else { return nil }
        return string
    }

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

import AppKit
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
    static let all: [MCPTool] = [
        listConnections, listDatabases, listCollections, find, openQuery, insertDocuments,
        updateDocuments, deleteDocuments, waitForDecision,
    ]

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

    // MARK: - open_query

    static let openQuery = MCPTool(
        name: "open_query",
        title: "Show a query in MongoHub Plus",
        description: """
            Shows a query to the user in MongoHub Plus, so you both look at the same results: \
            opens the connection's window (or brings an open one forward), opens the \
            collection's tab on Find, fills in the query and runs it. The results appear on \
            the user's screen and are not returned here; use find to read them. The \
            connection's access must be readOnly or readWrite.

            filter, projection and sort are text, exactly as for find. limit is how many \
            documents the app lists (the app's default is 30). The collection's tab is reused, \
            so this replaces the query the user had in it.
            """,
        inputSchema: [
            "type": "object",
            "properties": [
                "connection": MCPConnections.connectionArgumentSchema,
                "database": ["type": "string", "description": "The database name."],
                "collection": ["type": "string", "description": "The collection name."],
                "filter": [
                    "type": "string",
                    "description": "The query filter, as Extended JSON or mongosh text.",
                ],
                "projection": [
                    "type": "string",
                    "description": "Fields to show, as Extended JSON or mongosh text.",
                ],
                "sort": [
                    "type": "string",
                    "description": "Sort order, as Extended JSON or mongosh text. Defaults to _id.",
                ],
                "skip": ["type": "integer", "minimum": 0],
                "limit": ["type": "integer", "minimum": 1],
            ],
            "required": ["connection", "database", "collection"],
            "additionalProperties": false,
        ],
        readOnly: true,
        run: { arguments in
            // The text must parse exactly as it would for find. The limit is
            // only how many rows the app lists, so find's cap doesn't apply.
            var checked = arguments
            checked["limit"] = nil
            let query: FindQuery
            do {
                query = try FindQuery(checked)
            } catch let refusal as MCPConnections.Refusal {
                return .failure(refusal.message)
            } catch {
                return .failure(String(describing: error))
            }
            let limit: Int?
            switch arguments["limit"] {
            case nil, .null?: limit = nil
            case .int(let value)? where value >= 1: limit = value
            default: return .failure("limit must be a whole number of at least 1.")
            }
            func typed(_ name: String) -> String {
                arguments[name]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            let shown = ConnectionWindowController.ShownQuery(
                database: query.database, collection: query.collection,
                criteria: typed("filter"), fields: typed("projection"), sort: typed("sort"),
                skip: query.skip > 0 ? query.skip : nil, limit: limit)
            let sortShown = typed("sort").isEmpty ? "the app's default (_id)" : query.sortText

            return await MainActor.run { () -> MCPToolResult in
                let connection: MongoConnection
                do {
                    connection = try MCPConnections.resolve(arguments["connection"], need: .read)
                } catch let refusal as MCPConnections.Refusal {
                    return .failure(refusal.message)
                } catch {
                    return .failure(String(describing: error))
                }
                guard let app = NSApp.delegate as? AppDelegate else {
                    return .failure("MongoHub Plus can't show windows right now.")
                }
                let wasOpen = app.hasConnectionWindow(for: connection.id)
                guard app.openConnection(connection).show(shown) else {
                    return .failure(
                        "The \"\(connection.alias)\" window in MongoHub Plus couldn't connect, so nothing was shown. The user can close that window, and then you can try again."
                    )
                }
                // Don't take focus from whatever the user is doing: one Dock
                // bounce says where to look.
                NSApp.requestUserAttention(.informationalRequest)
                let state =
                    wasOpen ? "already open" : "opened now; it connects, then runs the query"
                return .success(
                    """
                    Showing the query in MongoHub Plus, in the "\(connection.alias)" window \
                    (\(state)): \(query.database).\(query.collection) on the Find tab, filter \
                    \(query.filterText), sort \(sortShown). The results are on the user's \
                    screen, not returned here; use find to read them.
                    """)
            }
        })

    // MARK: - insert_documents

    static let maxInsertDocuments = 100

    static let insertDocuments = MCPTool(
        name: "insert_documents",
        title: "Insert documents",
        description: """
            Inserts new documents into a collection on one of the user's saved connections. \
            The connection's access must be readWrite. Inserting is the only write assistants \
            may run directly; updates and deletes are never run directly.

            documents is text in MongoDB Extended JSON or mongosh syntax: one document, or an \
            array of up to \(maxInsertDocuments), for example \
            [{name: "Dee Test", createdAt: ISODate("2026-11-19T00:00:00Z"), visits: NumberInt(1)}]. \
            Pass text, not JSON objects, so field order and BSON types survive. A document \
            without an _id gets a new ObjectId. Documents are inserted in order, stopping at \
            the first failure; the result lists the _ids inserted and any errors. Inserting \
            into a collection that doesn't exist creates it.
            """,
        inputSchema: [
            "type": "object",
            "properties": [
                "connection": MCPConnections.connectionArgumentSchema,
                "database": ["type": "string", "description": "The database name."],
                "collection": ["type": "string", "description": "The collection name."],
                "documents": [
                    "type": "string",
                    "description":
                        "One document or an array of documents, as Extended JSON or mongosh text.",
                ],
            ],
            "required": ["connection", "database", "collection", "documents"],
            "additionalProperties": false,
        ],
        readOnly: false,
        destructive: false,
        run: { arguments in
            guard let database = nonEmptyString(arguments["database"]) else {
                return .failure("database is required: a database name from list_databases.")
            }
            guard let collection = nonEmptyString(arguments["collection"]) else {
                return .failure("collection is required: a collection name from list_collections.")
            }
            let documents: [Document]
            switch parseInsertDocuments(arguments["documents"]) {
            case .success(let parsed): documents = parsed
            case .failure(let refusal): return .failure(refusal.message)
            }

            return await MCPConnections.run(arguments, need: .insert) { connection, session in
                var batch = Document(isArray: true)
                for document in documents {
                    batch.append(document)
                }
                var command = Document()
                command["insert"] = collection
                command["documents"] = batch
                command["ordered"] = true
                let reply = try await session.runCommand(command, onDatabase: database)
                return insertResult(
                    reply, documents: documents, connection: connection.alias,
                    database: database, collection: collection)
            }
        })

    /// The Insert pane's rules: a bare document is wrapped in [ ], and every
    /// element must be a document. A missing _id is added first, as drivers
    /// do, so the result can name every inserted document.
    static func parseInsertDocuments(_ value: JSONValue?) -> Result<
        [Document], MCPConnections.Refusal
    > {
        func fail(_ message: String) -> Result<[Document], MCPConnections.Refusal> {
            .failure(MCPConnections.Refusal(message: message))
        }
        let raw: String
        switch value {
        case .string(let text)?: raw = text
        case nil, .null?:
            return fail("documents is required: one document or an array, as Extended JSON text.")
        default:
            return fail(
                "documents must be text in Extended JSON or mongosh syntax, such as [{name: \"Dee\"}], not JSON objects: field order and BSON types would be lost."
            )
        }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return fail("documents is empty.") }
        if !text.hasPrefix("[") {
            text = "[\(text)]"
        }
        let parsed: Document
        do {
            parsed = try ExtendedJSON.parseDocument(text)
        } catch {
            return fail("documents isn't valid Extended JSON or mongosh syntax: \(error)")
        }
        guard parsed.isArray, !parsed.isEmpty else {
            return fail("Provide a document or an array of documents.")
        }
        guard parsed.count <= maxInsertDocuments else {
            return fail(
                "That's \(parsed.count) documents; insert at most \(maxInsertDocuments) per call.")
        }
        var documents: [Document] = []
        for (index, value) in parsed.values.enumerated() {
            guard let document = value as? Document, !document.isArray else {
                return fail("Element \(index) isn't a document; every element must be a document.")
            }
            if document["_id"] != nil {
                documents.append(document)
            } else {
                var withID = Document()
                withID["_id"] = ObjectId()
                withID.append(contentsOf: document)
                documents.append(withID)
            }
        }
        return .success(documents)
    }

    /// Reports what the server inserted. Per-document failures (a duplicate
    /// key, a validation rule) arrive as writeErrors in an ok reply.
    private static func insertResult(
        _ reply: Document, documents: [Document], connection: String, database: String,
        collection: String
    ) -> MCPToolResult {
        let inserted = integer(reply["n"]) ?? 0
        let writeErrors =
            (reply["writeErrors"] as? Document)?.values.compactMap {
                $0 as? Document
            } ?? []
        var errors: [String] = []
        for error in writeErrors {
            let index = integer(error["index"]).map(String.init) ?? "?"
            let code = integer(error["code"]).map(String.init) ?? "?"
            let message = error["errmsg"] as? String ?? "unknown error"
            errors.append(
                "{\"index\": \(index), \"code\": \(code), \"message\": \(jsonString(message))}")
        }
        if let concern = reply["writeConcernError"] as? Document {
            let message = concern["errmsg"] as? String ?? "write concern error"
            errors.append("{\"writeConcern\": true, \"message\": \(jsonString(message))}")
        }

        // Ordered: everything before the first failure went in.
        let format = EJSONFormat(mode: .editor, pretty: false, keyOrder: .document)
        let ids = documents.prefix(inserted).map { document -> String in
            (try? ExtendedJSON.stringifyValue(document["_id"] ?? Null(), format: format))
                ?? "null"
        }
        var lines = [
            "{",
            "  \"connection\": \(jsonString(connection)),",
            "  \"database\": \(jsonString(database)),",
            "  \"collection\": \(jsonString(collection)),",
            "  \"inserted\": \(inserted),",
            "  \"notInserted\": \(documents.count - inserted),",
            "  \"insertedIds\": [\(ids.joined(separator: ", "))],",
        ]
        lines.append(
            errors.isEmpty
                ? "  \"errors\": []"
                : "  \"errors\": [\n    " + errors.joined(separator: ",\n    ") + "\n  ]")
        lines.append("}")
        let text = lines.joined(separator: "\n")
        return errors.isEmpty ? .success(text) : .failure(text)
    }

    private static func jsonString(_ value: String) -> String {
        String(decoding: JSONValue.string(value).encoded(), as: UTF8.self)
    }

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

    static func nonEmptyString(_ value: JSONValue?) -> String? {
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

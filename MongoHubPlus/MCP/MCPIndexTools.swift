import BSON
import ExtendedJSON
import Foundation
import MCPServer
import MongoService

/// list_indexes (internal mcp-tools.md §7 step 12): what the Index pane
/// shows, read-only.
extension MCPTools {
    static let listIndexes = MCPTool(
        name: "list_indexes",
        title: "List indexes",
        description: """
            Lists a collection's indexes on one of the user's saved connections, as the app's \
            Index pane shows them: each index's definition exactly as the server returns it \
            (key fields in order, name, unique, sparse, partialFilterExpression, \
            expireAfterSeconds, collation, hidden, …) in MongoDB Extended JSON, its size on \
            disk, and how many times queries used it since the server started ($indexStats, \
            counted per node on replica sets). Sizes and usage are left out, with a note, when \
            the user's privileges don't allow them. Views have no indexes of their own. The \
            connection's access must be readOnly or readWrite.
            """,
        inputSchema: [
            "type": "object",
            "properties": [
                "connection": MCPConnections.connectionArgumentSchema,
                "database": ["type": "string", "description": "The database name."],
                "collection": ["type": "string", "description": "The collection name."],
            ],
            "required": ["connection", "database", "collection"],
            "additionalProperties": false,
        ],
        readOnly: true,
        run: { arguments in
            guard let database = nonEmptyString(arguments["database"]) else {
                return .failure("database is required: a database name from list_databases.")
            }
            guard let collection = nonEmptyString(arguments["collection"]) else {
                return .failure(
                    "collection is required: a collection name from list_collections.")
            }
            return await MCPConnections.run(arguments, need: .read) { connection, session in
                var command = Document()
                command["listIndexes"] = collection
                let indexes: [Document]
                do {
                    indexes = try await session.collectCursor(
                        command: command, onDatabase: database, token: OperationToken())
                } catch let error as MongoServiceError where error.code == 166 {
                    return .failure(
                        "\(database).\(collection) is a view, so it has no indexes of its own: queries on it use its source collection's indexes."
                    )
                } catch let error as MongoServiceError where error.code == 26 {
                    return .failure(
                        "There's no collection named \"\(collection)\" in \(database). Call list_collections for the names."
                    )
                }

                // Best effort, as in the Index pane: both need privileges
                // that a read-only user may not have.
                var notes: [OrderedJSON] = []
                var sizes: [String: Int]?
                do {
                    let stats = try await session.collectionStats(
                        database: database, collection: collection)
                    if let sizeDocument = stats["indexSizes"] as? Document {
                        var found: [String: Int] = [:]
                        for pair in sizeDocument.pairs {
                            if let bytes = integer(pair.value) { found[pair.key] = bytes }
                        }
                        sizes = found
                    }
                } catch {
                    notes.append(.string("Index sizes are unavailable: \(error)"))
                }
                var usage: [String: (ops: Int, since: Date?)]?
                do {
                    var pipeline = Document(isArray: true)
                    pipeline.append(["$indexStats": Document()] as Document)
                    let stats = try await session.aggregate(
                        database: database, collection: collection, pipeline: pipeline)
                    var found: [String: (ops: Int, since: Date?)] = [:]
                    for stat in stats {
                        guard let name = stat["name"] as? String,
                            let accesses = stat["accesses"] as? Document,
                            let ops = integer(accesses["ops"])
                        else { continue }
                        found[name] = (ops, accesses["since"] as? Date)
                    }
                    usage = found
                    notes.append(
                        .string(
                            "Usage counts start when the server starts and are counted per node on replica sets."
                        ))
                } catch {
                    notes.append(.string("Index usage is unavailable: \(error)"))
                }

                let format = EJSONFormat(mode: .editor, pretty: false, keyOrder: .document)
                var written: [OrderedJSON] = []
                for index in indexes {
                    let name = index["name"] as? String ?? ""
                    let spec: String
                    do {
                        spec = try ExtendedJSON.stringify(index, format: format)
                    } catch {
                        return .failure(
                            "Index \(name) couldn't be written as Extended JSON: \(error)")
                    }
                    var entry: [(String, OrderedJSON)] = [("name", .string(name))]
                    if let bytes = sizes?[name] {
                        entry.append(("sizeBytes", .int(bytes)))
                    }
                    if let used = usage?[name] {
                        var counts: [(String, OrderedJSON)] = [("ops", .int(used.ops))]
                        if let since = used.since {
                            counts.append(("since", .string(since.formatted(.iso8601))))
                        }
                        entry.append(("usage", .object(counts)))
                    }
                    entry.append(("spec", .raw(spec)))
                    written.append(.object(entry))
                }

                var result: [(String, OrderedJSON)] = [
                    ("connection", .string(connection.alias)),
                    ("database", .string(database)),
                    ("collection", .string(collection)),
                    ("indexes", .array(written)),
                ]
                if !notes.isEmpty {
                    result.append(("notes", .array(notes)))
                }
                return .success(OrderedJSON.object(result).written())
            }
        })
}

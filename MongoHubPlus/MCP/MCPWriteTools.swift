import BSON
import ExtendedJSON
import Foundation
import MCPServer
import MongoService

/// Updates as pending actions (internal mcp-tools.md §0, §7 step 8): the
/// tool never changes anything. It shows the user exactly what would run and
/// waits for the user to click Apply Update or Reject in the app.
extension MCPTools {
    static let updateDocuments = MCPTool(
        name: "update_documents",
        title: "Ask to update documents",
        description: """
            Asks the user to update documents in a collection on one of their saved \
            connections. Nothing changes unless the user applies it: MongoHub Plus shows the \
            user exactly this update, how many documents it touches and a before/after \
            preview, and the user clicks Apply Update or Reject. You can't approve it, and \
            only one request waits at a time. The connection's access must be readWrite.

            filter and update are text in MongoDB Extended JSON or mongosh syntax. update must \
            use update operators, for example {$set: {status: "shipped"}, $inc: {retries: \
            NumberInt(1)}}; the supported ones are $set, $unset, $inc, $mul, $min, $max, \
            $rename, $setOnInsert, $currentDate, $bit, $push, $addToSet, $pop, $pull and \
            $pullAll. multi: true updates every matching document; otherwise only the first. \
            The filter {} matches every document, and then the user must also type the \
            collection's name to apply it.

            The call waits about 100 seconds for the decision. If the user hasn't answered by \
            then it returns status "waiting" and a request id: call wait_for_decision with \
            that id to keep waiting. A request without an answer is rejected after 10 minutes.
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
                        "Which documents, as Extended JSON or mongosh text. {} means every document.",
                ],
                "update": [
                    "type": "string",
                    "description":
                        "The change, as an update-operator document in Extended JSON or mongosh text.",
                ],
                "multi": [
                    "type": "boolean",
                    "description":
                        "true to update every matching document; false (the default) for the first only.",
                ],
            ],
            "required": ["connection", "database", "collection", "filter", "update"],
            "additionalProperties": false,
        ],
        readOnly: false,
        run: { arguments in
            let parsed: ParsedUpdate
            switch ParsedUpdate.parse(arguments) {
            case .success(let value): parsed = value
            case .failure(let refusal): return .failure(refusal.message)
            }

            // Check access, then count and sample what the update would touch,
            // so the user sees it. A filter the server rejects stops here,
            // before the user is bothered.
            let preview = await MCPConnections.withSession(
                arguments["connection"], need: .update
            ) { connection, session -> (UUID, String, Int?, [Document]) in
                let samples = try await session.find(
                    database: parsed.database, collection: parsed.collection,
                    filter: parsed.filter,
                    options: .init(limit: 3, maxTimeMS: FindLimits.maxTimeMS))
                let count = try? await session.count(
                    database: parsed.database, collection: parsed.collection,
                    filter: parsed.filter)
                return (connection.id, connection.alias, count, samples)
            }
            let (connectionID, connectionName, count, samples): (UUID, String, Int?, [Document])
            switch preview {
            case .success(let value): (connectionID, connectionName, count, samples) = value
            case .failure(let refusal): return .failure(refusal.message)
            }

            let request = PendingActions.UpdateRequest(
                connectionID: connectionID, connectionName: connectionName,
                database: parsed.database, collection: parsed.collection,
                filterText: parsed.filterText, filter: parsed.filter,
                updateText: parsed.updateText, update: parsed.update, multi: parsed.multi,
                matchCount: count, samples: samples)
            return await PendingActions.shared.submitAndWait(request)
        })

    static let waitForDecision = MCPTool(
        name: "wait_for_decision",
        title: "Wait for the user's decision",
        description: """
            Keeps waiting for the user's decision on a change requested with update_documents, \
            by the request id it returned. Waits about 100 seconds, then returns the outcome \
            (applied, rejected, expired) or status "waiting" again. It can't approve anything.
            """,
        inputSchema: [
            "type": "object",
            "properties": [
                "request": [
                    "type": "string", "description": "The request id update_documents returned.",
                ]
            ],
            "required": ["request"],
            "additionalProperties": false,
        ],
        readOnly: true,
        run: { arguments in
            guard let id = nonEmptyString(arguments["request"]) else {
                return .failure("request is required: the id update_documents returned.")
            }
            return await PendingActions.shared.wait(forRequest: id)
        })

    /// update_documents' arguments, checked before connecting.
    struct ParsedUpdate: Sendable {
        var database: String
        var collection: String
        var filterText: String
        var filter: Document
        var updateText: String
        var update: Document
        var multi: Bool

        static func parse(_ arguments: [String: JSONValue]) -> Result<
            ParsedUpdate, MCPConnections.Refusal
        > {
            func fail(_ message: String) -> Result<ParsedUpdate, MCPConnections.Refusal> {
                .failure(MCPConnections.Refusal(message: message))
            }
            guard let database = nonEmptyString(arguments["database"]) else {
                return fail("database is required: a database name from list_databases.")
            }
            guard let collection = nonEmptyString(arguments["collection"]) else {
                return fail("collection is required: a collection name from list_collections.")
            }

            // Both are required as text: {} has to be written out, never
            // assumed from a missing filter.
            func text(_ name: String) -> Result<String, MCPConnections.Refusal> {
                switch arguments[name] {
                case .string(let value)?:
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        return .failure(
                            .init(
                                message: name == "filter"
                                    ? "filter is empty. Write {} to match every document."
                                    : "update is empty."))
                    }
                    return .success(trimmed)
                case nil, .null?:
                    return .failure(.init(message: "\(name) is required, as text."))
                default:
                    return .failure(
                        .init(
                            message:
                                "\(name) must be text in Extended JSON or mongosh syntax, not a JSON object: key order and BSON types would be lost."
                        ))
                }
            }

            let filterInput: String
            switch text("filter") {
            case .success(let value): filterInput = value
            case .failure(let refusal): return .failure(refusal)
            }
            let filterText = QueryNormalizer.normalizeCriteria(filterInput, emptyIsValid: false)
            let filter: Document
            do {
                filter = try ExtendedJSON.parseDocument(filterText)
            } catch {
                return fail("filter isn't valid Extended JSON or mongosh syntax: \(error)")
            }

            let updateText: String
            switch text("update") {
            case .success(let value): updateText = value
            case .failure(let refusal): return .failure(refusal)
            }
            guard !updateText.hasPrefix("[") else {
                return fail("Aggregation-pipeline updates aren't supported. Use update operators.")
            }
            let update: Document
            do {
                update = try ExtendedJSON.parseDocument(updateText)
            } catch {
                return fail("update isn't valid Extended JSON or mongosh syntax: \(error)")
            }
            guard !update.isEmpty else {
                return fail("update has no operators.")
            }
            // The Update pane's rules: operators only, from its supported
            // set, each with a document of field/value pairs.
            do {
                _ = try UpdatePreview.effects(of: update, on: Document())
            } catch {
                return fail("update can't be used: \(error)")
            }

            let multi: Bool
            switch arguments["multi"] {
            case nil, .null?: multi = false
            case .bool(let value)?: multi = value
            default: return fail("multi must be true or false.")
            }

            return .success(
                ParsedUpdate(
                    database: database, collection: collection, filterText: filterText,
                    filter: filter, updateText: updateText, update: update, multi: multi))
        }
    }
}

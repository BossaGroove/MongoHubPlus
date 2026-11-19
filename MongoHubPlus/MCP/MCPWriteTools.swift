import BSON
import ExtendedJSON
import Foundation
import MCPServer
import MongoService

/// Updates and deletes as pending actions (internal mcp-tools.md §0, §7
/// steps 8 and 9): the tools never change anything. They show the user
/// exactly what would run and wait for the user to click Apply Update or
/// Delete, or Reject, in the app.
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
            collection's name to apply it. A filter that matches nothing is refused without \
            asking the user.

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
                "filter": filterSchema,
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
            let target: ChangeTarget
            switch ChangeTarget.parse(arguments) {
            case .success(let value): target = value
            case .failure(let refusal): return .failure(refusal.message)
            }
            let updateText: String
            let update: Document
            switch parseUpdate(arguments) {
            case .success(let value): (updateText, update) = value
            case .failure(let refusal): return .failure(refusal.message)
            }
            return await requestChange(
                arguments, target: target, kind: .update(text: updateText, update: update),
                sampleLimit: 3)
        })

    static let deleteDocuments = MCPTool(
        name: "delete_documents",
        title: "Ask to delete documents",
        description: """
            Asks the user to delete documents from a collection on one of their saved \
            connections. Nothing is deleted unless the user applies it: MongoHub Plus shows the \
            user exactly this filter, how many documents match and the first of them, and the \
            user clicks Delete or Reject. You can't approve it, and only one request waits at \
            a time. The connection's access must be readWrite.

            filter is text in MongoDB Extended JSON or mongosh syntax, for example \
            {status: "cancelled"} or {_id: ObjectId("…")}. multi: true deletes every matching \
            document; otherwise only the first. The filter {} matches every document, and then \
            the user must also type the collection's name to apply it. A filter that matches \
            nothing is refused without asking the user. Collections and databases can't be \
            dropped.

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
                "filter": filterSchema,
                "multi": [
                    "type": "boolean",
                    "description":
                        "true to delete every matching document; false (the default) for the first only.",
                ],
            ],
            "required": ["connection", "database", "collection", "filter"],
            "additionalProperties": false,
        ],
        readOnly: false,
        run: { arguments in
            let target: ChangeTarget
            switch ChangeTarget.parse(arguments) {
            case .success(let value): target = value
            case .failure(let refusal): return .failure(refusal.message)
            }
            // One document deletes only the first match, so only that one is
            // shown.
            return await requestChange(
                arguments, target: target, kind: .delete, sampleLimit: target.multi ? 3 : 1)
        })

    static let waitForDecision = MCPTool(
        name: "wait_for_decision",
        title: "Wait for the user's decision",
        description: """
            Keeps waiting for the user's decision on a change requested with update_documents \
            or delete_documents, by the request id it returned. Waits about 100 seconds, then \
            returns the outcome (applied, rejected, expired) or status "waiting" again. It \
            can't approve anything.
            """,
        inputSchema: [
            "type": "object",
            "properties": [
                "request": [
                    "type": "string",
                    "description": "The request id update_documents or delete_documents returned.",
                ]
            ],
            "required": ["request"],
            "additionalProperties": false,
        ],
        readOnly: true,
        run: { arguments in
            guard let id = nonEmptyString(arguments["request"]) else {
                return .failure(
                    "request is required: the id update_documents or delete_documents returned.")
            }
            return await PendingActions.shared.wait(forRequest: id)
        })

    private static let filterSchema: JSONValue = [
        "type": "string",
        "description":
            "Which documents, as Extended JSON or mongosh text. {} means every document.",
    ]

    /// Counts and samples what a change would touch, so the user sees it,
    /// then shows the request and waits for the decision. A filter the
    /// server rejects, or one that matches nothing, stops here, before the
    /// user is bothered.
    private static func requestChange(
        _ arguments: [String: JSONValue], target: ChangeTarget,
        kind: PendingActions.Request.Kind, sampleLimit: Int
    ) async -> MCPToolResult {
        let preview = await MCPConnections.withSession(
            arguments["connection"], need: .change
        ) { connection, session -> (UUID, String, Int?, [Document]) in
            let samples = try await session.find(
                database: target.database, collection: target.collection,
                filter: target.filter,
                options: .init(limit: sampleLimit, maxTimeMS: FindLimits.maxTimeMS))
            let count = try? await session.count(
                database: target.database, collection: target.collection,
                filter: target.filter)
            return (connection.id, connection.alias, count, samples)
        }
        let (connectionID, connectionName, count, samples): (UUID, String, Int?, [Document])
        switch preview {
        case .success(let value): (connectionID, connectionName, count, samples) = value
        case .failure(let refusal): return .failure(refusal.message)
        }

        guard !samples.isEmpty else {
            return .failure(
                "No documents in \(target.database).\(target.collection) match the filter right now, so there is nothing to ask for. The user wasn't asked, and nothing changed."
            )
        }
        let request = PendingActions.Request(
            kind: kind, connectionID: connectionID, connectionName: connectionName,
            database: target.database, collection: target.collection,
            filterText: target.filterText, filter: target.filter, multi: target.multi,
            matchCount: count, samples: samples)
        return await PendingActions.shared.submitAndWait(request)
    }

    /// Which documents a change is for, checked before connecting.
    struct ChangeTarget: Sendable {
        var database: String
        var collection: String
        var filterText: String
        var filter: Document
        var multi: Bool

        static func parse(_ arguments: [String: JSONValue]) -> Result<
            ChangeTarget, MCPConnections.Refusal
        > {
            func fail(_ message: String) -> Result<ChangeTarget, MCPConnections.Refusal> {
                .failure(MCPConnections.Refusal(message: message))
            }
            guard let database = nonEmptyString(arguments["database"]) else {
                return fail("database is required: a database name from list_databases.")
            }
            guard let collection = nonEmptyString(arguments["collection"]) else {
                return fail("collection is required: a collection name from list_collections.")
            }

            // Required as text: {} has to be written out, never assumed from
            // a missing filter.
            let filterInput: String
            switch requiredText("filter", in: arguments) {
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

            let multi: Bool
            switch arguments["multi"] {
            case nil, .null?: multi = false
            case .bool(let value)?: multi = value
            default: return fail("multi must be true or false.")
            }

            return .success(
                ChangeTarget(
                    database: database, collection: collection, filterText: filterText,
                    filter: filter, multi: multi))
        }
    }

    /// update_documents' update: operators only, by the Update pane's rules.
    private static func parseUpdate(_ arguments: [String: JSONValue]) -> Result<
        (String, Document), MCPConnections.Refusal
    > {
        func fail(_ message: String) -> Result<(String, Document), MCPConnections.Refusal> {
            .failure(MCPConnections.Refusal(message: message))
        }
        let updateText: String
        switch requiredText("update", in: arguments) {
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
        // The Update pane's rules: operators only, from its supported set,
        // each with a document of field/value pairs.
        do {
            _ = try UpdatePreview.effects(of: update, on: Document())
        } catch {
            return fail("update can't be used: \(error)")
        }
        return .success((updateText, update))
    }

    /// A required text argument, trimmed. JSON objects are refused: key
    /// order and BSON types would be lost.
    private static func requiredText(
        _ name: String, in arguments: [String: JSONValue]
    ) -> Result<String, MCPConnections.Refusal> {
        switch arguments[name] {
        case .string(let value)?:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return .failure(
                    .init(
                        message: name == "filter"
                            ? "filter is empty. Write {} to match every document."
                            : "\(name) is empty."))
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
}

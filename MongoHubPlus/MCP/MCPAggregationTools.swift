import BSON
import ExtendedJSON
import Foundation
import MCPServer
import MongoService

/// count and aggregate (internal mcp-tools.md §7 step 11): read-only, with
/// find's limits. aggregate refuses the stages that write ($out, $merge) or
/// never finish ($changeStream).
extension MCPTools {
    static let countDocuments = MCPTool(
        name: "count",
        title: "Count documents",
        description: """
            Counts the documents in a collection that match a filter, on one of the user's \
            saved connections, the way the app's Find pane counts its total results. The \
            connection's access must be readOnly or readWrite.

            filter is text in MongoDB Extended JSON or mongosh syntax, as for find; omit it to \
            count every document. The server stops a count after \
            \(FindLimits.maxTimeMS / 1000) seconds.
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
            ],
            "required": ["connection", "database", "collection"],
            "additionalProperties": false,
        ],
        readOnly: true,
        run: { arguments in
            // find's rules for the filter; its other arguments don't apply.
            let query: FindQuery
            do {
                query = try FindQuery(
                    arguments.filter { ["database", "collection", "filter"].contains($0.key) })
            } catch let refusal as MCPConnections.Refusal {
                return .failure(refusal.message)
            } catch {
                return .failure(String(describing: error))
            }
            return await MCPConnections.run(arguments, need: .read) { connection, session in
                var command = Document()
                command["count"] = query.collection
                if !query.filter.isEmpty {
                    command["query"] = query.filter
                }
                command["maxTimeMS"] = Int32(FindLimits.maxTimeMS)
                let reply: Document
                do {
                    reply = try await session.runCommand(
                        command, onDatabase: query.database, token: OperationToken())
                } catch let error as MongoServiceError where error.code == 50 {
                    return .failure(
                        "The count ran longer than \(FindLimits.maxTimeMS / 1000) seconds, so the server stopped it. Narrow the filter or filter on an indexed field."
                    )
                }
                guard let count = integer(reply["n"]) else {
                    return .failure("The server's count reply had no count.")
                }
                let result: OrderedJSON = .object([
                    ("connection", .string(connection.alias)),
                    ("database", .string(query.database)),
                    ("collection", .string(query.collection)),
                    ("filter", .string(query.filterText)),
                    ("count", .int(count)),
                ])
                return .success(result.written())
            }
        })

    static let aggregate = MCPTool(
        name: "aggregate",
        title: "Run an aggregation",
        description: """
            Runs a read-only aggregation pipeline on a collection on one of the user's saved \
            connections and returns the resulting documents. The connection's access must be \
            readOnly or readWrite.

            pipeline is text in MongoDB Extended JSON or mongosh syntax, an array of stages, \
            for example [{$match: {status: "shipped"}}, {$group: {_id: "$customerId", total: \
            {$sum: "$total"}}}, {$sort: {total: -1}}]. Pass it as text, never as a JSON array: \
            key order and BSON types matter. Stages that write ($out, $merge) and \
            $changeStream are refused.

            Returns at most \(FindLimits.maxLimit) documents (default \
            \(FindLimits.defaultLimit)); hasMore says whether the pipeline produced more. The \
            server stops a pipeline after \(FindLimits.maxTimeMS / 1000) seconds. Documents \
            are MongoDB Extended JSON v2 with exact BSON types, in their field order. Output \
            over about \(FindLimits.maxOutputBytes / 1000) KB is cut at the last whole \
            document (truncated: true); add a $project stage or a smaller limit.
            """,
        inputSchema: [
            "type": "object",
            "properties": [
                "connection": MCPConnections.connectionArgumentSchema,
                "database": ["type": "string", "description": "The database name."],
                "collection": ["type": "string", "description": "The collection name."],
                "pipeline": [
                    "type": "string",
                    "description":
                        "The stages, as an Extended JSON or mongosh array, e.g. [{$match: {…}}, {$group: {…}}].",
                ],
                "limit": ["type": "integer", "minimum": 1, "maximum": .int(FindLimits.maxLimit)],
            ],
            "required": ["connection", "database", "collection", "pipeline"],
            "additionalProperties": false,
        ],
        readOnly: true,
        run: { arguments in
            let request: AggregateRequest
            switch AggregateRequest.parse(arguments) {
            case .success(let value): request = value
            case .failure(let refusal): return .failure(refusal.message)
            }
            return await MCPConnections.run(arguments, need: .read) { connection, session in
                // One more than asked for, to tell whether there are more.
                var pipeline = request.pipeline
                var limitStage = Document()
                limitStage["$limit"] = request.limit + 1
                pipeline.append(limitStage)
                var command = Document()
                command["aggregate"] = request.collection
                command["pipeline"] = pipeline
                command["cursor"] = ["batchSize": Int32(request.limit + 1)] as Document
                command["maxTimeMS"] = Int32(FindLimits.maxTimeMS)
                let documents: [Document]
                do {
                    documents = try await session.collectCursor(
                        command: command, onDatabase: request.database, token: OperationToken())
                } catch let error as MongoServiceError where error.code == 50 {
                    return .failure(
                        "The pipeline ran longer than \(FindLimits.maxTimeMS / 1000) seconds, so the server stopped it. Match on an indexed field first, or narrow the $match."
                    )
                }

                let format = EJSONFormat(mode: .editor, pretty: false, keyOrder: .document)
                var written: [OrderedJSON] = []
                var bytes = 0
                var truncated = false
                for document in documents.prefix(request.limit) {
                    let text: String
                    do {
                        text = try ExtendedJSON.stringify(document, format: format)
                    } catch {
                        return .failure(
                            "Result \(written.count + 1) couldn't be written as Extended JSON: \(error)"
                        )
                    }
                    if bytes + text.utf8.count > FindLimits.maxOutputBytes {
                        guard !written.isEmpty else {
                            return .failure(
                                "The first result is larger than \(FindLimits.maxOutputBytes / 1000) KB. Add a $project stage to return fewer fields."
                            )
                        }
                        truncated = true
                        break
                    }
                    written.append(.raw(text))
                    bytes += text.utf8.count
                }
                let result: OrderedJSON = .object([
                    ("connection", .string(connection.alias)),
                    ("database", .string(request.database)),
                    ("collection", .string(request.collection)),
                    ("pipeline", .string(request.pipelineText)),
                    ("limit", .int(request.limit)),
                    ("returned", .int(written.count)),
                    ("hasMore", .bool(documents.count > request.limit || truncated)),
                    ("truncated", .bool(truncated)),
                    ("documents", .array(written)),
                ])
                return .success(result.written())
            }
        })

    /// aggregate's arguments, checked before connecting.
    struct AggregateRequest: Sendable {
        var database: String
        var collection: String
        var pipelineText: String
        var pipeline: Document
        var limit: Int

        /// Stages an assistant may not run: they write, or never finish.
        static let refusedStages: Set<String> = ["$out", "$merge", "$changeStream"]

        static func parse(_ arguments: [String: JSONValue]) -> Result<
            AggregateRequest, MCPConnections.Refusal
        > {
            func fail(_ message: String) -> Result<AggregateRequest, MCPConnections.Refusal> {
                .failure(MCPConnections.Refusal(message: message))
            }
            guard let database = nonEmptyString(arguments["database"]) else {
                return fail("database is required: a database name from list_databases.")
            }
            guard let collection = nonEmptyString(arguments["collection"]) else {
                return fail("collection is required: a collection name from list_collections.")
            }

            let pipelineText: String
            switch arguments["pipeline"] {
            case .string(let value)?:
                pipelineText = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !pipelineText.isEmpty else {
                    return fail("pipeline is empty. Write [] for every document as it is.")
                }
            case nil, .null?:
                return fail("pipeline is required, as text: an array of stages.")
            default:
                return fail(
                    "pipeline must be text in Extended JSON or mongosh syntax, such as [{$match: {status: \"shipped\"}}], not a JSON array: key order and BSON types would be lost."
                )
            }
            let parsed: Document
            do {
                parsed = try ExtendedJSON.parseDocument(pipelineText)
            } catch {
                return fail("pipeline isn't valid Extended JSON or mongosh syntax: \(error)")
            }
            // A single stage without [ ] is accepted, as in the Aggregation
            // pane.
            var pipeline = Document(isArray: true)
            if parsed.isArray {
                pipeline = parsed
            } else {
                pipeline.append(parsed)
            }
            for (index, stage) in pipeline.values.enumerated() {
                guard let stage = stage as? Document, !stage.isArray, stage.count == 1,
                    let name = stage.keys.first, name.hasPrefix("$")
                else {
                    return fail(
                        "Stage \(index + 1) isn't a stage: each one is a document with a single $ operator, such as {$match: {…}}."
                    )
                }
            }
            if let stage = firstRefusedStage(in: pipeline) {
                return fail(
                    "\(stage) can't be used: aggregate only reads. $out and $merge write, and $changeStream never finishes."
                )
            }

            let limit: Int
            switch arguments["limit"] {
            case nil, .null?: limit = FindLimits.defaultLimit
            case .int(let value)?: limit = value
            case .double(let value)? where value.rounded() == value: limit = Int(value)
            default: return fail("limit must be a whole number.")
            }
            guard (1...FindLimits.maxLimit).contains(limit) else {
                return fail("limit must be between 1 and \(FindLimits.maxLimit).")
            }

            return .success(
                AggregateRequest(
                    database: database, collection: collection, pipelineText: pipelineText,
                    pipeline: pipeline, limit: limit))
        }

        /// The first refused stage anywhere in the pipeline, including the
        /// sub-pipelines of $lookup, $facet and $unionWith.
        static func firstRefusedStage(in document: Document) -> String? {
            for pair in document.pairs {
                if !document.isArray, refusedStages.contains(pair.key) {
                    return pair.key
                }
                if let nested = pair.value as? Document, let found = firstRefusedStage(in: nested) {
                    return found
                }
            }
            return nil
        }
    }
}

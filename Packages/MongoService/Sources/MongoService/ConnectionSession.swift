import Foundation
import Logging
import MongoCore
import MongoKitten

/// Receives driver + session log lines for the app's log window.
public typealias MongoLogSink = @Sendable (_ level: String, _ message: String) -> Void

/// swift-log handler bridging MongoKitten's logger into a sink closure.
private struct SinkLogHandler: LogHandler {
    let sink: MongoLogSink
    var logLevel: Logger.Level = .info
    var metadata: Logger.Metadata = [:]

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?,
        source: String, file: String, function: String, line: UInt
    ) {
        sink(level.rawValue, message.description)
    }
}

/// Errors surfaced by `ConnectionSession`, normalized for the UI layer.
public struct MongoServiceError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public let code: Int?

    init(_ message: String, code: Int? = nil) {
        self.message = message
        self.code = code
    }

    public var description: String {
        if let code { return "\(message) (code \(code))" }
        return message
    }
}

/// One live connection to a MongoDB deployment (standalone, replica set,
/// sharded cluster, or Atlas via `mongodb+srv://`).
///
/// This is the only layer that talks to MongoKitten — the UI goes through
/// here exclusively (docs/modernization-plan.md §3). All operations are
/// async and run on the driver's connection pool; the actor serializes
/// session state, not I/O.
public actor ConnectionSession {
    public let settings: ConnectionSettings
    private var cluster: MongoCluster?
    private let logger: Logger?

    /// Validates and stores the connection string without connecting.
    /// Accepts everything the MongoDB connection-string spec allows,
    /// including `mongodb+srv://` (SRV lookup happens on connect).
    /// An optional `logSink` receives the driver's log lines.
    public init(connectionString: String, logSink: MongoLogSink? = nil) throws {
        do {
            // MongoKitten's URI dialect: it understands `sslVerify` rather
            // than the standard `tlsAllowInvalidCertificates`. Translate so
            // spec-compliant strings (e.g. pasted from Compass) work.
            var connectionString = connectionString
            let lower = connectionString.lowercased()
            if lower.contains("tlsallowinvalidcertificates=true"), !lower.contains("sslverify=") {
                connectionString += connectionString.contains("?") ? "&sslVerify=false" : "?sslVerify=false"
            }
            self.settings = try ConnectionSettings(connectionString)
        } catch {
            throw MongoServiceError("Invalid connection string: \(error)")
        }
        if let logSink {
            var logger = Logger(label: "mongohubplus.driver") { _ in
                SinkLogHandler(sink: logSink)
            }
            logger.logLevel = .info
            self.logger = logger
        } else {
            self.logger = nil
        }
    }

    /// Establishes the connection (performs SRV resolution, TLS handshake,
    /// authentication) and verifies it with a `ping`.
    public func connect() async throws {
        guard cluster == nil else { return }
        do {
            let cluster: MongoCluster
            if let logger {
                cluster = try await MongoCluster(connectingTo: settings, logger: logger)
            } else {
                cluster = try await MongoCluster(connectingTo: settings)
            }
            // MongoKitten ignores the readPreference URI option; secondary
            // reads need the cluster-level flag.
            if let readPreference = settings.queryParameters["readPreference"]?.lowercased(),
                ["secondary", "secondarypreferred", "primarypreferred", "nearest"]
                    .contains(readPreference)
            {
                cluster.slaveOk = true
            }
            self.cluster = cluster
            _ = try await runCommand(["ping": 1], onDatabase: "admin")
        } catch let error as MongoServiceError {
            self.cluster = nil
            throw error
        } catch {
            self.cluster = nil
            throw MongoServiceError("Failed to connect: \(error)")
        }
    }

    public var isConnected: Bool {
        cluster != nil
    }

    public func disconnect() async {
        if let cluster {
            await cluster.disconnect()
        }
        cluster = nil
    }

    // MARK: - Raw commands (the escape hatch everything exotic goes through)

    /// Runs an arbitrary database command and returns the raw reply document.
    /// Throws when the server reports `ok: 0`.
    @discardableResult
    public func runCommand(_ command: Document, onDatabase database: String) async throws -> Document {
        let cluster = try requireCluster()
        let connection = try await cluster.next(for: .basic)
        let reply = try await connection.execute(
            command,
            namespace: MongoNamespace(to: "$cmd", inDatabase: database),
            sessionId: nil
        )
        guard let document = reply.documents.first else {
            throw MongoServiceError("Empty reply from server")
        }
        let ok: Bool
        switch document["ok"] {
        case let d as Double: ok = d == 1
        case let i as Int32: ok = i == 1
        case let i as Int: ok = i == 1
        case let b as Bool: ok = b
        default: ok = false
        }
        guard ok else {
            let message = document["errmsg"] as? String ?? "Command failed"
            let code = (document["code"] as? Int32).map(Int.init) ?? document["code"] as? Int
            throw MongoServiceError(message, code: code)
        }
        return document
    }

    // MARK: - Topology / stats

    public func serverStatus() async throws -> Document {
        try await runCommand(["serverStatus": 1], onDatabase: "admin")
    }

    public func databaseStats(database: String) async throws -> Document {
        try await runCommand(["dbStats": 1], onDatabase: database)
    }

    public func collectionStats(database: String, collection: String) async throws -> Document {
        try await runCommand(["collStats": collection], onDatabase: database)
    }

    public func listDatabaseNames() async throws -> [String] {
        let reply = try await runCommand(
            ["listDatabases": 1, "nameOnly": true], onDatabase: "admin")
        guard let databases = reply["databases"] as? Document else {
            throw MongoServiceError("Malformed listDatabases reply")
        }
        return databases.values.compactMap { ($0 as? Document)?["name"] as? String }.sorted()
    }

    /// The collection's `listCollections` entry (options carry the
    /// validator, validationLevel, validationAction, collation, …).
    public func collectionInfo(database: String, collection: String) async throws -> Document {
        var command = Document()
        command["listCollections"] = Int32(1)
        command["filter"] = ["name": collection] as Document
        let entries = try await collectCursor(command: command, onDatabase: database)
        return entries.first ?? Document()
    }

    public func listCollectionNames(database: String) async throws -> [String] {
        let cluster = try requireCluster()
        let collections = try await cluster[database].listCollections()
        return collections.map(\.name).sorted()
    }

    // MARK: - Queries

    public struct FindOptions: Sendable {
        public var projection: Document?
        public var sort: Document?
        public var skip: Int
        public var limit: Int

        public init(
            projection: Document? = nil, sort: Document? = nil, skip: Int = 0, limit: Int = 30
        ) {
            self.projection = projection
            self.sort = sort
            self.skip = skip
            self.limit = limit
        }
    }

    public func find(
        database: String, collection: String, filter: Document,
        options: FindOptions = FindOptions()
    ) async throws -> [Document] {
        let cluster = try requireCluster()
        var builder = cluster[database][collection].find(filter)
        if let projection = options.projection, !projection.isEmpty {
            builder = builder.project(projection)
        }
        if let sort = options.sort, !sort.isEmpty {
            builder = builder.sort(sort)
        }
        builder = builder.skip(options.skip).limit(options.limit)

        var results: [Document] = []
        do {
            for try await document in builder {
                results.append(document)
            }
        } catch {
            throw MongoServiceError("Find failed: \(error)")
        }
        return results
    }

    public func count(database: String, collection: String, filter: Document) async throws -> Int {
        let cluster = try requireCluster()
        do {
            return try await cluster[database][collection]
                .count(filter.isEmpty ? nil : filter)
        } catch {
            throw MongoServiceError("Count failed: \(error)")
        }
    }

    // MARK: - Cursor commands (aggregate, export streaming)

    /// Runs a cursor-returning command (`aggregate`, `listIndexes`, …) and
    /// drains it fully with `getMore`, honoring Task cancellation.
    public func collectCursor(
        command: Document, onDatabase database: String, batchSize: Int = 1000
    ) async throws -> [Document] {
        var results: [Document] = []
        var reply = try await runCommand(command, onDatabase: database)
        while true {
            guard let cursor = reply["cursor"] as? Document else {
                throw MongoServiceError("Malformed cursor reply")
            }
            let batch =
                (cursor["firstBatch"] as? Document ?? cursor["nextBatch"] as? Document)?
                .values.compactMap { $0 as? Document } ?? []
            results.append(contentsOf: batch)
            let cursorID = cursor["id"] as? Int ?? 0
            let namespace = cursor["ns"] as? String ?? ""
            if cursorID == 0 {
                return results
            }
            let collection = namespace.split(separator: ".").dropFirst().joined(separator: ".")
            if Task.isCancelled {
                var kill = Document()
                kill["killCursors"] = collection
                var ids = Document(isArray: true)
                ids["0"] = cursorID
                kill["cursors"] = ids
                _ = try? await runCommand(kill, onDatabase: database)
                throw CancellationError()
            }
            var getMore = Document()
            getMore["getMore"] = cursorID
            getMore["collection"] = collection
            getMore["batchSize"] = batchSize
            reply = try await runCommand(getMore, onDatabase: database)
        }
    }

    /// Streams a cursor-returning command batch-by-batch without holding the
    /// full result set in memory (used by file export). Cancelling the
    /// consuming task kills the server-side cursor.
    public nonisolated func cursorBatches(
        command: Document, onDatabase database: String, batchSize: Int = 1000
    ) -> AsyncThrowingStream<[Document], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var reply = try await self.runCommand(command, onDatabase: database)
                    while true {
                        guard let cursor = reply["cursor"] as? Document else {
                            throw MongoServiceError("Malformed cursor reply")
                        }
                        let batch =
                            (cursor["firstBatch"] as? Document ?? cursor["nextBatch"] as? Document)?
                            .values.compactMap { $0 as? Document } ?? []
                        continuation.yield(batch)
                        let cursorID = cursor["id"] as? Int ?? 0
                        let namespace = cursor["ns"] as? String ?? ""
                        if cursorID == 0 {
                            continuation.finish()
                            return
                        }
                        let collection = namespace.split(separator: ".").dropFirst()
                            .joined(separator: ".")
                        if Task.isCancelled {
                            var kill = Document()
                            kill["killCursors"] = collection
                            var ids = Document(isArray: true)
                            ids["0"] = cursorID
                            kill["cursors"] = ids
                            _ = try? await self.runCommand(kill, onDatabase: database)
                            continuation.finish(throwing: CancellationError())
                            return
                        }
                        var getMore = Document()
                        getMore["getMore"] = cursorID
                        getMore["collection"] = collection
                        getMore["batchSize"] = batchSize
                        reply = try await self.runCommand(getMore, onDatabase: database)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Opens a change stream on a collection and yields events until the
    /// consuming task is cancelled. Requires a replica set or Atlas; on a
    /// standalone server the initial command fails and the stream throws.
    /// `fullDocument: updateLookup` is requested so updates carry the
    /// post-image when available.
    public nonisolated func changeStream(
        database: String, collection: String
    ) -> AsyncThrowingStream<Document, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var stage = Document()
                    stage["$changeStream"] = ["fullDocument": "updateLookup"] as Document
                    var pipeline = Document(isArray: true)
                    pipeline["0"] = stage
                    var command = Document()
                    command["aggregate"] = collection
                    command["pipeline"] = pipeline
                    command["cursor"] = Document()
                    var reply = try await self.runCommand(command, onDatabase: database)
                    while true {
                        guard let cursor = reply["cursor"] as? Document else {
                            throw MongoServiceError("Malformed cursor reply")
                        }
                        let batch =
                            (cursor["firstBatch"] as? Document ?? cursor["nextBatch"] as? Document)?
                            .values.compactMap { $0 as? Document } ?? []
                        for event in batch {
                            continuation.yield(event)
                        }
                        let cursorID = cursor["id"] as? Int ?? 0
                        let namespace = cursor["ns"] as? String ?? ""
                        if cursorID == 0 {
                            continuation.finish()
                            return
                        }
                        let cursorCollection = namespace.split(separator: ".").dropFirst()
                            .joined(separator: ".")
                        if Task.isCancelled {
                            var kill = Document()
                            kill["killCursors"] = cursorCollection
                            var ids = Document(isArray: true)
                            ids["0"] = cursorID
                            kill["cursors"] = ids
                            _ = try? await self.runCommand(kill, onDatabase: database)
                            continuation.finish()
                            return
                        }
                        var getMore = Document()
                        getMore["getMore"] = cursorID
                        getMore["collection"] = cursorCollection
                        getMore["batchSize"] = 100
                        // Tailable-await cursor: block up to 2s per round so
                        // cancellation is noticed promptly.
                        getMore["maxTimeMS"] = Int32(2000)
                        reply = try await self.runCommand(getMore, onDatabase: database)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Runs an aggregation pipeline and returns all result documents.
    public func aggregate(
        database: String, collection: String, pipeline: Document, options: Document? = nil
    ) async throws -> [Document] {
        var command = Document()
        command["aggregate"] = collection
        command["pipeline"] = pipeline
        command["cursor"] = ["batchSize": Int32(1000)] as Document
        if let options {
            for pair in options.pairs {
                command[pair.key] = pair.value
            }
        }
        return try await collectCursor(command: command, onDatabase: database)
    }

    // MARK: -

    private func requireCluster() throws -> MongoCluster {
        guard let cluster else {
            throw MongoServiceError("Not connected")
        }
        return cluster
    }
}

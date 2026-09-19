import Foundation
import Logging
import MongoCore
import MongoKitten
import NIOCore

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

/// A handle on a running server operation, so the UI can stop it.
///
/// Every command issued with a token carries the same logical session id, and
/// `killSessions` interrupts whatever that session is doing. That is the only
/// mechanism that reaches the *initial* `find`: `killCursors` needs a cursor
/// that does not exist yet while the first batch is still being computed,
/// which is exactly the case when someone runs a query with no usable index.
/// Measured against MongoDB 8.3: the operation leaves `currentOp` and the
/// client fails with `Interrupted` (code 11601) in milliseconds.
///
/// Abandoning the client-side `await` is *not* enough — the server keeps
/// running the operation. Killing the client outright did not stop it either
/// (observed still running 42s later), so nothing here relies on that.
public struct OperationToken: Sendable, Hashable {
    let id: UUID

    public init() {
        self.id = UUID()
    }

    /// `{ id: UUID }` — the server's logical session id for this operation.
    var lsid: Document {
        var bytes = [UInt8](repeating: 0, count: 16)
        withUnsafeBytes(of: id.uuid) { raw in
            for index in 0..<16 { bytes[index] = raw[index] }
        }
        var document = Document()
        document["id"] = Binary(subType: .uuid, buffer: ByteBuffer(bytes: bytes))
        return document
    }

    /// Tags the operation in `currentOp` and the server log, so a stuck query
    /// can be identified from outside the app too.
    var comment: String { "MongoHub Plus \(id.uuidString)" }
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
    /// A second connection kept for `stop(_:)` alone. The query connection is
    /// blocked waiting for its own reply, and MongoKitten hands the same
    /// connection back to the next caller, so a kill sent through the normal
    /// path queues behind the very query it is meant to interrupt and times
    /// out. Measured: same connection = `killSessions` never lands; separate
    /// connection = it returns in 1ms.
    private var controlCluster: MongoCluster?
    private var controlWarmup: Task<Void, Never>?
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
            // Warm the control connection in the background: Stop is pressed
            // in a hurry, and on Atlas a cold connect (SRV, TLS, SCRAM) would
            // otherwise land on the one action that has to be immediate.
            controlWarmup = Task { [weak self] in
                _ = try? await self?.openControlCluster()
            }
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
        controlWarmup?.cancel()
        controlWarmup = nil
        if let controlCluster {
            await controlCluster.disconnect()
        }
        controlCluster = nil
        if let cluster {
            await cluster.disconnect()
        }
        cluster = nil
    }

    // MARK: - Stopping a running operation (feature-spec 3.20)

    /// Interrupts the operation running under `token`, on the server.
    ///
    /// Best effort by design: a query that already finished, or one whose
    /// session the server has forgotten, is not an error worth surfacing —
    /// the caller has stopped caring about the result either way.
    public func stop(_ token: OperationToken) async {
        let started = Date()
        do {
            let control = try await openControlCluster()
            var kill = Document()
            var sessions = Document(isArray: true)
            sessions["0"] = token.lsid
            kill["killSessions"] = sessions
            _ = try await execute(kill, on: control, database: "admin")
            // Logged on success as well as failure: "did the server really
            // stop, or does the window just say so?" is the whole question
            // this button has to answer, and without a line here a stop
            // leaves no trace to check. `acknowledged` is the honest word —
            // the server accepts the kill and interrupts the operation at its
            // next interrupt point. The id matches the `comment` the query
            // carries, so it lines up with $currentOp and the server log.
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            logger?.info(
                "Stopped \(token.comment) — server acknowledged killSessions in \(elapsed)ms")
        } catch {
            logger?.info("Stop failed for \(token.comment): \(error)")
        }
    }

    /// The control connection, built on first use and kept afterwards.
    private func openControlCluster() async throws -> MongoCluster {
        if let controlCluster { return controlCluster }
        let control: MongoCluster
        if let logger {
            control = try await MongoCluster(connectingTo: settings, logger: logger)
        } else {
            control = try await MongoCluster(connectingTo: settings)
        }
        controlCluster = control
        return control
    }

    // MARK: - Raw commands (the escape hatch everything exotic goes through)

    /// Runs an arbitrary database command and returns the raw reply document.
    /// Throws when the server reports `ok: 0`.
    @discardableResult
    public func runCommand(
        _ command: Document, onDatabase database: String, token: OperationToken? = nil
    ) async throws -> Document {
        var command = command
        if let token {
            command["lsid"] = token.lsid
            if command["comment"] == nil {
                command["comment"] = token.comment
            }
        }
        return try await execute(command, on: try requireCluster(), database: database)
    }

    /// Runs `body`, and if we stop waiting for its result for any reason —
    /// the user pressed Stop, the driver hit its own 30-second query timeout,
    /// the connection dropped — makes sure the server stops too. An abandoned
    /// operation is not reaped by anything else: killing the client outright
    /// left one running for 42 seconds and counting.
    private func stoppingIfAbandoned<T>(
        _ token: OperationToken, _ body: () async throws -> T
    ) async throws -> T {
        do {
            return try await body()
        } catch {
            await stop(token)
            throw error
        }
    }

    private func execute(
        _ command: Document, on cluster: MongoCluster, database: String
    ) async throws -> Document {
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

    /// Runs a `find` and returns every matching document.
    ///
    /// Built as a raw command rather than through MongoKitten's query builder
    /// because `FindCommand` has no `lsid` field, and without one there is no
    /// session for `stop(_:)` to kill.
    public func find(
        database: String, collection: String, filter: Document,
        options: FindOptions = FindOptions(), token: OperationToken? = nil
    ) async throws -> [Document] {
        var command = Document()
        command["find"] = collection
        command["filter"] = filter
        if let projection = options.projection, !projection.isEmpty {
            command["projection"] = projection
        }
        if let sort = options.sort, !sort.isEmpty {
            command["sort"] = sort
        }
        if options.skip > 0 {
            command["skip"] = options.skip
        }
        if options.limit > 0 {
            command["limit"] = options.limit
        }
        do {
            return try await collectCursor(
                command: command, onDatabase: database,
                batchSize: options.limit > 0 ? min(options.limit, 1000) : 1000,
                token: token)
        } catch let error as MongoServiceError {
            throw error
        } catch {
            throw MongoServiceError("Find failed: \(error)")
        }
    }

    /// Counts matching documents.
    ///
    /// Raw command rather than the query builder for the same reason `find` is:
    /// a count with no usable index is usually the *slowest* part of running a
    /// query — the find stops at the limit, the count reads everything — so it
    /// is the operation most in need of an lsid to stop.
    public func count(
        database: String, collection: String, filter: Document, token: OperationToken? = nil
    ) async throws -> Int {
        var command = Document()
        command["count"] = collection
        if !filter.isEmpty {
            command["query"] = filter
        }
        do {
            let reply: Document
            if let token {
                reply = try await stoppingIfAbandoned(token) {
                    try await runCommand(command, onDatabase: database, token: token)
                }
            } else {
                reply = try await runCommand(command, onDatabase: database)
            }
            switch reply["n"] {
            case let value as Int32: return Int(value)
            case let value as Int: return value
            case let value as Double: return Int(value)
            default: throw MongoServiceError("Malformed count reply")
            }
        } catch let error as MongoServiceError {
            throw error
        } catch {
            throw MongoServiceError("Count failed: \(error)")
        }
    }

    // MARK: - Cursor commands (aggregate, export streaming)

    /// Runs a cursor-returning command (`aggregate`, `listIndexes`, …) and
    /// drains it fully with `getMore`, honoring Task cancellation.
    public func collectCursor(
        command: Document, onDatabase database: String, batchSize: Int = 1000,
        token: OperationToken? = nil
    ) async throws -> [Document] {
        guard let token else {
            return try await drainCursor(
                command: command, onDatabase: database, batchSize: batchSize, token: nil)
        }
        return try await stoppingIfAbandoned(token) {
            try await drainCursor(
                command: command, onDatabase: database, batchSize: batchSize, token: token)
        }
    }

    private func drainCursor(
        command: Document, onDatabase database: String, batchSize: Int, token: OperationToken?
    ) async throws -> [Document] {
        var results: [Document] = []
        var reply = try await runCommand(command, onDatabase: database, token: token)
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
                _ = try? await runCommand(kill, onDatabase: database, token: token)
                throw CancellationError()
            }
            var getMore = Document()
            getMore["getMore"] = cursorID
            getMore["collection"] = collection
            getMore["batchSize"] = batchSize
            reply = try await runCommand(getMore, onDatabase: database, token: token)
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
        database: String, collection: String, pipeline: Document, options: Document? = nil,
        token: OperationToken? = nil
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
        return try await collectCursor(command: command, onDatabase: database, token: token)
    }

    // MARK: -

    private func requireCluster() throws -> MongoCluster {
        guard let cluster else {
            throw MongoServiceError("Not connected")
        }
        return cluster
    }
}

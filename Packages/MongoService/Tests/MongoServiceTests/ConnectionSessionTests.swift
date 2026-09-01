import BSON
import ExtendedJSON
import Foundation
import Testing

@testable import MongoService

struct ConnectionStringTests {
    @Test func acceptsStandardAndSRVSchemes() throws {
        _ = try ConnectionSession(connectionString: "mongodb://localhost:27017")
        _ = try ConnectionSession(connectionString: "mongodb://user:pass@h1:27017,h2:27018/db?replicaSet=rs0&ssl=true")
        _ = try ConnectionSession(
            connectionString: "mongodb+srv://user:pass@cluster0.example.mongodb.net/mydb?retryWrites=true&w=majority")
    }

    /// The standard `tlsAllowInvalidCertificates` option must reach the
    /// driver, which only understands its own `sslVerify` spelling.
    @Test func translatesTLSAllowInvalidCertificates() async throws {
        let weak = try ConnectionSession(
            connectionString: "mongodb://localhost:27017/?tls=true&tlsAllowInvalidCertificates=true")
        #expect(await weak.settings.useSSL)
        #expect(await weak.settings.verifySSLCertificates == false)

        let strict = try ConnectionSession(connectionString: "mongodb://localhost:27017/?tls=true")
        #expect(await strict.settings.verifySSLCertificates)

        // An explicit sslVerify wins — no double-append, no override.
        let explicit = try ConnectionSession(
            connectionString:
                "mongodb://localhost:27017/?tlsAllowInvalidCertificates=true&sslVerify=true")
        #expect(await explicit.settings.verifySSLCertificates)

        // No query string yet → appended with `?`.
        let bare = try ConnectionSession(
            connectionString: "mongodb://localhost:27017?tlsAllowInvalidCertificates=true")
        #expect(await bare.settings.verifySSLCertificates == false)
    }

    @Test func retainsReadPreferenceQueryParameter() async throws {
        let session = try ConnectionSession(
            connectionString: "mongodb://h1:27017,h2:27017/?replicaSet=rs0&readPreference=secondaryPreferred")
        #expect(await session.settings.queryParameters["readPreference"] == "secondaryPreferred")
    }

    @Test func rejectsGarbage() {
        #expect(throws: (any Error).self) {
            _ = try ConnectionSession(connectionString: "http://not-mongo")
        }
        #expect(throws: (any Error).self) {
            _ = try ConnectionSession(connectionString: "")
        }
    }
}

/// Integration tests against a real server. Skipped unless the environment
/// provides a URI:
///   MONGOHUBPLUS_TEST_URI       — e.g. mongodb://localhost:27017
///                               (local: `docker run -p 27017:27017 mongo:7`)
///   MONGOHUBPLUS_TEST_ATLAS_URI — an Atlas mongodb+srv:// connection string
struct IntegrationTests {
    static let localURI = ProcessInfo.processInfo.environment["MONGOHUBPLUS_TEST_URI"]
    static let atlasURI = ProcessInfo.processInfo.environment["MONGOHUBPLUS_TEST_ATLAS_URI"]

    static func exercise(uri: String, allowWrites: Bool) async throws {
        let session = try ConnectionSession(connectionString: uri)
        try await session.connect()
        #expect(await session.isConnected)

        // Topology + stats.
        let status = try await session.serverStatus()
        #expect(status["version"] is String)
        let databases = try await session.listDatabaseNames()
        #expect(!databases.isEmpty)

        if allowWrites {
            let db = "mongohubplus_m0_test"
            let coll = "smoke"
            _ = try? await session.runCommand(["dropDatabase": 1], onDatabase: db)
            for i in 0..<5 {
                var doc = Document()
                doc["_id"] = ObjectId()
                doc["i"] = Int32(i)
                doc["big"] = 5_000_000_000
                doc["when"] = Date()
                try await session.runCommand(
                    ["insert": coll, "documents": [doc] as Document], onDatabase: db)
            }

            let count = try await session.count(database: db, collection: coll, filter: [:])
            #expect(count == 5)

            var filter = Document()
            filter["i"] = ["$gte": Int32(3)] as Document
            let found = try await session.find(
                database: db, collection: coll, filter: filter,
                options: .init(sort: ["i": Int32(1)] as Document))
            #expect(found.count == 2)
            #expect(found.first?["i"] as? Int32 == 3)
            #expect(found.first?["big"] as? Int == 5_000_000_000)

            let collections = try await session.listCollectionNames(database: db)
            #expect(collections.contains(coll))

            // Update command (as the Update pane issues it).
            var updateCommand = Document()
            updateCommand["update"] = coll
            var updates = Document(isArray: true)
            var updateSpec = Document()
            updateSpec["q"] = ["i": ["$gte": Int32(0)] as Document] as Document
            updateSpec["u"] = ["$set": ["flag": true] as Document] as Document
            updateSpec["multi"] = true
            updates["0"] = updateSpec
            updateCommand["updates"] = updates
            let updateReply = try await session.runCommand(updateCommand, onDatabase: db)
            #expect(updateReply["n"] as? Int32 == 5)

            // Index create / list / drop (as the Index pane issues them).
            var createIndex = Document()
            createIndex["createIndexes"] = coll
            var indexes = Document(isArray: true)
            var indexSpec = Document()
            indexSpec["key"] = ["i": Int32(1)] as Document
            indexSpec["name"] = "i_1"
            indexSpec["expireAfterSeconds"] = Int32(3600)
            indexes["0"] = indexSpec
            createIndex["indexes"] = indexes
            _ = try await session.runCommand(createIndex, onDatabase: db)

            var listIndexes = Document()
            listIndexes["listIndexes"] = coll
            let indexList = try await session.collectCursor(command: listIndexes, onDatabase: db)
            #expect(indexList.contains { $0["name"] as? String == "i_1" })
            #expect(
                indexList.first { $0["name"] as? String == "i_1" }?["expireAfterSeconds"]
                    as? Int32 == 3600)

            var dropIndex = Document()
            dropIndex["dropIndexes"] = coll
            dropIndex["index"] = "i_1"
            _ = try await session.runCommand(dropIndex, onDatabase: db)

            // Aggregation, incl. a getMore drain (>101 default first batch).
            var bulk = Document(isArray: true)
            for i in 0..<300 {
                var doc = Document()
                doc["i"] = Int32(i)
                bulk[String(i)] = doc
            }
            try await session.runCommand(
                ["insert": "aggsrc", "documents": bulk] as Document, onDatabase: db)
            var pipeline = Document(isArray: true)
            pipeline["0"] = ["$match": ["i": ["$lt": Int32(250)] as Document] as Document] as Document
            pipeline["1"] = ["$sort": ["i": Int32(1)] as Document] as Document
            let aggregated = try await session.aggregate(
                database: db, collection: "aggsrc", pipeline: pipeline)
            #expect(aggregated.count == 250)
            #expect(aggregated.first?["i"] as? Int32 == 0)

            // Delete command (as the Remove pane issues it).
            var deleteCommand = Document()
            deleteCommand["delete"] = coll
            var deletes = Document(isArray: true)
            var deleteSpec = Document()
            deleteSpec["q"] = Document()
            deleteSpec["limit"] = Int32(0)
            deletes["0"] = deleteSpec
            deleteCommand["deletes"] = deletes
            let deleteReply = try await session.runCommand(deleteCommand, onDatabase: db)
            #expect(deleteReply["n"] as? Int32 == 5)

            // Export/import round trip: stream find batches (getMore path),
            // canonical JSON-Lines, parse back, insert into a new collection.
            var findCommand = Document()
            findCommand["find"] = "aggsrc"
            findCommand["batchSize"] = Int32(120)
            var lines: [String] = []
            for try await batch in session.cursorBatches(
                command: findCommand, onDatabase: db, batchSize: 120)
            {
                for document in batch {
                    lines.append(try ExtendedJSON.stringify(document, format: .canonical))
                }
            }
            #expect(lines.count == 300)
            var reimport: [Document] = []
            for line in lines {
                reimport.append(try ExtendedJSON.parseDocument(line))
            }
            var restoreDocs = Document(isArray: true)
            for (index, doc) in reimport.enumerated() {
                restoreDocs[String(index)] = doc
            }
            try await session.runCommand(
                ["insert": "aggsrc_restored", "documents": restoreDocs] as Document,
                onDatabase: db)
            let restoredCount = try await session.count(
                database: db, collection: "aggsrc_restored", filter: Document())
            #expect(restoredCount == 300)

            // renameCollection (admin), as the sidebar CRUD issues it.
            var rename = Document()
            rename["renameCollection"] = "\(db).aggsrc"
            rename["to"] = "\(db).aggsrc2"
            _ = try await session.runCommand(rename, onDatabase: "admin")
            let renamed = try await session.listCollectionNames(database: db)
            #expect(renamed.contains("aggsrc2") && !renamed.contains("aggsrc"))

            let stats = try await session.collectionStats(database: db, collection: coll)
            #expect(stats["count"] != nil)

            _ = try await session.runCommand(["dropDatabase": 1], onDatabase: db)
        }

        await session.disconnect()
        #expect(!(await session.isConnected))
    }

    @Test(.enabled(if: localURI != nil))
    func localMongod() async throws {
        try await Self.exercise(uri: Self.localURI!, allowWrites: true)
    }

    @Test(.enabled(if: atlasURI != nil))
    func atlasCluster() async throws {
        // Read-mostly: Atlas free tiers restrict some commands; writes are
        // still exercised in a scratch database.
        try await Self.exercise(uri: Self.atlasURI!, allowWrites: true)
    }
}

import Foundation

/// Per-collection Find history (legacy: last 20 queries, MRU). Fixes the
/// legacy scoping bug: keyed by connection UUID + database + collection
/// (feature-spec 3.4).
struct QueryHistoryEntry: Codable, Equatable {
    var criteria: String
    var fields: String
    var sort: String
    var skip: Int
    var limit: Int
}

@MainActor
final class QueryHistoryStore {
    static let shared = QueryHistoryStore()

    private static let defaultsKey = "queryHistory.v1"
    private static let maxPerCollection = 20

    private var storage: [String: [QueryHistoryEntry]]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
            let decoded = try? JSONDecoder().decode([String: [QueryHistoryEntry]].self, from: data)
        {
            storage = decoded
        } else {
            storage = [:]
        }
    }

    private func key(_ connectionID: UUID, _ database: String, _ collection: String) -> String {
        "\(connectionID.uuidString)|\(database).\(collection)"
    }

    func entries(connectionID: UUID, database: String, collection: String) -> [QueryHistoryEntry] {
        storage[key(connectionID, database, collection)] ?? []
    }

    /// MRU insert: an entry with the same criteria replaces the old one.
    func add(
        _ entry: QueryHistoryEntry, connectionID: UUID, database: String, collection: String
    ) {
        guard !entry.criteria.isEmpty else { return }
        let storageKey = key(connectionID, database, collection)
        var list = storage[storageKey] ?? []
        list.removeAll { $0.criteria == entry.criteria }
        list.insert(entry, at: 0)
        if list.count > Self.maxPerCollection {
            list.removeLast(list.count - Self.maxPerCollection)
        }
        storage[storageKey] = list
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(storage) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

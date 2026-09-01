import Foundation

/// Persistent list of saved connections: a JSON file in Application Support
/// (feature-spec 1.8 — replaces legacy Core Data). Main-actor; UI observes
/// via `Notification.Name.connectionStoreDidChange`.
@MainActor
final class ConnectionStore {
    static let shared = ConnectionStore()

    private(set) var connections: [MongoConnection] = []

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let dir = support.appendingPathComponent("MongoHub Plus", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("connections.json")
        }
        load()
    }

    private struct FileFormat: Codable {
        var version: Int
        var connections: [MongoConnection]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let file = try JSONDecoder().decode(FileFormat.self, from: data)
            connections = file.connections.sorted(by: Self.displayOrder)
        } catch {
            NSLog("ConnectionStore: failed to load \(fileURL.path): \(error)")
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(FileFormat(version: 1, connections: connections))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("ConnectionStore: failed to save: \(error)")
        }
        NotificationCenter.default.post(name: .connectionStoreDidChange, object: self)
    }

    func connection(id: UUID) -> MongoConnection? {
        connections.first { $0.id == id }
    }

    func connection(alias: String) -> MongoConnection? {
        connections.first { $0.alias == alias }
    }

    func isAliasInUse(_ alias: String, excluding id: UUID? = nil) -> Bool {
        connections.contains { $0.alias == alias && $0.id != id }
    }

    /// Inserts or updates, keeping the list sorted by alias (legacy sorted the
    /// list case-insensitively).
    func upsert(_ connection: MongoConnection) {
        connections.removeAll { $0.id == connection.id }
        connections.append(connection)
        connections.sort(by: Self.displayOrder)
        save()
    }

    /// Pinned connections sort first, then case-insensitive alias order.
    private static func displayOrder(_ a: MongoConnection, _ b: MongoConnection) -> Bool {
        if a.isPinned != b.isPinned { return a.isPinned }
        return a.alias.localizedCaseInsensitiveCompare(b.alias) == .orderedAscending
    }

    func setPinned(_ pinned: Bool, id: UUID) {
        guard var connection = connection(id: id) else { return }
        connection.pinned = pinned
        upsert(connection)
    }

    func delete(id: UUID) {
        connections.removeAll { $0.id == id }
        Keychain.deleteAll(for: id)
        save()
    }

    /// Legacy-style duplicate naming: "name - Copy", "name - Copy 2", …
    func duplicateAlias(for alias: String) -> String {
        var base = alias
        if let range = base.range(of: #" - Copy( \d+)?$"#, options: .regularExpression) {
            base = String(base[..<range.lowerBound])
        }
        var candidate = "\(base) - Copy"
        var n = 2
        while isAliasInUse(candidate) {
            candidate = "\(base) - Copy \(n)"
            n += 1
        }
        return candidate
    }
}

extension Notification.Name {
    static let connectionStoreDidChange = Notification.Name("MongoHub Plus.connectionStoreDidChange")
}

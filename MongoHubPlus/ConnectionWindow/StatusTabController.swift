import AppKit
import BSON
import MongoService

/// The Status tab (legacy MHStatusViewController): renders serverStatus /
/// dbStats / collStats documents in a footer-less outline, retitling itself.
@MainActor
final class StatusTabController: TabItemViewController {
    private let session: () -> ConnectionSession?
    private let outline = DocumentOutlineViewController(
        options: .init(
            showsFooter: false, showsRemoveButton: false, showsPagination: false,
            autosaveName: "status-outline"))

    init(session: @escaping () -> ConnectionSession?) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Server Stats")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        addChild(outline)
        view = outline.view
    }

    func showServerStatus() {
        title = String(localized: "Server Stats")
        load { try await $0.serverStatus() }
    }

    func showDatabaseStats(database: String) {
        title = String(localized: "\(database) Stats")
        load { try await $0.databaseStats(database: database) }
    }

    func showCollectionStats(database: String, collection: String) {
        title = String(localized: "\(database).\(collection) Stats")
        load { session in
            let stats = try await session.collectionStats(
                database: database, collection: collection)
            // $jsonSchema / validation rules (feature-spec 3.19): shown at
            // the top of the stats when the collection defines any.
            let info = try await session.collectionInfo(
                database: database, collection: collection)
            guard let options = info["options"] as? Document else { return stats }
            var validation = Document()
            for key in ["validator", "validationLevel", "validationAction"] {
                if let value = options[key] {
                    validation[key] = value
                }
            }
            guard !validation.isEmpty else { return stats }
            var merged = Document()
            merged["validation"] = validation
            for pair in stats.pairs {
                merged[pair.key] = pair.value
            }
            return merged
        }
    }

    private func load(_ operation: @escaping (ConnectionSession) async throws -> Document) {
        guard let session = session() else { return }
        Task {
            do {
                let stats = try await operation(session)
                self.outline.display(fields: stats)
            } catch {
                // Errors render inside the outline (legacy behavior).
                self.outline.displayError(String(describing: error))
            }
        }
    }
}

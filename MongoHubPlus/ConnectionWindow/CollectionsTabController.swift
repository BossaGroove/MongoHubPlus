import AppKit
import BSON
import MongoService

/// One database's collections as a table — storage, data, documents, indexes
/// (feature-spec 2.10). The Database Stats tab answers "how big is this
/// database"; this answers "which collection is responsible", which the
/// totals cannot.
///
/// Sizes read the same as everywhere else in the app (`ByteSize`), and a
/// double-click opens the collection's query tab, like the sidebar.
@MainActor
final class CollectionsTabController: TabItemViewController {
    struct Row {
        var name: String
        var properties: String
        var storageSize: Int?
        var dataSize: Int?
        var documents: Int?
        var averageSize: Int?
        var indexes: Int?
        var indexSize: Int?
        /// Why this row has no numbers — a view has no `collStats`, and a
        /// collection can be unreadable on its own.
        var problem: String?
    }

    private enum Column: String, CaseIterable {
        case name, properties, storage, data, documents, average, indexes, indexSize

        var title: String {
            switch self {
            case .name: return String(localized: "Collection")
            case .properties: return String(localized: "Properties")
            case .storage: return String(localized: "Storage size")
            case .data: return String(localized: "Data size")
            case .documents: return String(localized: "Documents")
            case .average: return String(localized: "Avg. document size")
            case .indexes: return String(localized: "Indexes")
            case .indexSize: return String(localized: "Total index size")
            }
        }

        var width: CGFloat {
            switch self {
            case .name: return 220
            case .properties: return 90
            case .average: return 140
            case .indexSize: return 130
            default: return 100
            }
        }

        /// Numbers read right-aligned; names and properties read left.
        var isNumeric: Bool {
            self != .name && self != .properties
        }
    }

    private let session: () -> ConnectionSession?
    private let openCollection: (String, String) -> Void
    private let tableView = NSTableView()
    private let spinner = QueryPaneUI.spinner()
    private let statusLabel = NSTextField(labelWithString: "")
    private var database: String = ""
    private var rows: [Row] = []
    private var sortColumn: Column = .storage
    private var sortAscending = false
    private var loadTask: Task<Void, Never>?

    init(
        session: @escaping () -> ConnectionSession?,
        openCollection: @escaping (String, String) -> Void
    ) {
        self.session = session
        self.openCollection = openCollection
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Collections")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func willRemoveFromTabHost() {
        loadTask?.cancel()
        loadTask = nil
    }

    override func loadView() {
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: .init(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = 60
            // Header clicks sort; the descriptor's key is the column id and
            // the sorting itself is done in `applySort`, because the values
            // are a mix of optional numbers and strings.
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(
                key: column.rawValue, ascending: true)
            tableView.addTableColumn(tableColumn)
        }
        // Seed the descriptor so the header carries the sort arrow from the
        // start, matching the order the first load is already in.
        tableView.sortDescriptors = [
            NSSortDescriptor(key: Column.storage.rawValue, ascending: false)
        ]
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowSizeStyle = .small
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelectedCollection(_:))

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(scrollView)
        container.addSubview(spinner)
        container.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -4),

            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(
                equalTo: spinner.leadingAnchor, constant: -6),
            statusLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),

            spinner.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),
        ])
        view = container
    }

    // MARK: - Loading

    func show(database: String) {
        self.database = database
        title = String(localized: "\(database) Collections")
        reload()
    }

    private func reload() {
        guard let session = session() else { return }
        let database = self.database
        loadTask?.cancel()
        loadViewIfNeeded()
        spinner.startAnimation(nil)
        statusLabel.stringValue = ""
        loadTask = Task {
            do {
                let names = try await session.listCollectionNames(database: database)
                // collStats is one command per collection and there is no
                // command that reports them all, so they go out together —
                // sequentially this would be one Atlas round trip per
                // collection before the table could draw anything.
                var loaded: [Row] = await withTaskGroup(of: Row.self) { group in
                    for name in names.sorted() {
                        group.addTask {
                            await Self.row(for: name, database: database, session: session)
                        }
                    }
                    var collected: [Row] = []
                    for await row in group { collected.append(row) }
                    return collected
                }
                loaded.sort { $0.name < $1.name }
                self.rows = loaded
                self.applySort()
                self.spinner.stopAnimation(nil)
                self.statusLabel.stringValue = Self.summary(for: loaded)
            } catch {
                self.spinner.stopAnimation(nil)
                self.rows = []
                self.tableView.reloadData()
                self.statusLabel.stringValue = String(describing: error)
            }
        }
    }

    private static func row(
        for name: String, database: String, session: ConnectionSession
    ) async -> Row {
        var row = Row(name: name, properties: "")
        do {
            let stats = try await session.collectionStats(database: database, collection: name)
            row.storageSize = intValue(stats["storageSize"])
            row.dataSize = intValue(stats["size"])
            row.documents = intValue(stats["count"])
            row.averageSize = intValue(stats["avgObjSize"])
            row.indexes = intValue(stats["nindexes"])
            row.indexSize = intValue(stats["totalIndexSize"])
            if (stats["capped"] as? Bool) == true {
                row.properties = String(localized: "capped")
            }
        } catch {
            // A view has no collStats, and a single collection can be denied
            // on its own. Either way the row still names the collection
            // rather than disappearing from the list.
            row.problem = String(describing: error)
            row.properties = String(localized: "view or unreadable")
        }
        return row
    }

    private static func summary(for rows: [Row]) -> String {
        let storage = rows.compactMap(\.storageSize).reduce(0, +)
        let indexes = rows.compactMap(\.indexSize).reduce(0, +)
        let documents = rows.compactMap(\.documents).reduce(0, +)
        let unreadable = rows.filter { $0.problem != nil }.count
        let template = String(
            localized: "%1$d collections · %2$@ storage · %3$@ indexes · %4$d documents")
        var text = String(
            format: template,
            rows.count, ByteSize.string(storage), ByteSize.string(indexes), documents)
        if unreadable > 0 {
            text += String(format: String(localized: " · %d without stats"), unreadable)
        }
        return text
    }

    private static func intValue(_ primitive: Primitive?) -> Int? {
        switch primitive {
        case let value as Int32: return Int(value)
        case let value as Int: return value
        case let value as Double: return Int(value)
        default: return nil
        }
    }

    // MARK: - Sorting

    private func applySort() {
        let ascending = sortAscending
        func compare(_ lhs: Int?, _ rhs: Int?) -> Bool {
            // Rows without stats sort to the bottom either way, rather than
            // pretending to be zero.
            guard let lhs else { return false }
            guard let rhs else { return true }
            return ascending ? lhs < rhs : lhs > rhs
        }
        switch sortColumn {
        case .name:
            rows.sort { ascending ? $0.name < $1.name : $0.name > $1.name }
        case .properties:
            rows.sort { ascending ? $0.properties < $1.properties : $0.properties > $1.properties }
        case .storage: rows.sort { compare($0.storageSize, $1.storageSize) }
        case .data: rows.sort { compare($0.dataSize, $1.dataSize) }
        case .documents: rows.sort { compare($0.documents, $1.documents) }
        case .average: rows.sort { compare($0.averageSize, $1.averageSize) }
        case .indexes: rows.sort { compare($0.indexes, $1.indexes) }
        case .indexSize: rows.sort { compare($0.indexSize, $1.indexSize) }
        }
        tableView.reloadData()
    }

    @objc private func openSelectedCollection(_ sender: Any?) {
        let clicked = tableView.clickedRow
        let row = clicked >= 0 ? clicked : tableView.selectedRow
        guard rows.indices.contains(row) else { return }
        openCollection(database, rows[row].name)
    }

    private func text(for row: Row, column: Column) -> String {
        switch column {
        case .name: return row.name
        case .properties: return row.properties
        case .storage: return row.storageSize.map(ByteSize.string) ?? "—"
        case .data: return row.dataSize.map(ByteSize.string) ?? "—"
        case .documents: return row.documents.map { "\($0)" } ?? "—"
        case .average: return row.averageSize.map(ByteSize.string) ?? "—"
        case .indexes: return row.indexes.map { "\($0)" } ?? "—"
        case .indexSize: return row.indexSize.map(ByteSize.string) ?? "—"
        }
    }
}

extension CollectionsTabController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard let identifier = tableColumn?.identifier,
            let column = Column(rawValue: identifier.rawValue),
            rows.indices.contains(row)
        else { return nil }

        let reuseID = NSUserInterfaceItemIdentifier("collections-\(column.rawValue)")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: reuseID, owner: self)
            as? NSTableCellView
        {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = reuseID
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            field.alignment = column.isNumeric ? .right : .left
            field.font =
                column.isNumeric
                ? .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                : .systemFont(ofSize: 11)
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = text(for: rows[row], column: column)
        cell.textField?.toolTip = rows[row].problem
        return cell
    }

    func tableView(
        _ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
    ) {
        guard let descriptor = tableView.sortDescriptors.first,
            let key = descriptor.key,
            let column = Column(rawValue: key)
        else { return }
        sortColumn = column
        sortAscending = descriptor.ascending
        applySort()
    }
}

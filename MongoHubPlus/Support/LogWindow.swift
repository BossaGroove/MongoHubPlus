import AppKit

/// App-wide log buffer (legacy MHLogWindow, but bounded and always
/// collecting). Driver lines arrive via each session's log sink; the app
/// adds connection lifecycle and import/export events.
@MainActor
final class LogStore {
    static let shared = LogStore()

    struct Entry {
        let date: Date
        let level: String
        let domain: String
        let message: String
    }

    private static let maxEntries = 5000
    private(set) var entries: [Entry] = []

    func add(level: String, domain: String, message: String) {
        entries.append(Entry(date: Date(), level: level, domain: domain, message: message))
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
        NotificationCenter.default.post(name: .logStoreDidChange, object: self)
    }

    /// Sendable entry point for background sinks.
    nonisolated static func log(level: String, domain: String, message: String) {
        Task { @MainActor in
            LogStore.shared.add(level: level, domain: domain, message: message)
        }
    }
}

extension Notification.Name {
    static let logStoreDidChange = Notification.Name("MongoHub Plus.logStoreDidChange")
}

/// The Logs window (Window ▸ Logs, ⌥⌘L): Time / Level / Domain / Log.
@MainActor
final class LogWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let tableView = NSTableView()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 360),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = String(localized: "Logs")
        window.setFrameAutosaveName("LogWindow")
        self.init(window: window)

        for (id, title, width) in [
            ("time", "Time", 90.0), ("level", "Level", 60.0), ("domain", "Domain", 140.0),
            ("message", "Log", 420.0),
        ] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            tableView.addTableColumn(column)
        }
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowSizeStyle = .small
        tableView.allowsMultipleSelection = true
        tableView.dataSource = self
        tableView.delegate = self

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        window.contentView = scrollView

        NotificationCenter.default.addObserver(
            self, selector: #selector(logChanged), name: .logStoreDidChange, object: nil)
        tableView.reloadData()
    }

    @objc private func logChanged() {
        let wasAtBottom =
            tableView.enclosingScrollView.map {
                $0.contentView.bounds.maxY >= (tableView.bounds.height - 40)
            } ?? true
        tableView.reloadData()
        if wasAtBottom, LogStore.shared.entries.count > 0 {
            tableView.scrollRowToVisible(LogStore.shared.entries.count - 1)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        LogStore.shared.entries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier,
            LogStore.shared.entries.indices.contains(row)
        else { return nil }
        let entry = LogStore.shared.entries[row]
        let text: String
        switch identifier.rawValue {
        case "time": text = Self.timeFormatter.string(from: entry.date)
        case "level": text = entry.level
        case "domain": text = entry.domain
        default: text = entry.message
        }

        let reuseID = NSUserInterfaceItemIdentifier("log-cell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: reuseID, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = reuseID
            let field = NSTextField(labelWithString: "")
            field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = text
        return cell
    }

    /// ⌘C copies the selected rows as text (works on every row — the legacy
    /// off-by-one blocked row 0, feature-spec §8.17).
    @objc func copy(_ sender: Any?) {
        let lines = tableView.selectedRowIndexes.compactMap { row -> String? in
            guard LogStore.shared.entries.indices.contains(row) else { return nil }
            let entry = LogStore.shared.entries[row]
            return "\(Self.timeFormatter.string(from: entry.date)) \(entry.domain) \(entry.level) \(entry.message)"
        }
        guard !lines.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

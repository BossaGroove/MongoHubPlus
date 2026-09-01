import AppKit
import BSON
import MongoService

/// The Activity Monitor tab (legacy MHActivityMonitorViewController):
/// mongostat-style per-second deltas from `serverStatus`, polled at 1 Hz.
/// MMAPv1-era columns (mapped, locked %, idx miss %) are gone; rows are
/// capped instead of growing forever (feature-spec 4.4).
@MainActor
final class ActivityMonitorTabController: TabItemViewController {
    private struct Sample {
        var values: [String: String]
    }

    private static let columns: [(id: String, title: String, width: CGFloat)] = [
        ("insert", "insert/s", 60), ("query", "query/s", 60), ("update", "update/s", 60),
        ("delete", "delete/s", 60), ("getmore", "getmore/s", 64), ("command", "cmd/s", 60),
        ("faults", "faults/s", 60), ("vsize", "vsize MB", 70), ("res", "res MB", 70),
        ("conn", "conn", 50), ("time", "time", 80),
    ]
    private static let maxRows = 3600  // one hour of samples

    private let session: () -> ConnectionSession?
    private let tableView = NSTableView()
    private var samples: [Sample] = []
    private var previousStatus: Document?
    private var pollTask: Task<Void, Never>?

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(session: @escaping () -> ConnectionSession?) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Activity Monitor")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func willRemoveFromTabHost() {
        pollTask?.cancel()
        pollTask = nil
    }

    override func loadView() {
        for column in Self.columns {
            let tableColumn = NSTableColumn(identifier: .init(column.id))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableView.addTableColumn(tableColumn)
        }
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowSizeStyle = .small
        tableView.dataSource = self
        tableView.delegate = self

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        view = scrollView
        startPolling()
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func poll() async {
        guard let session = session() else { return }
        guard let status = try? await session.serverStatus() else { return }
        defer { previousStatus = status }
        guard let previous = previousStatus else { return }

        var values: [String: String] = [:]
        let opcounters = status["opcounters"] as? Document ?? Document()
        let previousOpcounters = previous["opcounters"] as? Document ?? Document()
        for key in ["insert", "query", "update", "delete", "getmore", "command"] {
            values[key] = String(intValue(opcounters[key]) - intValue(previousOpcounters[key]))
        }
        let extra = status["extra_info"] as? Document
        let previousExtra = previous["extra_info"] as? Document
        if let faults = extra?["page_faults"], let previousFaults = previousExtra?["page_faults"] {
            values["faults"] = String(intValue(faults) - intValue(previousFaults))
        } else {
            values["faults"] = "-"
        }
        let mem = status["mem"] as? Document
        values["vsize"] = mem?["virtual"].map { String(intValue($0)) } ?? "-"
        values["res"] = mem?["resident"].map { String(intValue($0)) } ?? "-"
        let connections = status["connections"] as? Document
        values["conn"] = connections?["current"].map { String(intValue($0)) } ?? "-"
        values["time"] = Self.timeFormatter.string(from: Date())

        samples.append(Sample(values: values))
        if samples.count > Self.maxRows {
            samples.removeFirst(samples.count - Self.maxRows)
        }
        tableView.reloadData()
        tableView.scrollRowToVisible(samples.count - 1)
    }

    private func intValue(_ primitive: Primitive?) -> Int {
        switch primitive {
        case let value as Int32: return Int(value)
        case let value as Int: return value
        case let value as Double: return Int(value)
        default: return 0
        }
    }
}

extension ActivityMonitorTabController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        samples.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier else { return nil }
        let reuseID = NSUserInterfaceItemIdentifier("monitor-cell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: reuseID, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = reuseID
            let field = NSTextField(labelWithString: "")
            field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            field.alignment = .right
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = samples[row].values[identifier.rawValue] ?? ""
        return cell
    }
}

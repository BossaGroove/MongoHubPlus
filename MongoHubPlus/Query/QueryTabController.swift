import AppKit
import MongoService

/// The per-collection Query tab (legacy MHQueryViewController): a segmented
/// control over the six sub-panes — Find, Insert, Update, Remove, Index,
/// Aggregation (Map/Reduce dropped per feature-spec 3.9).
@MainActor
final class QueryTabController: TabItemViewController {
    private let context: QueryPaneContext

    private let segmentedControl = NSSegmentedControl()
    private let subTabs = NSTabView()

    private lazy var findPane = FindPaneController(context: context)
    private lazy var insertPane = InsertPaneController(context: context)
    private lazy var updatePane = UpdatePaneController(context: context)
    private lazy var removePane = RemovePaneController(context: context)
    private lazy var indexPane = IndexPaneController(context: context)
    private lazy var aggregationPane = AggregationPaneController(context: context)
    private lazy var tailPane = TailPaneController(context: context)

    private enum Segment: Int, CaseIterable {
        case find, insert, update, remove, index, aggregation, tail

        /// Stable identity (verification hooks match on this).
        var label: String {
            switch self {
            case .find: return "Find"
            case .insert: return "Insert"
            case .update: return "Update"
            case .remove: return "Remove"
            case .index: return "Index"
            case .aggregation: return "Aggregation"
            case .tail: return "Tail"
            }
        }

        var localizedLabel: String {
            switch self {
            case .find: return String(localized: "Find")
            case .insert: return String(localized: "Insert")
            case .update: return String(localized: "Update")
            case .remove: return String(localized: "Remove")
            case .index: return String(localized: "Index")
            case .aggregation: return String(localized: "Aggregation")
            case .tail: return String(localized: "Tail")
            }
        }
    }

    init(
        connectionID: UUID, database: String, collection: String,
        session: @escaping () -> ConnectionSession?
    ) {
        self.context = QueryPaneContext(
            connectionID: connectionID, database: database, collection: collection,
            session: session)
        super.init(nibName: nil, bundle: nil)
        title = context.namespace
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func willRemoveFromTabHost() {
        findPane.closeEditors()
        tailPane.stop()
    }

    override func loadView() {
        let root = NSView()

        segmentedControl.segmentCount = Segment.allCases.count
        for segment in Segment.allCases {
            segmentedControl.setLabel(segment.localizedLabel, forSegment: segment.rawValue)
        }
        segmentedControl.selectedSegment = 0
        segmentedControl.target = self
        segmentedControl.action = #selector(segmentChanged(_:))
        segmentedControl.segmentStyle = .automatic
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false

        subTabs.tabViewType = .noTabsNoBorder
        subTabs.translatesAutoresizingMaskIntoConstraints = false
        for segment in Segment.allCases {
            let item = NSTabViewItem(identifier: segment.rawValue)
            item.view = pane(for: segment).view
            addChild(pane(for: segment))
            subTabs.addTabViewItem(item)
        }

        root.addSubview(segmentedControl)
        root.addSubview(subTabs)
        NSLayoutConstraint.activate([
            segmentedControl.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            segmentedControl.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            subTabs.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: 6),
            subTabs.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            subTabs.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            subTabs.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    private func pane(for segment: Segment) -> NSViewController {
        switch segment {
        case .find: return findPane
        case .insert: return insertPane
        case .update: return updatePane
        case .remove: return removePane
        case .index: return indexPane
        case .aggregation: return aggregationPane
        case .tail: return tailPane
        }
    }

    /// Focus the natural first field of the selected pane (legacy
    /// selectBestTextField).
    private func focusSelectedPane() {
        guard let segment = Segment(rawValue: segmentedControl.selectedSegment) else { return }
        let responder: NSView?
        switch segment {
        case .find: responder = findPane.initialFirstResponder
        case .insert: responder = insertPane.initialFirstResponder
        case .update: responder = updatePane.initialFirstResponder
        case .remove: responder = removePane.initialFirstResponder
        case .index: responder = nil
        case .aggregation: responder = aggregationPane.initialFirstResponder
        case .tail: responder = nil
        }
        if let responder {
            view.window?.makeFirstResponder(responder)
        }
    }

    @objc private func segmentChanged(_ sender: Any?) {
        subTabs.selectTabViewItem(at: segmentedControl.selectedSegment)
        focusSelectedPane()
    }

    /// Programmatic segment selection (UI-verification hooks).
    func selectSegment(named name: String) {
        guard let segment = Segment.allCases.first(where: { $0.label.lowercased() == name.lowercased() })
        else { return }
        segmentedControl.selectedSegment = segment.rawValue
        segmentChanged(nil)
    }

    /// Kept for the -MAOpenQuery verification hook.
    func runQuery(_ sender: Any?) {
        findPane.runQuery(sender)
    }

    /// UI-verification hooks.
    func debugSetQuery(criteria: String?, fields: String?, sort: String? = nil) {
        findPane.debugSetQuery(criteria: criteria, fields: fields, sort: sort)
    }

    func debugExportResults(to url: URL) {
        findPane.debugExportResults(to: url)
    }
}

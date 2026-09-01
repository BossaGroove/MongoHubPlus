import AppKit
import BSON
import ExtendedJSON
import MongoService

/// The query explain sheet (feature 3.15, owner request 2026-09-01):
/// verdict banner (index vs collection scan + winning-plan chain), stat
/// tiles from executionStats, the full server reply in the standard
/// outline, and a verbosity popup that re-runs in place.
@MainActor
final class ExplainSheetController: NSWindowController {
    enum Verbosity: String, CaseIterable {
        case executionStats
        case queryPlanner
        case allPlansExecution

        var displayName: String {
            switch self {
            case .executionStats: return String(localized: "Execution Stats")
            case .queryPlanner: return String(localized: "Query Planner (no execution)")
            case .allPlansExecution: return String(localized: "All Plans Execution")
            }
        }
    }

    private let database: String
    private let explainTarget: Document  // the inner command (find …)
    private let session: ConnectionSession

    private let verdictIcon = NSImageView()
    private let verdictLabel = NSTextField(labelWithString: "")
    private let chainLabel = NSTextField(labelWithString: "")
    private let advisoryLabel = NSTextField(labelWithString: "")
    private var tileValues: [NSTextField] = []
    private let outline = DocumentOutlineViewController(
        options: .init(
            showsFooter: false, showsRemoveButton: false, showsPagination: false,
            autosaveName: "explain-outline"))
    private let verbosityPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let spinner = NSProgressIndicator()

    init(database: String, explainTarget: Document, session: ConnectionSession) {
        self.database = database
        self.explainTarget = explainTarget
        self.session = session
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 560),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = String(localized: "Explain")
        window.minSize = NSSize(width: 560, height: 400)
        super.init(window: window)
        buildContent()
        run()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    private func buildContent() {
        guard let window else { return }
        let content = NSView()

        // Verdict banner
        verdictIcon.translatesAutoresizingMaskIntoConstraints = false
        verdictLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        verdictLabel.translatesAutoresizingMaskIntoConstraints = false
        chainLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        chainLabel.textColor = .secondaryLabelColor
        chainLabel.lineBreakMode = .byTruncatingTail
        chainLabel.translatesAutoresizingMaskIntoConstraints = false
        advisoryLabel.font = .systemFont(ofSize: 11)
        advisoryLabel.textColor = .secondaryLabelColor
        advisoryLabel.lineBreakMode = .byWordWrapping
        advisoryLabel.maximumNumberOfLines = 2
        advisoryLabel.translatesAutoresizingMaskIntoConstraints = false

        // Stat tiles
        let tileTitles = [
            String(localized: "Returned"), String(localized: "Docs Examined"),
            String(localized: "Keys Examined"), String(localized: "Time"),
        ]
        var tiles: [NSView] = []
        for title in tileTitles {
            let value = NSTextField(labelWithString: "—")
            value.font = .monospacedDigitSystemFont(ofSize: 20, weight: .medium)
            value.alignment = .center
            tileValues.append(value)
            let caption = NSTextField(labelWithString: title)
            caption.font = .systemFont(ofSize: 10)
            caption.textColor = .secondaryLabelColor
            caption.alignment = .center
            let stack = NSStackView(views: [value, caption])
            stack.orientation = .vertical
            stack.alignment = .centerX
            stack.spacing = 2
            tiles.append(stack)
        }
        let tileRow = NSStackView(views: tiles)
        tileRow.orientation = .horizontal
        tileRow.distribution = .fillEqually
        tileRow.translatesAutoresizingMaskIntoConstraints = false

        // Footer
        for verbosity in Verbosity.allCases {
            verbosityPopup.addItem(withTitle: verbosity.displayName)
        }
        verbosityPopup.target = self
        verbosityPopup.action = #selector(verbosityChanged(_:))
        verbosityPopup.translatesAutoresizingMaskIntoConstraints = false
        let verbosityLabel = NSTextField(labelWithString: String(localized: "Verbosity:"))
        verbosityLabel.translatesAutoresizingMaskIntoConstraints = false
        let closeButton = NSButton(
            title: String(localized: "Close"), target: self, action: #selector(closeAction(_:)))
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let outlineView = outline.view
        outlineView.translatesAutoresizingMaskIntoConstraints = false

        for view in [
            verdictIcon, verdictLabel, chainLabel, advisoryLabel, tileRow, outlineView,
            verbosityLabel, verbosityPopup, closeButton, spinner,
        ] {
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            verdictIcon.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            verdictIcon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            verdictIcon.widthAnchor.constraint(equalToConstant: 24),
            verdictIcon.heightAnchor.constraint(equalToConstant: 24),

            verdictLabel.centerYAnchor.constraint(equalTo: verdictIcon.centerYAnchor),
            verdictLabel.leadingAnchor.constraint(equalTo: verdictIcon.trailingAnchor, constant: 8),
            verdictLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: content.trailingAnchor, constant: -20),

            spinner.centerYAnchor.constraint(equalTo: verdictIcon.centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            chainLabel.topAnchor.constraint(equalTo: verdictLabel.bottomAnchor, constant: 4),
            chainLabel.leadingAnchor.constraint(equalTo: verdictLabel.leadingAnchor),
            chainLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            advisoryLabel.topAnchor.constraint(equalTo: chainLabel.bottomAnchor, constant: 4),
            advisoryLabel.leadingAnchor.constraint(equalTo: verdictLabel.leadingAnchor),
            advisoryLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            tileRow.topAnchor.constraint(equalTo: advisoryLabel.bottomAnchor, constant: 14),
            tileRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            tileRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            outlineView.topAnchor.constraint(equalTo: tileRow.bottomAnchor, constant: 14),
            outlineView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            outlineView.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            verbosityLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            verbosityLabel.centerYAnchor.constraint(equalTo: verbosityPopup.centerYAnchor),
            verbosityPopup.leadingAnchor.constraint(
                equalTo: verbosityLabel.trailingAnchor, constant: 8),
            verbosityPopup.topAnchor.constraint(equalTo: outlineView.bottomAnchor, constant: 12),
            verbosityPopup.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),

            closeButton.centerYAnchor.constraint(equalTo: verbosityPopup.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        ])
        window.contentView = content
    }

    // MARK: - Run

    private var verbosity: Verbosity {
        Verbosity.allCases[verbosityPopup.indexOfSelectedItem]
    }

    @objc private func verbosityChanged(_ sender: Any?) {
        run()
    }

    @objc private func closeAction(_ sender: Any?) {
        guard let window else { return }
        window.sheetParent?.endSheet(window)
    }

    private func run() {
        spinner.startAnimation(nil)
        var command = Document()
        command["explain"] = explainTarget
        command["verbosity"] = verbosity.rawValue
        let executed = verbosity != .queryPlanner
        Task {
            do {
                let reply = try await session.runCommand(command, onDatabase: database)
                self.spinner.stopAnimation(nil)
                self.display(reply: reply, executed: executed)
            } catch {
                self.spinner.stopAnimation(nil)
                self.verdictIcon.image = NSImage(
                    systemSymbolName: "xmark.octagon.fill", accessibilityDescription: nil)
                self.verdictIcon.contentTintColor = .systemRed
                self.verdictLabel.stringValue = String(localized: "Explain failed")
                self.chainLabel.stringValue = String(describing: error)
            }
        }
    }

    // MARK: - Reply parsing

    private func display(reply: Document, executed: Bool) {
        // Aggregate explains nest the plan inside stages[0].$cursor.
        var source = reply
        if reply["queryPlanner"] == nil,
            let stages = reply["stages"] as? Document,
            let first = stages.values.first as? Document,
            let cursor = first["$cursor"] as? Document
        {
            source = cursor
        }
        let planner = source["queryPlanner"] as? Document
        let winning = planner?["winningPlan"] as? Document

        // Sharded replies nest per-shard plans.
        let shards = (winning?["shards"] as? Document)?.values.compactMap { $0 as? Document }
        let chain = Self.planChain(
            from: (shards?.first?["winningPlan"] as? Document) ?? winning ?? Document())

        let indexes = chain.compactMap(\.index)
        let hasCollscan = chain.contains { $0.stage == "COLLSCAN" }

        // An index that satisfies only the sort is a collection scan in
        // disguise: no filter field appears in any used index's keyPattern.
        let filterFields = ((explainTarget["filter"] as? Document)?.keys ?? [])
            .filter { !$0.hasPrefix("$") }
        let indexedFields = Set(chain.flatMap(\.keyPattern))
        let sortOnlyIndex =
            !hasCollscan && !indexes.isEmpty && !filterFields.isEmpty
            && filterFields.allSatisfy { !indexedFields.contains($0) }

        if hasCollscan {
            verdictIcon.image = NSImage(
                systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            verdictIcon.contentTintColor = .systemOrange
            verdictLabel.stringValue = String(localized: "Collection scan — no index used")
        } else if sortOnlyIndex {
            verdictIcon.image = NSImage(
                systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            verdictIcon.contentTintColor = .systemOrange
            let names = indexes.joined(separator: ", ")
            verdictLabel.stringValue = String(
                localized: "Index \(names) used for sort only — filter is not indexed")
        } else if !indexes.isEmpty {
            verdictIcon.image = NSImage(
                systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
            verdictIcon.contentTintColor = .systemGreen
            let names = indexes.joined(separator: ", ")
            verdictLabel.stringValue = String(localized: "Used index: \(names)")
        } else {
            verdictIcon.image = NSImage(
                systemSymbolName: "info.circle.fill", accessibilityDescription: nil)
            verdictIcon.contentTintColor = .secondaryLabelColor
            verdictLabel.stringValue = String(localized: "See the full plan below")
        }

        var chainText = chain.reversed()
            .map { entry in
                entry.index.map { "\(entry.stage) (\($0))" } ?? entry.stage
            }
            .joined(separator: " → ")
        if let shards, shards.count > 1 {
            chainText = String(localized: "\(shards.count) shards (merged stats)") + " · " + chainText
        }
        chainLabel.stringValue = chainText

        // Stat tiles + advisory
        let stats = source["executionStats"] as? Document
        let returned = Self.intValue(stats?["nReturned"])
        let docsExamined = Self.intValue(stats?["totalDocsExamined"])
        let keysExamined = Self.intValue(stats?["totalKeysExamined"])
        let millis = Self.intValue(stats?["executionTimeMillis"])
        if executed, let stats, !stats.isEmpty {
            tileValues[0].stringValue = returned.map(String.init) ?? "—"
            tileValues[1].stringValue = docsExamined.map(String.init) ?? "—"
            tileValues[2].stringValue = keysExamined.map(String.init) ?? "—"
            tileValues[3].stringValue = millis.map { "\($0) ms" } ?? "—"
        } else {
            for tile in tileValues { tile.stringValue = "—" }
        }

        var advisories: [String] = []
        if !executed {
            advisories.append(String(localized: "Plan only — the query was not executed."))
        }
        if let returned, let docsExamined, docsExamined > 100, docsExamined > 10 * max(returned, 1) {
            let ratio = docsExamined / max(returned, 1)
            advisories.append(
                String(localized: "Examined \(ratio)× more documents than returned."))
        }
        if hasCollscan || sortOnlyIndex, !filterFields.isEmpty {
            let spec = filterFields.map { "\($0): 1" }.joined(separator: ", ")
            advisories.append(String(localized: "An index on { \(spec) } may help."))
        }
        advisoryLabel.stringValue = advisories.joined(separator: "  ")

        outline.display(fields: reply)
    }

    /// Walks the winning plan from the outermost stage inward. Handles the
    /// SBE shape (a nested `queryPlan`) and OR stages (`inputStages`).
    static func planChain(
        from winningPlan: Document
    ) -> [(stage: String, index: String?, keyPattern: [String])] {
        var chain: [(String, String?, [String])] = []
        var current: Document? = (winningPlan["queryPlan"] as? Document) ?? winningPlan
        while let node = current {
            if let stage = node["stage"] as? String {
                chain.append(
                    (stage, node["indexName"] as? String,
                     (node["keyPattern"] as? Document)?.keys ?? []))
            }
            current =
                node["inputStage"] as? Document
                ?? (node["inputStages"] as? Document)?.values.first as? Document
        }
        return chain
    }

    private static func intValue(_ primitive: Primitive?) -> Int? {
        switch primitive {
        case let value as Int32: return Int(value)
        case let value as Int: return value
        case let value as Double: return Int(value)
        default: return nil
        }
    }
}

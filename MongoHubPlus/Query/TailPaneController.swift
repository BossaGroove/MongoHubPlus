import AppKit
import BSON
import ExtendedJSON

/// The Tail sub-tab (M4c): a live change-stream view. Start opens a change
/// stream on the collection and prepends events as they arrive (newest
/// first, capped); requires a replica set or Atlas — on a standalone server
/// the pane shows a friendly explanation instead.
@MainActor
final class TailPaneController: NSViewController {
    private static let maxEvents = 500

    private let context: QueryPaneContext
    private var streamTask: Task<Void, Never>?
    private var events: [Document] = []
    private var eventCount = 0

    private var startStopButton: NSButton!
    private var clearButton: NSButton!
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = QueryPaneUI.spinner()
    private let outline = DocumentOutlineViewController(
        options: .init(
            showsFooter: true, showsRemoveButton: false, showsPagination: false,
            autosaveName: "tail-outline"))

    init(context: QueryPaneContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        streamTask?.cancel()
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        if isViewLoaded {
            spinner.stopAnimation(nil)
            startStopButton.title = String(localized: "Start Tailing")
            statusLabel.stringValue = String(localized: "Stopped")
        }
    }

    override func loadView() {
        let container = NSView()

        startStopButton = NSButton(
            title: String(localized: "Start Tailing"), target: self,
            action: #selector(startStopAction(_:)))
        startStopButton.bezelStyle = .rounded
        clearButton = NSButton(
            title: String(localized: "Clear"), target: self, action: #selector(clearAction(_:)))
        clearButton.bezelStyle = .rounded
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let topRow = NSStackView(views: [startStopButton, clearButton, spinner, statusLabel])
        topRow.orientation = .horizontal
        topRow.spacing = 8
        topRow.translatesAutoresizingMaskIntoConstraints = false

        outline.delegate = nil
        let outlineView = outline.view
        outlineView.translatesAutoresizingMaskIntoConstraints = false
        addChild(outline)

        container.addSubview(topRow)
        container.addSubview(outlineView)
        NSLayoutConstraint.activate([
            topRow.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            topRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            topRow.trailingAnchor.constraint(
                lessThanOrEqualTo: container.trailingAnchor, constant: -8),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),

            outlineView.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 8),
            outlineView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            outlineView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            outlineView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        statusLabel.stringValue = String(
            localized: "Live changes for this collection (replica set or Atlas required).")

        if UserDefaults.standard.bool(forKey: "MATailStart") {
            startStopAction(nil)
        }
    }

    // MARK: - Actions

    @objc private func startStopAction(_ sender: Any?) {
        if streamTask != nil {
            stop()
            return
        }
        guard let session = context.session() else { return }
        startStopButton.title = String(localized: "Stop Tailing")
        statusLabel.stringValue = String(localized: "Listening for changes…")
        spinner.startAnimation(nil)

        let stream = session.changeStream(
            database: context.database, collection: context.collection)
        streamTask = Task {
            do {
                for try await event in stream {
                    self.append(event: event)
                }
                self.stop()
            } catch {
                self.spinner.stopAnimation(nil)
                self.streamTask = nil
                self.startStopButton.title = String(localized: "Start Tailing")
                let description = String(describing: error)
                if description.contains("replica sets") || description.contains("40573") {
                    self.statusLabel.stringValue = String(
                        localized: "Change streams require a replica set (or MongoDB Atlas).")
                } else {
                    self.statusLabel.stringValue = description
                }
            }
        }
    }

    @objc private func clearAction(_ sender: Any?) {
        events.removeAll()
        eventCount = 0
        outline.display(documents: [], label: nil)
    }

    // MARK: - Events

    /// Newest first; `_id` (the resume token) is dropped so the outline
    /// labels rows by `operationType` instead of a noisy token blob.
    private func append(event: Document) {
        var display = Document()
        for pair in event.pairs where pair.key != "_id" {
            display[pair.key] = pair.value
        }
        events.insert(display, at: 0)
        if events.count > Self.maxEvents {
            events.removeLast(events.count - Self.maxEvents)
        }
        eventCount += 1
        outline.display(
            documents: events,
            label: String(localized: "\(eventCount) events — newest first"))
    }
}

import AppKit
import BSON
import ExtendedJSON
import MongoService

extension Notification.Name {
    /// Posted after a successful save so the Find tab can refresh — fixing
    /// the legacy notification that never fired (feature-spec §8.9).
    static let jsonEditorDidSaveDocument = Notification.Name("MongoHub Plus.jsonEditorDidSaveDocument")
}

/// The per-document JSON editor window (legacy MHJsonWindowController):
/// pretty lossless Extended JSON, syntax-colored, byte-level round-trip
/// verification on open, save = full-document replace by `_id`.
@MainActor
final class JSONEditorWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    private let originalDocument: Document
    private let namespace: String
    private let database: String
    private let collection: String
    private let connectionID: UUID
    private let session: ConnectionSession

    var onClose: (() -> Void)?

    private var textView: NSTextView!
    private let statusLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private var saveButton: NSButton!
    private let highlighter = JSONHighlighter()

    /// Where the next editor window cascades from (shared across editors).
    private static var cascadePoint = NSPoint.zero

    private var originalText = ""
    private var isDirty: Bool {
        textView.string != originalText
    }

    init(
        document: Document, namespace: String, database: String, collection: String,
        connectionID: UUID, session: ConnectionSession
    ) {
        self.originalDocument = document
        self.namespace = namespace
        self.database = database
        self.collection = collection
        self.connectionID = connectionID
        self.session = session

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        // Title includes the _id (broken in legacy — feature-spec §8.10).
        if let id = document["_id"] {
            window.title = "\(namespace) _id:\(BSONDisplay.valueString(id))"
        } else {
            window.title = namespace
        }
        super.init(window: window)
        window.delegate = self
        buildContent()
        loadDocument()
        // Remember frame across launches (owner report: opened bottom-left);
        // cascade so a second editor doesn't cover the first exactly.
        window.center()
        window.setFrameAutosaveName("MAJSONEditorWindow")
        window.setFrameUsingName("MAJSONEditorWindow")
        Self.cascadePoint = window.cascadeTopLeft(from: Self.cascadePoint)
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesChanged), name: .preferencesDidChange,
            object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildContent() {
        guard let window else { return }
        let content = NSView()

        saveButton = NSButton(title: String(localized: "Save"), target: self, action: #selector(saveAction(_:)))
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = .command
        let cancelButton = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancelAction(_:)))
        cancelButton.keyEquivalent = "\u{1b}"  // Esc closes (owner request)

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let topBar = NSStackView(views: [saveButton, cancelButton, progress, statusLabel])
        topBar.orientation = .horizontal
        topBar.spacing = 8
        topBar.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        textView = NSTextView()
        textView.autoresizingMask = [.width]
        textView.allowsUndo = true
        textView.delegate = self
        textView.textContainerInset = NSSize(width: 4, height: 6)
        scrollView.documentView = textView

        content.addSubview(topBar)
        content.addSubview(scrollView)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            topBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            topBar.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -10),

            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
    }

    // MARK: - Load + round-trip verification (feature-spec 4.2)

    private func loadDocument() {
        do {
            originalText = try ExtendedJSON.stringify(
                originalDocument,
                format: EJSONFormat(mode: .editor, pretty: true, keyOrder: Preferences.jsonKeyOrder))
        } catch {
            originalText = "// Could not render document: \(error)"
            saveButton.isEnabled = false
        }
        textView.string = originalText
        highlighter.apply(to: textView)

        switch ExtendedJSON.verifyRoundTrip(originalDocument) {
        case .lossless:
            break
        case .lossy(let reason):
            saveButton.isEnabled = false
            statusLabel.stringValue = "Read-only: this document cannot round-trip losslessly"
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "This document cannot be edited safely")
            alert.informativeText =
                "Re-parsing the generated JSON does not reproduce the original document "
                + "byte-for-byte, so saving could silently change values. "
                + "The editor is read-only for this document.\n\nReason: \(reason)"
            if let window {
                alert.beginSheetModal(for: window)
            }
        }
    }

    @objc private func preferencesChanged() {
        highlighter.refresh(textView)
    }

    // MARK: - Editing

    func textDidChange(_ notification: Notification) {
        highlighter.highlight(textView)
        window?.isDocumentEdited = isDirty
    }

    /// Esc closes the window even while typing (macOS would otherwise show
    /// the text-completion menu). The unsaved-changes prompt still applies.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:))
            || commandSelector == #selector(NSStandardKeyBindingResponding.complete(_:))
        {
            window?.performClose(nil)
            return true
        }
        return false
    }

    // MARK: - Save (replaceOne by _id, upsert — legacy `save` semantics)

    @objc private func saveAction(_ sender: Any?) {
        save(completion: nil)
    }

    private func save(completion: ((Bool) -> Void)?) {
        statusLabel.stringValue = "Saving…"
        let text = textView.string

        let document: Document
        do {
            document = try ExtendedJSON.parseDocument(text)
            guard !document.isArray else {
                throw EJSONError("The editor holds a single document, not an array")
            }
            guard let _ = document["_id"] else {
                throw EJSONError("The document needs an _id field")
            }
        } catch {
            statusLabel.stringValue = String(describing: error).replacingOccurrences(of: "\n", with: " ")
            presentSheetError(title: String(localized: "Invalid Document"), message: String(describing: error))
            completion?(false)
            return
        }

        progress.startAnimation(nil)
        saveButton.isEnabled = false
        Task {
            do {
                var command = Document()
                command["update"] = collection
                var updates = Document(isArray: true)
                var spec = Document()
                var filter = Document()
                filter["_id"] = document["_id"]
                spec["q"] = filter
                spec["u"] = document
                spec["upsert"] = true
                updates["0"] = spec
                command["updates"] = updates
                _ = try await session.runCommand(command, onDatabase: database)

                self.progress.stopAnimation(nil)
                self.saveButton.isEnabled = true
                self.originalText = text
                self.window?.isDocumentEdited = false
                self.statusLabel.stringValue = "Saved"
                NotificationCenter.default.post(
                    name: .jsonEditorDidSaveDocument, object: self,
                    userInfo: [
                        "connectionID": self.connectionID,
                        "namespace": self.namespace,
                    ])
                completion?(true)
            } catch {
                self.progress.stopAnimation(nil)
                self.saveButton.isEnabled = true
                self.statusLabel.stringValue = String(describing: error)
                self.presentSheetError(title: String(localized: "Save Failed"), message: String(describing: error))
                completion?(false)
            }
        }
    }

    @objc private func cancelAction(_ sender: Any?) {
        window?.performClose(nil)
    }

    // MARK: - Close with unsaved changes (legacy Save / Don't Save / Cancel)

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = String(localized: "Unsaved Document")
        alert.informativeText = String(localized: "This document has unsaved changes.")
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Don't Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.save { success in
                    if success { self.window?.close() }
                }
            case .alertSecondButtonReturn:
                self.originalText = self.textView.string  // discard dirty state
                self.window?.close()
            default:
                break
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    private func presentSheetError(title: String, message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }
}

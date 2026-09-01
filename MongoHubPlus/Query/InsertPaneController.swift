import AppKit
import BSON
import ExtendedJSON

/// The Insert sub-tab: one document or an array of documents in a
/// syntax-colored editor (legacy insert pane).
@MainActor
final class InsertPaneController: NSViewController {
    private let context: QueryPaneContext
    private let highlighter = JSONHighlighter()
    private var textView: NSTextView!
    private let resultLabel = QueryPaneUI.resultLabel(placeholder: "Insert Result")
    private let spinner = QueryPaneUI.spinner()

    init(context: QueryPaneContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesChanged), name: .preferencesDidChange,
            object: nil)
    }

    @objc private func preferencesChanged() {
        guard isViewLoaded else { return }
        highlighter.refresh(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var initialFirstResponder: NSView { textView }

    override func loadView() {
        let container = NSView()
        let (scrollView, editor) = QueryPaneUI.jsonTextView(highlighter: highlighter)
        textView = editor
        textView.delegate = self
        textView.string = "{\n  \n}"

        let insertButton = QueryPaneUI.runButton(
            title: String(localized: "Insert"), target: self, action: #selector(insertAction(_:)))
        insertButton.keyEquivalent = "r"
        insertButton.keyEquivalentModifierMask = .command

        let bottomRow = NSStackView(views: [spinner, resultLabel, insertButton])
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 8
        bottomRow.translatesAutoresizingMaskIntoConstraints = false
        resultLabel.setContentHuggingPriority(.init(1), for: .horizontal)

        container.addSubview(scrollView)
        container.addSubview(bottomRow)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: bottomRow.topAnchor, constant: -8),

            bottomRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            bottomRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            bottomRow.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        view = container
    }

    @objc func insertAction(_ sender: Any?) {
        guard let session = context.session() else { return }
        // Legacy auto-wrapped a bare document in [ ] (and crashed on empty
        // input — fixed: feature-spec §8.13).
        var text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            QueryPaneUI.flash(resultLabel, text: "Nothing to insert", success: false)
            return
        }
        if !text.hasPrefix("[") {
            text = "[\(text)]"
        }

        let documents: Document
        do {
            let parsed = try ExtendedJSON.parseDocument(text)
            guard parsed.isArray, parsed.count > 0 else {
                throw EJSONError("Provide a document or an array of documents")
            }
            for value in parsed.values where !(value is Document) {
                throw EJSONError("Every array element must be a document")
            }
            documents = parsed
        } catch {
            QueryPaneUI.flash(resultLabel, text: "Parsing error", success: false)
            QueryPaneUI.alertSheet(in: view, title: String(localized: "Error"), message: String(describing: error))
            return
        }

        spinner.startAnimation(nil)
        Task {
            do {
                var command = Document()
                command["insert"] = context.collection
                command["documents"] = documents
                let reply = try await session.runCommand(command, onDatabase: context.database)
                self.spinner.stopAnimation(nil)
                let n = (reply["n"] as? Int32).map(Int.init) ?? reply["n"] as? Int ?? documents.count
                QueryPaneUI.flash(
                    self.resultLabel,
                    text: n == 1 ? "Completed! 1 document inserted" : "Completed! \(n) documents inserted",
                    success: true)
            } catch {
                self.spinner.stopAnimation(nil)
                QueryPaneUI.flash(self.resultLabel, text: "Error!", success: false)
                QueryPaneUI.alertSheet(in: self.view, title: String(localized: "Insert Failed"), message: String(describing: error))
            }
        }
    }
}

extension InsertPaneController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        highlighter.highlight(textView)
    }
}

import AppKit
import BSON
import ExtendedJSON

/// The Remove sub-tab: criteria + Remove (Return runs; ⌘Return skips the
/// remove-all confirmation — legacy behavior, tooltip included).
@MainActor
final class RemovePaneController: NSViewController {
    private let context: QueryPaneContext

    private let previewField = QueryPaneUI.previewField()
    private let spinner = QueryPaneUI.spinner()
    private let criteriaField = NSTextField(string: "")
    private let resultLabel = QueryPaneUI.resultLabel(placeholder: "Remove Result")

    init(context: QueryPaneContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var initialFirstResponder: NSView { criteriaField }

    override func loadView() {
        let container = NSView()

        criteriaField.placeholderString = String(localized: "{ }")
        criteriaField.delegate = self

        let removeButton = QueryPaneUI.runButton(
            title: String(localized: "Remove"), target: self, action: #selector(removeAction(_:)))
        removeButton.keyEquivalent = "\r"
        removeButton.toolTip = String(localized: "Use ⌘ to skip the confirmation panel")

        let row = NSStackView(views: [
            NSTextField(labelWithString: String(localized: "Query:")), criteriaField, removeButton,
        ])
        row.orientation = .horizontal
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        criteriaField.setContentHuggingPriority(.init(1), for: .horizontal)

        container.addSubview(previewField)
        container.addSubview(spinner)
        container.addSubview(row)
        container.addSubview(resultLabel)
        NSLayoutConstraint.activate([
            previewField.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            previewField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            previewField.trailingAnchor.constraint(equalTo: spinner.leadingAnchor, constant: -6),

            spinner.centerYAnchor.constraint(equalTo: previewField.centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),

            row.topAnchor.constraint(equalTo: previewField.bottomAnchor, constant: 6),
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            resultLabel.topAnchor.constraint(greaterThanOrEqualTo: row.bottomAnchor, constant: 16),
            resultLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            resultLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 8),
            resultLabel.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -16),
        ])
        view = container
        composePreview()
    }

    private var normalizedCriteria: String {
        QueryNormalizer.normalizeCriteria(criteriaField.stringValue, emptyIsValid: false)
    }

    private func composePreview() {
        previewField.stringValue = "db.\(context.collection).remove(\(normalizedCriteria))"
    }

    @objc func removeAction(_ sender: Any?) {
        composePreview()
        let criteria: Document
        do {
            criteria = try ExtendedJSON.parseDocument(normalizedCriteria)
        } catch {
            QueryPaneUI.flash(resultLabel, text: "Error!", success: false)
            QueryPaneUI.alertSheet(in: view, title: String(localized: "Error In Query"), message: String(describing: error))
            return
        }

        // Empty criteria = remove ALL documents: confirm unless ⌘ is held
        // (legacy behavior, Cancel is the default).
        let commandHeld = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        if criteria.isEmpty && !commandHeld {
            guard let window = view.window else { return }
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Are you sure you want to remove all documents in \(context.namespace)?"
            alert.informativeText = String(localized: "This action cannot be undone.")
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.addButton(withTitle: String(localized: "Remove All"))
            alert.buttons[1].hasDestructiveAction = true
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertSecondButtonReturn else { return }
                self?.performRemove(criteria: criteria)
            }
            return
        }
        performRemove(criteria: criteria)
    }

    private func performRemove(criteria: Document) {
        guard let session = context.session() else { return }
        spinner.startAnimation(nil)
        Task {
            do {
                var command = Document()
                command["delete"] = context.collection
                var deletes = Document(isArray: true)
                var spec = Document()
                spec["q"] = criteria
                spec["limit"] = Int32(0)
                deletes["0"] = spec
                command["deletes"] = deletes
                let reply = try await session.runCommand(command, onDatabase: context.database)
                self.spinner.stopAnimation(nil)
                let n = (reply["n"] as? Int32).map(Int.init) ?? reply["n"] as? Int ?? 0
                QueryPaneUI.flash(self.resultLabel, text: "Removed Documents: \(n)", success: true)
            } catch {
                self.spinner.stopAnimation(nil)
                QueryPaneUI.flash(self.resultLabel, text: "Error!", success: false)
                QueryPaneUI.alertSheet(in: self.view, title: String(localized: "Remove Failed"), message: String(describing: error))
            }
        }
    }
}

extension RemovePaneController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        composePreview()
    }

    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            removeAction(nil)
            return true
        }
        return false
    }
}

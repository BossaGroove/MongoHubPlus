import AppKit
import BSON
import ExtendedJSON

/// The Update sub-tab: criteria + Upsert/Multi + dynamic update-operator rows
/// (legacy MHQueryUpdateOperatorView mechanics, `upsert` spelled right).
@MainActor
final class UpdatePaneController: NSViewController {
    /// The legacy operator list, separators included, in the same order.
    private static let operators: [[String]] = [
        ["$currentDate", "Current Date"], ["$inc", "Increment"], ["$max", "Max"],
        ["$min", "Min"], ["$mul", "Multiply"], ["$rename", "Rename"],
        ["$setOnInsert", "Set On Insert"], ["$set", "Set"], ["$unset", "Unset"],
        [],
        ["$addToSet", "Add To Set"], ["$pop", "Pop"], ["$pullAll", "Pull All"],
        ["$pull", "Pull"], ["$push", "Push"],
        [],
        ["$bit", "Bit"],
    ]

    @MainActor
    private final class OperatorRow {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        let field = NSTextField(string: "")
        let addButton = NSButton()
        let removeButton = NSButton()
        let stack = NSStackView()
    }

    private let context: QueryPaneContext

    private let previewField = QueryPaneUI.previewField()
    private let spinner = QueryPaneUI.spinner()
    private let criteriaField = NSTextField(string: "")
    private let upsertCheckbox = NSButton(checkboxWithTitle: "Upsert", target: nil, action: nil)
    private let multiCheckbox = NSButton(checkboxWithTitle: "Multi", target: nil, action: nil)
    private let rowsStack = NSStackView()
    private let resultLabel = QueryPaneUI.resultLabel(placeholder: "Update Result")
    private var rows: [OperatorRow] = []

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
        upsertCheckbox.target = self
        upsertCheckbox.action = #selector(composeAction(_:))
        multiCheckbox.target = self
        multiCheckbox.action = #selector(composeAction(_:))

        let updateButton = QueryPaneUI.runButton(
            title: String(localized: "Update"), target: self, action: #selector(updateAction(_:)))
        updateButton.keyEquivalent = "r"
        updateButton.keyEquivalentModifierMask = .command

        let criteriaRow = NSStackView(views: [
            NSTextField(labelWithString: String(localized: "Query")), criteriaField,
            upsertCheckbox, multiCheckbox, updateButton,
        ])
        criteriaRow.orientation = .horizontal
        criteriaRow.spacing = 6
        criteriaRow.translatesAutoresizingMaskIntoConstraints = false
        criteriaField.setContentHuggingPriority(.init(1), for: .horizontal)

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 6
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(previewField)
        container.addSubview(spinner)
        container.addSubview(criteriaRow)
        container.addSubview(rowsStack)
        container.addSubview(resultLabel)
        NSLayoutConstraint.activate([
            previewField.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            previewField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            previewField.trailingAnchor.constraint(equalTo: spinner.leadingAnchor, constant: -6),

            spinner.centerYAnchor.constraint(equalTo: previewField.centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),

            criteriaRow.topAnchor.constraint(equalTo: previewField.bottomAnchor, constant: 6),
            criteriaRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            criteriaRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            rowsStack.topAnchor.constraint(equalTo: criteriaRow.bottomAnchor, constant: 8),
            rowsStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            rowsStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            resultLabel.topAnchor.constraint(greaterThanOrEqualTo: rowsStack.bottomAnchor, constant: 12),
            resultLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            resultLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 8),
            resultLabel.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -12),
        ])
        view = container

        addOperatorRow(after: nil)  // first row, defaults to $set (legacy)
        composePreview()
    }

    // MARK: - Operator rows

    private func addOperatorRow(after row: OperatorRow?) {
        let newRow = OperatorRow()
        newRow.popup.autoenablesItems = false
        for entry in Self.operators {
            if entry.isEmpty {
                newRow.popup.menu?.addItem(.separator())
            } else {
                newRow.popup.addItem(withTitle: entry[1])
            }
        }
        newRow.popup.target = self
        newRow.popup.action = #selector(operatorPopupChanged(_:))
        newRow.field.placeholderString = String(localized: "{ }")
        newRow.field.delegate = self
        newRow.addButton.image = NSImage(named: NSImage.addTemplateName)
        newRow.addButton.bezelStyle = .smallSquare
        newRow.addButton.target = self
        newRow.addButton.action = #selector(addRowAction(_:))
        newRow.removeButton.image = NSImage(named: NSImage.removeTemplateName)
        newRow.removeButton.bezelStyle = .smallSquare
        newRow.removeButton.target = self
        newRow.removeButton.action = #selector(removeRowAction(_:))

        newRow.stack.orientation = .horizontal
        newRow.stack.spacing = 6
        newRow.stack.addArrangedSubview(newRow.popup)
        newRow.stack.addArrangedSubview(newRow.field)
        newRow.stack.addArrangedSubview(newRow.addButton)
        newRow.stack.addArrangedSubview(newRow.removeButton)
        newRow.popup.widthAnchor.constraint(equalToConstant: 140).isActive = true
        newRow.field.setContentHuggingPriority(.init(1), for: .horizontal)
        newRow.stack.translatesAutoresizingMaskIntoConstraints = false

        let insertIndex = row.flatMap { r in rows.firstIndex(where: { $0 === r }).map { $0 + 1 } } ?? rows.count
        rows.insert(newRow, at: insertIndex)
        rowsStack.insertArrangedSubview(newRow.stack, at: insertIndex)
        newRow.stack.leadingAnchor.constraint(equalTo: rowsStack.leadingAnchor).isActive = true
        newRow.stack.trailingAnchor.constraint(equalTo: rowsStack.trailingAnchor).isActive = true

        // First row ever defaults to $set (legacy); new rows pick the first
        // unused operator via the dedup pass.
        if rows.count == 1, let setIndex = titleIndex(of: "$set") {
            newRow.popup.selectItem(at: setIndex)
        } else {
            newRow.popup.selectItem(at: -1)
        }
        reconcileOperatorRows()
    }

    private func titleIndex(of operatorKey: String) -> Int? {
        var menuIndex = 0
        for entry in Self.operators {
            if entry.isEmpty {
                menuIndex += 1
            } else {
                if entry[0] == operatorKey { return menuIndex }
                menuIndex += 1
            }
        }
        return nil
    }

    private func operatorKey(forMenuIndex index: Int) -> String? {
        guard index >= 0, index < Self.operators.count else { return nil }
        let entry = Self.operators[index]
        return entry.isEmpty ? nil : entry[0]
    }

    /// Each operator may be used once; +/- enablement follows (legacy rules).
    private func reconcileOperatorRows() {
        var used = Set<Int>()
        for row in rows {
            var index = row.popup.indexOfSelectedItem
            if index < 0 || used.contains(index) || operatorKey(forMenuIndex: index) == nil {
                index = (0..<Self.operators.count).first {
                    operatorKey(forMenuIndex: $0) != nil && !used.contains($0)
                } ?? -1
                row.popup.selectItem(at: index)
            }
            if index >= 0 { used.insert(index) }
        }
        let allUsed = used.count >= Self.operators.filter { !$0.isEmpty }.count
        for row in rows {
            row.addButton.isEnabled = !allUsed
            row.removeButton.isEnabled = rows.count > 1
            for (itemIndex, item) in (row.popup.menu?.items ?? []).enumerated() {
                item.isEnabled =
                    !item.isSeparatorItem
                    && (!used.contains(itemIndex) || itemIndex == row.popup.indexOfSelectedItem)
            }
        }
        composePreview()
    }

    @objc private func addRowAction(_ sender: NSButton) {
        addOperatorRow(after: rows.first { $0.addButton === sender })
    }

    @objc private func removeRowAction(_ sender: NSButton) {
        guard rows.count > 1, let index = rows.firstIndex(where: { $0.removeButton === sender })
        else { return }
        let row = rows.remove(at: index)
        rowsStack.removeArrangedSubview(row.stack)
        row.stack.removeFromSuperview()
        reconcileOperatorRows()
    }

    @objc private func operatorPopupChanged(_ sender: Any?) {
        reconcileOperatorRows()
    }

    // MARK: - Compose / run

    private var normalizedCriteria: String {
        QueryNormalizer.normalizeCriteria(criteriaField.stringValue, emptyIsValid: false)
    }

    @objc private func composeAction(_ sender: Any?) {
        composePreview()
    }

    private func composePreview() {
        var sets: [String] = []
        for row in rows {
            guard let key = operatorKey(forMenuIndex: row.popup.indexOfSelectedItem) else { continue }
            let value = row.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            sets.append("\(key): \(value.isEmpty ? "{ }" : value)")
        }
        var preview = "db.\(context.collection).update(\(normalizedCriteria), {\(sets.joined(separator: ", "))}"
        if upsertCheckbox.state == .on || multiCheckbox.state == .on {
            var flags: [String] = []
            if upsertCheckbox.state == .on { flags.append("upsert: true") }
            if multiCheckbox.state == .on { flags.append("multi: true") }
            preview += ", {\(flags.joined(separator: ", "))}"
        }
        preview += ")"
        previewField.stringValue = preview
    }

    @objc func updateAction(_ sender: Any?) {
        guard let session = context.session() else { return }
        composePreview()

        let criteria: Document
        do {
            criteria = try ExtendedJSON.parseDocument(normalizedCriteria)
        } catch {
            QueryPaneUI.flash(resultLabel, text: "Error!", success: false)
            QueryPaneUI.alertSheet(in: view, title: String(localized: "Error In Query"), message: String(describing: error))
            view.window?.makeFirstResponder(criteriaField)
            return
        }

        var update = Document()
        for row in rows {
            guard let key = operatorKey(forMenuIndex: row.popup.indexOfSelectedItem) else { continue }
            let text = QueryNormalizer.normalizeCriteria(row.field.stringValue, emptyIsValid: false)
            do {
                update[key] = try ExtendedJSON.parseDocument(text)
            } catch {
                QueryPaneUI.flash(resultLabel, text: "Error!", success: false)
                QueryPaneUI.alertSheet(
                    in: view, title: "Error In \(row.popup.titleOfSelectedItem ?? key)",
                    message: String(describing: error))
                view.window?.makeFirstResponder(row.field)
                return
            }
        }
        guard !update.isEmpty else {
            QueryPaneUI.flash(resultLabel, text: "Nothing to update", success: false)
            return
        }

        let multi = multiCheckbox.state == .on
        let upsert = upsertCheckbox.state == .on
        spinner.startAnimation(nil)
        Task {
            do {
                var command = Document()
                command["update"] = context.collection
                var updates = Document(isArray: true)
                var spec = Document()
                spec["q"] = criteria
                spec["u"] = update
                spec["upsert"] = upsert
                spec["multi"] = multi
                updates["0"] = spec
                command["updates"] = updates
                let reply = try await session.runCommand(command, onDatabase: context.database)
                self.spinner.stopAnimation(nil)
                let n = (reply["n"] as? Int32).map(Int.init) ?? reply["n"] as? Int ?? 0
                QueryPaneUI.flash(self.resultLabel, text: "Updated Documents: \(n)", success: true)
            } catch {
                self.spinner.stopAnimation(nil)
                QueryPaneUI.flash(self.resultLabel, text: "Error!", success: false)
                QueryPaneUI.alertSheet(in: self.view, title: String(localized: "Update Failed"), message: String(describing: error))
            }
        }
    }
}

extension UpdatePaneController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        composePreview()
    }

    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            updateAction(nil)
            return true
        }
        return false
    }
}

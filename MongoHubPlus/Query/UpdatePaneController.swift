import AppKit
import BSON
import ExtendedJSON
import MongoService

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

    // MARK: - Preview (feature-spec 3.21)

    private let previewHeader = NSTextField(labelWithString: "")
    private let previewStack = NSStackView()
    private let previewScroll = NSScrollView()
    /// Shown instead of the preview when the update cannot be read — bad JSON
    /// in a value field, nothing to update. The count survives it, because the
    /// count only ever depended on the query.
    private let previewProblem = NSTextField(labelWithString: "")
    private var updateButton: NSButton!
    private var refreshWork: DispatchWorkItem?
    /// Collapses the problem line when there is nothing wrong. `isHidden`
    /// alone does not: outside a stack view a hidden view keeps its height,
    /// which left a blank band under the Preview heading.
    private var previewProblemCollapsed: NSLayoutConstraint!
    private var matchCount: Int?

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
        multiCheckbox.state = .on

        updateButton = QueryPaneUI.runButton(
            title: String(localized: "Update"), target: self, action: #selector(updateAction(_:)))
        updateButton.keyEquivalent = "r"
        updateButton.keyEquivalentModifierMask = .command
        updateButton.setContentHuggingPriority(.required, for: .horizontal)

        let criteriaRow = NSStackView(views: [
            NSTextField(labelWithString: String(localized: "Query")), criteriaField,
            upsertCheckbox, multiCheckbox, updateButton!,
        ])
        criteriaRow.orientation = .horizontal
        criteriaRow.spacing = 6
        criteriaRow.translatesAutoresizingMaskIntoConstraints = false
        criteriaField.fillsRowWidth()

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 6
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        previewHeader.font = .systemFont(ofSize: 11)
        previewHeader.textColor = .secondaryLabelColor
        previewHeader.translatesAutoresizingMaskIntoConstraints = false

        previewProblem.font = .systemFont(ofSize: 11)
        previewProblem.textColor = .systemOrange
        previewProblem.lineBreakMode = .byWordWrapping
        previewProblem.maximumNumberOfLines = 3
        previewProblem.translatesAutoresizingMaskIntoConstraints = false

        previewStack.orientation = .vertical
        previewStack.alignment = .leading
        previewStack.spacing = 10
        previewStack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        previewStack.translatesAutoresizingMaskIntoConstraints = false
        // A scroll view lays its document view out from the bottom unless the
        // view is flipped, which would park the first document off screen.
        let previewDocument = FlippedView()
        previewDocument.translatesAutoresizingMaskIntoConstraints = false
        previewDocument.addSubview(previewStack)
        previewScroll.documentView = previewDocument
        previewScroll.hasVerticalScroller = true
        previewScroll.borderType = .bezelBorder
        previewScroll.drawsBackground = true
        previewScroll.backgroundColor = JSONTheme.current.background
        previewScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            previewStack.topAnchor.constraint(equalTo: previewDocument.topAnchor),
            previewStack.leadingAnchor.constraint(equalTo: previewDocument.leadingAnchor),
            previewStack.trailingAnchor.constraint(equalTo: previewDocument.trailingAnchor),
            previewStack.bottomAnchor.constraint(equalTo: previewDocument.bottomAnchor),
            previewDocument.widthAnchor.constraint(equalTo: previewScroll.contentView.widthAnchor),
        ])

        container.addSubview(previewField)
        container.addSubview(spinner)
        container.addSubview(criteriaRow)
        container.addSubview(rowsStack)
        container.addSubview(previewHeader)
        previewProblemCollapsed = previewProblem.heightAnchor.constraint(equalToConstant: 0)
        container.addSubview(previewProblem)
        container.addSubview(previewScroll)
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

            previewHeader.topAnchor.constraint(equalTo: rowsStack.bottomAnchor, constant: 12),
            previewHeader.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            previewHeader.trailingAnchor.constraint(
                lessThanOrEqualTo: container.trailingAnchor, constant: -8),

            previewProblem.topAnchor.constraint(equalTo: previewHeader.bottomAnchor, constant: 4),
            previewProblemCollapsed,
            previewProblem.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            previewProblem.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -8),

            previewScroll.topAnchor.constraint(equalTo: previewProblem.bottomAnchor, constant: 4),
            previewScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            previewScroll.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -8),
            previewScroll.bottomAnchor.constraint(equalTo: resultLabel.topAnchor, constant: -8),

            resultLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            resultLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 8),
            resultLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
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
        newRow.field.fillsRowWidth()
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

    /// Prefill from the Find pane's Update… button (owner request
    /// 2026-09-15): criteria only, never run.
    func prefillCriteria(_ criteria: String) {
        criteriaField.stringValue = criteria
        if isViewLoaded { composePreview() }
    }

    /// UI-verification hook: fills the first operator row so the preview can
    /// be exercised without driving the text fields by hand
    /// (--args -MAUpdateOperator Set -MAUpdateValue64 <base64 EJSON>).
    func debugSetOperator(named name: String?, value: String?) {
        loadViewIfNeeded()
        guard let row = rows.first else { return }
        if let name, let index = row.popup.itemTitles.firstIndex(of: name) {
            row.popup.selectItem(at: index)
        }
        if let value { row.field.stringValue = value }
        composePreview()
    }

    private var normalizedCriteria: String {
        QueryNormalizer.normalizeCriteria(criteriaField.stringValue, emptyIsValid: false)
    }

    @objc private func composeAction(_ sender: Any?) {
        composePreview()
    }

    private func composePreview() {
        schedulePreviewRefresh()
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

    // MARK: - Preview + affected count (feature-spec 3.21)

    /// Re-reads the query and the operator rows and refreshes both halves.
    /// Debounced, because it runs on every keystroke.
    private func schedulePreviewRefresh() {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshPreview() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// The update spec as the operator rows currently read, or the reason it
    /// cannot be read. Same parse the Update button uses, so what you preview
    /// is what you would run.
    private enum ComposedUpdate {
        case ready(Document)
        case unreadable(String)
    }

    private func composedUpdate() -> ComposedUpdate {
        var update = Document()
        for row in rows {
            guard let key = operatorKey(forMenuIndex: row.popup.indexOfSelectedItem) else { continue }
            let text = QueryNormalizer.normalizeCriteria(row.field.stringValue, emptyIsValid: false)
            do {
                update[key] = try ExtendedJSON.parseDocument(text)
            } catch {
                let name = row.popup.titleOfSelectedItem ?? key
                return .unreadable("\(name): \(error)")
            }
        }
        guard !update.isEmpty else {
            return .unreadable(String(localized: "Nothing to update"))
        }
        return .ready(update)
    }

    private func refreshPreview() {
        guard let session = context.session() else { return }

        let criteria: Document
        do {
            criteria = try ExtendedJSON.parseDocument(normalizedCriteria)
        } catch {
            // A query that does not parse has no match count and nothing to
            // sample, so both halves go quiet rather than showing stale rows.
            matchCount = nil
            showPreviewProblem(String(localized: "Query: \(String(describing: error))"))
            return
        }

        let composed = composedUpdate()
        if case .unreadable(let reason) = composed {
            showPreviewProblem(reason)
        }

        Task {
            let count = try? await session.count(
                database: self.context.database, collection: self.context.collection,
                filter: criteria)
            self.matchCount = count
            self.updateButtonTitle()

            guard case .ready(let update) = composed else { return }
            let samples =
                (try? await session.find(
                    database: self.context.database, collection: self.context.collection,
                    filter: criteria, options: .init(limit: 3))) ?? []
            self.showPreview(samples: samples, update: update)
        }
    }

    private func showPreview(samples: [Document], update: Document) {
        var rendered: [(document: Document, effects: [UpdateEffect])] = []
        for sample in samples {
            do {
                var effects = try UpdatePreview.effects(of: update, on: sample)
                effects += UpdatePreview.renameAdditions(of: update, on: sample)
                rendered.append((sample, effects))
            } catch {
                showPreviewProblem(String(describing: error))
                return
            }
        }
        previewProblem.stringValue = ""
        previewProblem.isHidden = true
        previewProblemCollapsed.isActive = true
        previewHeader.stringValue = String(
            format: String(localized: "Preview (sample of %d documents)"), rendered.count)
        setPreviewCards(
            rendered.map {
                UpdatePreviewRenderer.render(
                    document: $0.document, effects: $0.effects, theme: JSONTheme.current)
            })
        updateButton.isEnabled = true
    }

    /// Clears the preview and says why, the way Compass does: the diff goes
    /// rather than going stale, and Update is refused until it reads again.
    private func showPreviewProblem(_ message: String) {
        previewHeader.stringValue = String(
            format: String(localized: "Preview (sample of %d documents)"), 0)
        setPreviewCards([])
        previewProblem.stringValue = message.replacingOccurrences(of: "\n", with: " ")
        previewProblem.isHidden = false
        previewProblemCollapsed.isActive = false
        updateButton.isEnabled = false
    }

    /// One bordered card per document, the way Compass separates them — a
    /// blank line between two JSON blobs reads as part of the document.
    private func setPreviewCards(_ documents: [NSAttributedString]) {
        let theme = JSONTheme.current
        for view in previewStack.arrangedSubviews {
            previewStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for document in documents {
            let card = NSView()
            card.translatesAutoresizingMaskIntoConstraints = false
            card.wantsLayer = true
            card.layer?.backgroundColor = theme.background.cgColor
            card.layer?.cornerRadius = 6
            card.layer?.borderWidth = 1
            card.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

            let label = NSTextField(labelWithAttributedString: document)
            label.isSelectable = true
            label.allowsEditingTextAttributes = true
            // Selecting hands the text to the window's shared field editor,
            // which redraws it with the field's own font and colour — the
            // system defaults — unless the field is marked as carrying
            // attributed text. Without this, clicking a card turned the whole
            // document white in the system font.
            label.font = theme.font
            label.textColor = theme.text
            label.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
                label.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
                label.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
                label.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
            ])
            previewStack.addArrangedSubview(card)
            card.widthAnchor.constraint(
                equalTo: previewStack.widthAnchor, constant: -20
            ).isActive = true
        }
    }

    /// "Update 28 documents" — the count is the query's result count and has
    /// nothing to do with the operators, so it survives a broken update.
    private func updateButtonTitle() {
        guard let matchCount else {
            updateButton.title = String(localized: "Update")
            return
        }
        if multiCheckbox.state == .on {
            updateButton.title = String(
                format: String(localized: "Update %d documents"), matchCount)
        } else {
            // Without Multi only the first match is written, so promising 28
            // would be a lie.
            updateButton.title = String(
                format: String(localized: "Update 1 of %d matching"), matchCount)
        }
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
        // ⌘Return expands the id shortcuts into the criteria field first
        // (feature-spec 3.3), so they are visible before the update runs.
        if commandSelector == QueryPaneUI.noopSelector, control === criteriaField,
            QueryPaneUI.isCommandReturn
        {
            if QueryPaneUI.expandIDShortcuts(in: criteriaField) { composePreview() }
            updateAction(nil)
            return true
        }
        return false
    }
}

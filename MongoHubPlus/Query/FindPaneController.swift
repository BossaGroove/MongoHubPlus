import AppKit
import BSON
import ExtendedJSON
import MongoService

/// The Find sub-tab (legacy MHQueryViewController's find pane): criteria
/// history combo, sort/fields/skip/limit, live preview, results outline,
/// pagination, per-document JSON editors.
@MainActor
final class FindPaneController: NSViewController {
    private let context: QueryPaneContext

    private let queryPreviewField = QueryPaneUI.previewField()
    private let spinner = QueryPaneUI.spinner()
    private let criteriaCombo = NSComboBox()
    private let sortField = NSTextField(string: "")
    private let fieldsField = NSTextField(string: "")
    private let skipField = NSTextField(string: "")
    private let limitField = NSTextField(string: "")
    private let resultsOutline = DocumentOutlineViewController(
        options: .init(
            showsFooter: true, showsRemoveButton: true, showsPagination: true,
            autosaveName: "find-outline"))

    private var history: [QueryHistoryEntry] = []
    private var editorWindows: [Data: JSONEditorWindowController] = [:]

    init(context: QueryPaneContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
        reloadHistory()
        NotificationCenter.default.addObserver(
            self, selector: #selector(editorDidSave(_:)),
            name: .jsonEditorDidSaveDocument, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func closeEditors() {
        for (_, editor) in editorWindows {
            editor.close()
        }
        editorWindows.removeAll()
    }

    var initialFirstResponder: NSView { criteriaCombo }

    override func loadView() {
        let container = NSView()

        func label(_ text: String) -> NSTextField {
            NSTextField(labelWithString: text)
        }

        criteriaCombo.usesDataSource = true
        criteriaCombo.dataSource = self
        criteriaCombo.delegate = self
        criteriaCombo.numberOfVisibleItems = 5
        criteriaCombo.completes = true
        criteriaCombo.placeholderString = String(localized: "Query or id")
        sortField.placeholderString = String(localized: "{_id: 1}")
        fieldsField.placeholderString = String(localized: "{ }")
        skipField.placeholderString = String(localized: "0")
        skipField.alignment = .right
        limitField.placeholderString = String(localized: "30")
        limitField.alignment = .right
        for field in [sortField, fieldsField, skipField, limitField] {
            field.delegate = self
        }

        let runButton = QueryPaneUI.runButton(title: String(localized: "Run"), target: self, action: #selector(runQuery(_:)))
        runButton.keyEquivalent = "r"
        runButton.keyEquivalentModifierMask = .command
        runButton.toolTip = String(localized: "Run (⌘R)")

        let explainButton = NSButton(
            title: String(localized: "Explain"), target: self, action: #selector(explainQuery(_:)))
        explainButton.bezelStyle = .rounded
        explainButton.controlSize = .small
        explainButton.keyEquivalent = "r"
        explainButton.keyEquivalentModifierMask = [.command, .shift]
        explainButton.toolTip = String(localized: "Explain (⇧⌘R)")

        let row2 = NSStackView(views: [label(String(localized: "Query or id")), criteriaCombo, label(String(localized: "Sort")), sortField])
        let row3 = NSStackView(views: [
            label(String(localized: "Fields")), fieldsField, label(String(localized: "Skip")), skipField, label(String(localized: "Limit")), limitField,
            explainButton, runButton,
        ])
        for row in [row2, row3] {
            row.orientation = .horizontal
            row.spacing = 6
            row.translatesAutoresizingMaskIntoConstraints = false
        }
        criteriaCombo.setContentHuggingPriority(.init(1), for: .horizontal)
        fieldsField.setContentHuggingPriority(.init(1), for: .horizontal)
        sortField.widthAnchor.constraint(equalToConstant: 150).isActive = true
        skipField.widthAnchor.constraint(equalToConstant: 56).isActive = true
        limitField.widthAnchor.constraint(equalToConstant: 56).isActive = true

        resultsOutline.delegate = self
        resultsOutline.onEditValue = { [weak self] node, root, text in
            self?.commitInlineEdit(node: node, root: root, text: text)
        }
        resultsOutline.onExportResults = { [weak self] in
            self?.exportResults()
        }
        resultsOutline.onAddField = { [weak self] node, root in
            self?.promptAddField(node: node, root: root)
        }
        resultsOutline.onDeleteField = { [weak self] node, root in
            self?.promptDeleteField(node: node, root: root)
        }
        resultsOutline.onExportSelected = { [weak self] documents in
            guard let self, let window = self.view.window else { return }
            ImportExport.exportDocuments(
                documents,
                suggestedName: "\(self.context.database)-\(self.context.collection)-selected",
                window: window)
        }
        let resultsView = resultsOutline.view
        resultsView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(queryPreviewField)
        container.addSubview(spinner)
        container.addSubview(row2)
        container.addSubview(row3)
        container.addSubview(resultsView)
        NSLayoutConstraint.activate([
            queryPreviewField.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            queryPreviewField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            queryPreviewField.trailingAnchor.constraint(equalTo: spinner.leadingAnchor, constant: -6),

            spinner.centerYAnchor.constraint(equalTo: queryPreviewField.centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),

            row2.topAnchor.constraint(equalTo: queryPreviewField.bottomAnchor, constant: 6),
            row2.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            row2.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            row3.topAnchor.constraint(equalTo: row2.bottomAnchor, constant: 6),
            row3.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            row3.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            resultsView.topAnchor.constraint(equalTo: row3.bottomAnchor, constant: 6),
            resultsView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            resultsView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            resultsView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        addChild(resultsOutline)
        composePreview()
        view = container
    }

    // MARK: - Query composition (legacy findQueryComposer)

    private var normalizedCriteria: String {
        QueryNormalizer.normalizeCriteria(criteriaCombo.stringValue, emptyIsValid: false)
    }

    private var effectiveSort: String {
        let sort = sortField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if sort.isEmpty {
            return Preferences.defaultSortAscending ? "{_id: 1}" : "{_id: -1}"
        }
        return QueryNormalizer.normalizeCriteria(sort, emptyIsValid: false)
    }

    private var effectiveLimit: Int {
        let value = Int(limitField.stringValue) ?? 0
        return value <= 0 ? 30 : value
    }

    private var effectiveSkip: Int {
        max(0, Int(skipField.stringValue) ?? 0)
    }

    private func composePreview() {
        var preview = "db.\(context.collection).find(\(normalizedCriteria)"
        let fields = fieldsField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fields.isEmpty {
            preview += ", \(QueryNormalizer.normalizeCriteria(fields, emptyIsValid: false))"
        }
        preview += ").sort(\(effectiveSort)).skip(\(effectiveSkip)).limit(\(effectiveLimit))"
        queryPreviewField.stringValue = preview
    }

    // MARK: - Export current results (owner request 2026-09-01)

    /// Parses the pane's current criteria/sort/projection into an export
    /// query; skip/limit are deliberately excluded (full matching set).
    private func currentExportQuery() throws -> ImportExport.ExportQuery {
        var query = ImportExport.ExportQuery()
        query.filter = try ExtendedJSON.parseDocument(normalizedCriteria)
        query.sort = try ExtendedJSON.parseDocument(effectiveSort)
        let fieldsText = fieldsField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fieldsText.isEmpty {
            query.projection = try ExtendedJSON.parseDocument(
                QueryNormalizer.normalizeCriteria(fieldsText, emptyIsValid: false))
        }
        return query
    }

    func exportResults() {
        guard let session = context.session(), let window = view.window else { return }
        do {
            let query = try currentExportQuery()
            ImportExport.exportResults(
                database: context.database, collection: context.collection, query: query,
                session: session, window: window)
        } catch {
            resultsOutline.displayErrorLabel(String(describing: error))
        }
    }

    /// UI-verification hooks: preset the query fields / export without panels.
    func debugSetQuery(criteria: String?, fields: String?, sort: String? = nil) {
        if let criteria { criteriaCombo.stringValue = criteria }
        if let fields { fieldsField.stringValue = fields }
        if let sort { sortField.stringValue = sort }
    }

    func debugExportResults(to url: URL) {
        guard let session = context.session(), let window = view.window,
            let query = try? currentExportQuery()
        else { return }
        ImportExport.debugExportResults(
            to: url, database: context.database, collection: context.collection, query: query,
            session: session, window: window)
    }

    // MARK: - Add / delete fields (M4a follow-up, 4.7)

    /// Resolves where a field would be added for the clicked node: the node
    /// itself when it is a container, otherwise its parent.
    private func addTarget(
        node: OutlineNode, root: OutlineNode
    ) -> (containerPath: [String], container: Document)? {
        guard let rootDocument = root.rootDocument else { return nil }
        var containerPath = node.path
        if !(node.value is Document) {
            containerPath = Array(node.path.dropLast())
        }
        var container: Document = rootDocument
        for segment in containerPath {
            guard let next = container[segment] as? Document else { return nil }
            container = next
        }
        return (containerPath, container)
    }

    private func promptAddField(node: OutlineNode, root: OutlineNode) {
        guard let window = view.window,
            let target = addTarget(node: node, root: root)
        else { return }
        let isArray = target.container.isArray
        let alert = NSAlert()
        alert.messageText = String(localized: "Add Field")
        alert.informativeText = target.containerPath.isEmpty
            ? String(localized: "Top level")
            : target.containerPath.joined(separator: ".")
        alert.addButton(withTitle: String(localized: "Add"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let nameField = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
        nameField.placeholderString = String(localized: "field name")
        let valueField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        valueField.placeholderString = String(localized: "value (Extended JSON or text)")
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: isArray ? 24 : 58))
        if isArray {
            valueField.frame.origin.y = 0
            accessory.addSubview(valueField)
        } else {
            accessory.addSubview(nameField)
            accessory.addSubview(valueField)
        }
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = isArray ? valueField : nameField
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.performAddField(
                root: root, containerPath: target.containerPath,
                name: isArray ? nil : nameField.stringValue,
                valueText: valueField.stringValue)
        }
    }

    /// `name == nil` appends to an array container.
    func performAddField(root: OutlineNode, containerPath: [String], name: String?, valueText: String) {
        guard let session = context.session(), let id = root.documentID,
            let rootDocument = root.rootDocument
        else { return }
        var container: Document = rootDocument
        for segment in containerPath {
            guard let next = container[segment] as? Document else { return }
            container = next
        }
        let fieldName: String
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.contains("."), !trimmed.hasPrefix("$") else {
                return showInlineEditError(String(localized: "Invalid field name"))
            }
            guard container[trimmed] == nil else {
                return showInlineEditError(
                    String(localized: "A field named \"\(trimmed)\" already exists."))
            }
            fieldName = trimmed
        } else {
            fieldName = String(container.values.count)  // array append index
        }
        let value: Primitive = (try? ExtendedJSON.parseValue(valueText)) ?? valueText
        let fieldPath = (containerPath + [fieldName]).joined(separator: ".")

        Task {
            do {
                var update = Document()
                if name == nil {
                    var push = Document()
                    push[containerPath.joined(separator: ".")] = value
                    update["$push"] = push
                } else {
                    var set = Document()
                    set[fieldPath] = value
                    update["$set"] = set
                }
                try await self.applyUpdate(update, id: id, session: session)
                let newRoot = Self.settingValue(
                    rootDocument, path: containerPath + [fieldName], value: value)
                self.resultsOutline.replaceRoot(root, with: newRoot)
                root.setRootDocument(newRoot)
            } catch {
                self.showInlineEditError(String(describing: error))
            }
        }
    }

    private func promptDeleteField(node: OutlineNode, root: OutlineNode) {
        guard let window = view.window else { return }
        let path = node.path.joined(separator: ".")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Delete field \"\(path)\"?")
        alert.informativeText = String(localized: "This action cannot be undone.")
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.buttons[1].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            self?.performDeleteField(root: root, path: node.path)
        }
    }

    func performDeleteField(root: OutlineNode, path: [String]) {
        guard let session = context.session(), let id = root.documentID,
            let rootDocument = root.rootDocument, !path.isEmpty
        else { return }
        // Array elements: $unset leaves null holes, so rebuild the parent
        // array without the element and $set it instead.
        let parentPath = Array(path.dropLast())
        var parent: Document = rootDocument
        for segment in parentPath {
            guard let next = parent[segment] as? Document else { return }
            parent = next
        }
        Task {
            do {
                var update = Document()
                let newRoot: Document
                if parent.isArray, let index = Int(path.last ?? "") {
                    var newArray = Document(isArray: true)
                    var position = 0
                    for (valueIndex, value) in parent.values.enumerated()
                    where valueIndex != index {
                        newArray[String(position)] = value
                        position += 1
                    }
                    var set = Document()
                    set[parentPath.joined(separator: ".")] = newArray
                    update["$set"] = set
                    newRoot = Self.settingValue(
                        rootDocument, path: parentPath, value: newArray)
                } else {
                    var unset = Document()
                    unset[path.joined(separator: ".")] = 1
                    update["$unset"] = unset
                    newRoot = Self.removingValue(rootDocument, path: path)
                }
                try await self.applyUpdate(update, id: id, session: session)
                self.resultsOutline.replaceRoot(root, with: newRoot)
                root.setRootDocument(newRoot)
            } catch {
                self.showInlineEditError(String(describing: error))
            }
        }
    }

    private func applyUpdate(
        _ update: Document, id: Primitive, session: ConnectionSession
    ) async throws {
        var updateSpec = Document()
        var query = Document()
        query["_id"] = id
        updateSpec["q"] = query
        updateSpec["u"] = update
        var updates = Document(isArray: true)
        updates["0"] = updateSpec
        var command = Document()
        command["update"] = context.collection
        command["updates"] = updates
        let reply = try await session.runCommand(command, onDatabase: context.database)
        let matched = (reply["n"] as? Int32).map(Int.init) ?? (reply["n"] as? Int) ?? 0
        guard matched > 0 else {
            struct NotFound: Error, CustomStringConvertible {
                var description: String { "Document not found (was it deleted?)" }
            }
            throw NotFound()
        }
    }

    /// Returns a copy of `document` without the value at `path`.
    static func removingValue(_ document: Document, path: [String]) -> Document {
        var copy = document
        guard let key = path.first else { return copy }
        if path.count == 1 {
            copy[key] = nil
        } else if let nested = copy[key] as? Document {
            copy[key] = removingValue(nested, path: Array(path.dropFirst()))
        }
        return copy
    }

    // MARK: - Explain (3.15)

    @objc func explainQuery(_ sender: Any?) {
        guard let session = context.session(), let window = view.window else { return }
        do {
            let query = try currentExportQuery()
            var target = Document()
            target["find"] = context.collection
            if !query.filter.isEmpty { target["filter"] = query.filter }
            if let sort = query.sort, !sort.isEmpty { target["sort"] = sort }
            if let projection = query.projection, !projection.isEmpty {
                target["projection"] = projection
            }
            if effectiveSkip > 0 { target["skip"] = Int32(effectiveSkip) }
            target["limit"] = Int32(effectiveLimit)
            let sheet = ExplainSheetController(
                database: context.database, explainTarget: target, session: session)
            explainSheet = sheet
            if let sheetWindow = sheet.window {
                window.beginSheet(sheetWindow) { [weak self] _ in
                    self?.explainSheet = nil
                }
            }
        } catch {
            resultsOutline.displayErrorLabel(String(describing: error))
        }
    }

    private var explainSheet: ExplainSheetController?

    // MARK: - Run

    @objc func runQuery(_ sender: Any?) {
        guard let session = context.session() else { return }
        composePreview()

        let criteriaText = normalizedCriteria
        let sortText = effectiveSort
        let fieldsText = fieldsField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let skip = effectiveSkip
        let limit = effectiveLimit

        let criteria: Document
        let sort: Document
        var projection: Document?
        do {
            criteria = try ExtendedJSON.parseDocument(criteriaText)
        } catch {
            return showParseError(error, in: criteriaCombo)
        }
        do {
            sort = try ExtendedJSON.parseDocument(sortText)
        } catch {
            return showParseError(error, in: sortField)
        }
        if !fieldsText.isEmpty {
            do {
                projection = try ExtendedJSON.parseDocument(
                    QueryNormalizer.normalizeCriteria(fieldsText, emptyIsValid: false))
            } catch {
                return showParseError(error, in: fieldsField)
            }
        }

        criteriaCombo.stringValue = criteriaCombo.stringValue.trimmingCharacters(
            in: .whitespacesAndNewlines)
        spinner.startAnimation(nil)
        let started = Date()

        Task {
            do {
                let documents = try await session.find(
                    database: context.database, collection: context.collection, filter: criteria,
                    options: .init(projection: projection, sort: sort, skip: skip, limit: limit))
                self.spinner.stopAnimation(nil)
                self.rememberQuery()
                self.resultsOutline.display(documents: documents, label: nil)
                self.resultsOutline.setBackButtonEnabled(skip > 0)
                // UI-verification hook: open the editor on the first result.
                if UserDefaults.standard.bool(forKey: "MAEditFirstResult"),
                    let first = documents.first
                {
                    self.openEditor(for: first)
                }
                // UI-verification hook: -MAInlineEdit "field=EJSON value"
                // exercises the in-place editing path on the first result.
                if let spec = UserDefaults.standard.string(forKey: "MAInlineEdit"),
                    let eq = spec.firstIndex(of: "="),
                    let root = self.resultsOutline.nodes.first
                {
                    var node: OutlineNode? = nil
                    var children = root.children
                    for segment in spec[..<eq].split(separator: ".").map(String.init) {
                        node = children.first(where: { $0.name == segment })
                        children = node?.children ?? []
                    }
                    if let node {
                        self.autoConfirmTypeChange = true
                        self.commitInlineEdit(
                            node: node, root: root, text: String(spec[spec.index(after: eq)...]))
                    }
                }
                // UI-verification hook: open the explain sheet.
                if UserDefaults.standard.bool(forKey: "MAExplain") {
                    self.explainQuery(nil)
                }
                // UI-verification hooks: structure edits on the first result.
                // -MAAddField64 "container.name=value" ("" container = top level,
                //  trailing "." appends to an array container)
                if let encoded = UserDefaults.standard.string(forKey: "MAAddField64"),
                    let data = Data(base64Encoded: encoded),
                    let spec = String(data: data, encoding: .utf8),
                    let eq = spec.firstIndex(of: "="),
                    let root = self.resultsOutline.nodes.first
                {
                    let target = String(spec[..<eq])
                    let valueText = String(spec[spec.index(after: eq)...])
                    var segments = target.split(
                        separator: ".", omittingEmptySubsequences: false
                    ).map(String.init)
                    let name = segments.removeLast()
                    self.performAddField(
                        root: root, containerPath: segments.filter { !$0.isEmpty },
                        name: name.isEmpty ? nil : name, valueText: valueText)
                }
                if let encoded = UserDefaults.standard.string(forKey: "MADeleteField64"),
                    let data = Data(base64Encoded: encoded),
                    let spec = String(data: data, encoding: .utf8),
                    let root = self.resultsOutline.nodes.first
                {
                    self.performDeleteField(
                        root: root, path: spec.split(separator: ".").map(String.init))
                }
                // UI-verification hook: -MAStartInlineEdit "field" shows the
                // in-place edit field (for screenshot checks).
                if let field = UserDefaults.standard.string(forKey: "MAStartInlineEdit"),
                    let root = self.resultsOutline.nodes.first,
                    let node = root.children.first(where: { $0.name == field })
                {
                    self.resultsOutline.debugBeginInlineEdit(node: node)
                    // -MACancelInlineEdit: blur without changes (shares the
                    // Esc restore path) so the display rendering must return.
                    if UserDefaults.standard.bool(forKey: "MACancelInlineEdit") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                            self?.view.window?.makeFirstResponder(nil)
                        }
                    }
                }

                let count = try await session.count(
                    database: context.database, collection: context.collection, filter: criteria)
                let elapsed = Date().timeIntervalSince(started)
                self.resultsOutline.setLabel(
                    String(format: String(localized: "Total Results: %d (%.2fs)"), count, elapsed))
            } catch {
                self.spinner.stopAnimation(nil)
                self.resultsOutline.displayError(String(describing: error))
                self.queryPreviewField.stringValue = "Error: \(error)"
            }
        }
    }

    private func showParseError(_ error: any Error, in control: NSControl) {
        resultsOutline.displayError("Error: \(error)")
        queryPreviewField.stringValue = "Error: \(error)"
        view.window?.makeFirstResponder(control)
    }

    private func rememberQuery() {
        let criteria = criteriaCombo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !criteria.isEmpty else { return }
        QueryHistoryStore.shared.add(
            QueryHistoryEntry(
                criteria: criteria,
                fields: fieldsField.stringValue,
                sort: sortField.stringValue,
                skip: effectiveSkip,
                limit: effectiveLimit),
            connectionID: context.connectionID, database: context.database,
            collection: context.collection)
        reloadHistory()
    }

    private func reloadHistory() {
        history = QueryHistoryStore.shared.entries(
            connectionID: context.connectionID, database: context.database,
            collection: context.collection)
        if isViewLoaded {
            criteriaCombo.reloadData()
        }
    }

    // MARK: - In-place value editing (feature-spec 4.4)

    /// Parses the edited text, reconciles its BSON type against the old
    /// value (never silently changing a type), writes a `$set` to the
    /// server, then patches the outline in place.
    func commitInlineEdit(node: OutlineNode, root: OutlineNode, text: String) {
        guard let oldValue = node.value, let id = root.documentID,
            let rootDocument = root.rootDocument
        else { return }

        var newValue: Primitive
        do {
            newValue = try ExtendedJSON.parseValue(text)
        } catch {
            if oldValue is String {
                // Convenience: unparseable input on a string field is taken
                // literally (typing quotes around plain text is a chore).
                newValue = text
            } else {
                resultsOutline.revertEdit(node: node)
                return showInlineEditError("Not valid Extended JSON: \(error)")
            }
        }

        // Type reconciliation ("never silently change a value's BSON type"):
        // lossless numeric coercion to the old type is silent; anything else
        // needs explicit confirmation.
        if BSONDisplay.typeName(newValue) != BSONDisplay.typeName(oldValue) {
            if let coerced = Self.coerce(newValue, toTypeOf: oldValue) {
                newValue = coerced
            } else {
                let alert = NSAlert()
                alert.messageText = String(localized: "Change the field's type?")
                alert.informativeText =
                    "\(node.path.joined(separator: ".")) is \(BSONDisplay.typeName(oldValue)); "
                    + "the new value is \(BSONDisplay.typeName(newValue))."
                alert.addButton(withTitle: String(localized: "Change Type"))
                alert.addButton(withTitle: String(localized: "Cancel"))
                if !autoConfirmTypeChange, alert.runModal() != .alertFirstButtonReturn {
                    resultsOutline.revertEdit(node: node)
                    return
                }
            }
        }

        guard let session = context.session() else { return }
        let value = newValue
        Task {
            do {
                var updateSpec = Document()
                var query = Document()
                query["_id"] = id
                updateSpec["q"] = query
                var set = Document()
                set[node.path.joined(separator: ".")] = value
                updateSpec["u"] = ["$set": set] as Document
                var updates = Document(isArray: true)
                updates["0"] = updateSpec
                var command = Document()
                command["update"] = self.context.collection
                command["updates"] = updates
                let reply = try await session.runCommand(
                    command, onDatabase: self.context.database)
                let matched = (reply["n"] as? Int32).map(Int.init) ?? (reply["n"] as? Int) ?? 0
                guard matched > 0 else {
                    struct NotFound: Error, CustomStringConvertible {
                        var description: String { "Document not found (was it deleted?)" }
                    }
                    throw NotFound()
                }
                let newRoot = Self.settingValue(rootDocument, path: node.path, value: value)
                self.resultsOutline.applyEdit(
                    node: node, root: root, newValue: value, newRootDocument: newRoot)
            } catch {
                self.resultsOutline.revertEdit(node: node)
                self.showInlineEditError(String(describing: error))
            }
        }
    }

    /// UI-verification hook (-MAInlineEdit): skips the type-change alert.
    var autoConfirmTypeChange = false

    private func showInlineEditError(_ message: String) {
        resultsOutline.displayErrorLabel(message)
    }

    /// Lossless numeric coercion to the old value's BSON type.
    static func coerce(_ value: Primitive, toTypeOf old: Primitive) -> Primitive? {
        switch (value, old) {
        case (let v as Int32, is Int): return Int(v)
        case (let v as Int32, is Double): return Double(v)
        case (let v as Int, is Int32):
            return Int32(exactly: v)
        case (let v as Int, is Double):
            let d = Double(v)
            return Int(d) == v ? d : nil
        case (let v as Double, is Int32):
            return v.truncatingRemainder(dividingBy: 1) == 0 ? Int32(exactly: v) : nil
        case (let v as Double, is Int):
            return v.truncatingRemainder(dividingBy: 1) == 0 ? Int(exactly: v) : nil
        default: return nil
        }
    }

    /// Returns a copy of `document` with the value at `path` replaced,
    /// preserving key order end-to-end.
    static func settingValue(_ document: Document, path: [String], value: Primitive) -> Document {
        var copy = document
        guard let key = path.first else { return copy }
        if path.count == 1 {
            copy[key] = value
        } else if let nested = copy[key] as? Document {
            copy[key] = settingValue(nested, path: Array(path.dropFirst()), value: value)
        }
        return copy
    }

    // MARK: - Document editing

    private func openEditor(for document: Document) {
        guard let session = context.session() else { return }
        let key = documentKey(document)
        if let existing = editorWindows[key] {
            existing.showWindow(nil)
            return
        }
        let editor = JSONEditorWindowController(
            document: document,
            namespace: context.namespace,
            database: context.database, collection: context.collection,
            connectionID: context.connectionID,
            session: session)
        editor.onClose = { [weak self] in
            self?.editorWindows[key] = nil
        }
        editorWindows[key] = editor
        editor.showWindow(nil)
    }

    private func documentKey(_ document: Document) -> Data {
        var key = Document()
        key["_id"] = document["_id"]
        return key.makeData()
    }

    @objc private func editorDidSave(_ notification: Notification) {
        guard let info = notification.userInfo,
            info["connectionID"] as? UUID == context.connectionID,
            info["namespace"] as? String == context.namespace
        else { return }
        runQuery(nil)
    }
}

// MARK: - Results outline delegate

extension FindPaneController: DocumentOutlineDelegate {
    func documentOutline(
        _ controller: DocumentOutlineViewController, deleteDocumentsWithIDs ids: [Primitive]
    ) {
        guard let session = context.session() else { return }
        var idArray = Document(isArray: true)
        for (index, id) in ids.enumerated() {
            idArray[String(index)] = id
        }
        var filter = Document()
        filter["_id"] = ["$in": idArray] as Document

        spinner.startAnimation(nil)
        Task {
            do {
                var command = Document()
                command["delete"] = context.collection
                var deletes = Document(isArray: true)
                var spec = Document()
                spec["q"] = filter
                spec["limit"] = Int32(0)
                deletes["0"] = spec
                command["deletes"] = deletes
                _ = try await session.runCommand(command, onDatabase: context.database)
                self.spinner.stopAnimation(nil)
                controller.removeDocuments(withIDs: ids)
            } catch {
                self.spinner.stopAnimation(nil)
                controller.displayError(String(describing: error))
            }
        }
    }

    func documentOutline(
        _ controller: DocumentOutlineViewController, doubleClickedDocument document: Document
    ) {
        openEditor(for: document)
    }

    func documentOutlineNextPage(_ controller: DocumentOutlineViewController) {
        skipField.stringValue = String(effectiveSkip + effectiveLimit)
        runQuery(nil)
    }

    func documentOutlinePreviousPage(_ controller: DocumentOutlineViewController) {
        guard effectiveSkip > 0 else { return }
        skipField.stringValue = String(max(0, effectiveSkip - effectiveLimit))
        runQuery(nil)
    }
}

// MARK: - Criteria combo box (history) + live preview

extension FindPaneController: NSComboBoxDataSource, NSComboBoxDelegate, NSTextFieldDelegate {
    func numberOfItems(in comboBox: NSComboBox) -> Int {
        history.count
    }

    func comboBox(_ comboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? {
        history.indices.contains(index) ? history[index].criteria : nil
    }

    func comboBox(_ comboBox: NSComboBox, completedString string: String) -> String? {
        history.first { $0.criteria.hasPrefix(string) }?.criteria
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        let index = criteriaCombo.indexOfSelectedItem
        guard history.indices.contains(index) else { return }
        let entry = history[index]
        fieldsField.stringValue = entry.fields
        sortField.stringValue = entry.sort
        skipField.stringValue = entry.skip == 0 ? "" : String(entry.skip)
        limitField.stringValue = entry.limit == 30 ? "" : String(entry.limit)
        composePreview()
    }

    func controlTextDidChange(_ obj: Notification) {
        composePreview()
    }

    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            runQuery(nil)
            return true
        }
        // Tab from the query box goes to Sort, not Fields (owner request —
        // matches the visual row order, not the automatic key loop).
        if commandSelector == #selector(NSResponder.insertTab(_:)), control === criteriaCombo {
            view.window?.makeFirstResponder(sortField)
            return true
        }
        if commandSelector == #selector(NSResponder.insertBacktab(_:)), control === sortField {
            view.window?.makeFirstResponder(criteriaCombo)
            return true
        }
        if commandSelector == #selector(NSResponder.insertBacktab(_:)), control === fieldsField {
            view.window?.makeFirstResponder(sortField)
            return true
        }
        if commandSelector == #selector(NSResponder.insertTab(_:)), control === sortField {
            view.window?.makeFirstResponder(fieldsField)
            return true
        }
        return false
    }
}

import AppKit
import BSON
import ExtendedJSON

/// A row in the results outline. Top-level rows represent whole documents
/// (named/valued by `_id`, falling back to `name`, then the first key — the
/// legacy MODHelper rule); child rows are fields.
@MainActor
final class OutlineNode {
    let name: String
    private(set) var value: Primitive?
    private(set) var valueText: String
    private(set) var typeText: String
    let children: [OutlineNode]
    /// Key path from the root document ("a", "0", "b" …); empty on root rows
    /// and in field-per-row (stats) mode.
    let path: [String]
    /// Set on top-level rows only.
    private(set) var rootDocument: Document?
    let documentID: Primitive?

    init(
        name: String, value: Primitive?, children: [OutlineNode], path: [String] = [],
        rootDocument: Document? = nil, documentID: Primitive? = nil
    ) {
        self.name = name
        self.value = value
        self.valueText = value.map(BSONDisplay.valueString) ?? ""
        self.typeText = value.map(BSONDisplay.typeName) ?? ""
        self.children = children
        self.path = path
        self.rootDocument = rootDocument
        self.documentID = documentID
    }

    init(name: String, valueText: String, typeText: String) {
        self.name = name
        self.value = nil
        self.valueText = valueText
        self.typeText = typeText
        self.children = []
        self.path = []
        self.rootDocument = nil
        self.documentID = nil
    }

    /// In-place value patch after a successful server-side edit.
    func setValue(_ newValue: Primitive) {
        value = newValue
        valueText = BSONDisplay.valueString(newValue)
        typeText = BSONDisplay.typeName(newValue)
    }

    func setRootDocument(_ document: Document) {
        rootDocument = document
    }

    static func nodes(from documents: [Document]) -> [OutlineNode] {
        documents.map { document in
            let idName: String
            let idValue: Primitive?
            if let id = document["_id"] {
                idName = "_id"
                idValue = id
            } else if let name = document["name"] {
                idName = "name"
                idValue = name
            } else if let first = document.pairs.first(where: { _ in true }) {
                idName = first.key
                idValue = first.value
            } else {
                idName = ""
                idValue = nil
            }
            return OutlineNode(
                name: idName, value: idValue,
                children: fieldNodes(of: document, path: []),
                rootDocument: document, documentID: idValue)
        }
    }

    /// One row per top-level field — used by the Status tab (legacy's
    /// `convertForOutlineWithObject:`), where rows are fields, not documents.
    static func fieldRows(of document: Document) -> [OutlineNode] {
        fieldNodes(of: document, path: [])
    }

    private static func fieldNodes(of document: Document, path: [String]) -> [OutlineNode] {
        var nodes: [OutlineNode] = []
        if document.isArray {
            for (index, value) in document.values.enumerated() {
                nodes.append(node(name: String(index), value: value, path: path + [String(index)]))
            }
        } else {
            var pairs = Array(document.pairs)
            switch Preferences.jsonKeyOrder {
            case .ascending: pairs.sort { $0.key < $1.key }
            case .descending: pairs.sort { $0.key > $1.key }
            case .document: break
            }
            for pair in pairs {
                nodes.append(node(name: pair.key, value: pair.value, path: path + [pair.key]))
            }
        }
        return nodes
    }

    private static func node(name: String, value: Primitive, path: [String]) -> OutlineNode {
        let children = (value as? Document).map { fieldNodes(of: $0, path: path) } ?? []
        return OutlineNode(name: name, value: value, children: children, path: path)
    }
}

@MainActor
protocol DocumentOutlineDelegate: AnyObject {
    func documentOutlineSelectionDidChange(_ controller: DocumentOutlineViewController)
    func documentOutline(
        _ controller: DocumentOutlineViewController, deleteDocumentsWithIDs ids: [Primitive])
    func documentOutline(
        _ controller: DocumentOutlineViewController, doubleClickedDocument document: Document)
    func documentOutlineNextPage(_ controller: DocumentOutlineViewController)
    func documentOutlinePreviousPage(_ controller: DocumentOutlineViewController)
}

extension DocumentOutlineDelegate {
    func documentOutlineSelectionDidChange(_ controller: DocumentOutlineViewController) {}
    func documentOutline(
        _ controller: DocumentOutlineViewController, deleteDocumentsWithIDs ids: [Primitive]) {}
    func documentOutline(
        _ controller: DocumentOutlineViewController, doubleClickedDocument document: Document) {}
    func documentOutlineNextPage(_ controller: DocumentOutlineViewController) {}
    func documentOutlinePreviousPage(_ controller: DocumentOutlineViewController) {}
}

/// The reusable 3-column (Name / Value / Type) results outline with its
/// configurable footer (legacy MHDocumentOutlineViewController).
@MainActor
final class DocumentOutlineViewController: NSViewController, NSMenuItemValidation {
    struct Options {
        var showsFooter = true
        var showsRemoveButton = true
        var showsPagination = true
        var autosaveName: String
    }

    weak var delegate: DocumentOutlineDelegate?

    /// When set, leaf scalar values become editable in place (double-click
    /// the Value cell). Called with the node, its root, and the edited text;
    /// the owner parses/validates and writes to the server.
    var onEditValue: ((_ node: OutlineNode, _ root: OutlineNode, _ text: String) -> Void)?

    /// When set, the context menu offers exporting the query's full matching
    /// set / the selected documents (Find results only).
    var onExportResults: (() -> Void)?
    var onExportSelected: (([Document]) -> Void)?

    /// Structure edits (M4a follow-up): add a field into / delete the
    /// clicked node. Wired by the Find pane only.
    var onAddField: ((_ node: OutlineNode, _ root: OutlineNode) -> Void)?
    var onDeleteField: ((_ node: OutlineNode, _ root: OutlineNode) -> Void)?

    private let options: Options
    private(set) var nodes: [OutlineNode] = []
    private var editingField: NSTextField?
    private var editingOriginalText = ""

    private let outlineView = NSOutlineView()
    private let feedbackLabel = NSTextField(labelWithString: "")
    private var backButton: NSButton!
    private var nextButton: NSButton!
    private var removeButton: NSButton!
    private var expandPopup: NSPopUpButton!

    init(options: Options) {
        self.options = options
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()

        // Outline
        for (identifier, title, width) in [
            ("name", String(localized: "Name"), 180.0), ("value", String(localized: "Value"), 300.0),
            ("type", String(localized: "Type"), 110.0),
        ] {
            let column = NSTableColumn(identifier: .init(identifier))
            column.title = title
            column.width = width
            column.minWidth = identifier == "type" ? 80 : 40
            outlineView.addTableColumn(column)
        }
        outlineView.outlineTableColumn = outlineView.tableColumns[0]
        outlineView.usesAlternatingRowBackgroundColors = true
        // Full-width rows — the default .automatic style resolves to the
        // padded/rounded "inset" look and shifts as content changes.
        outlineView.style = .plain
        outlineView.rowSizeStyle = .custom
        outlineView.rowHeight = Self.rowHeight
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesChanged), name: .preferencesDidChange,
            object: nil)
        outlineView.indentationPerLevel = 12
        outlineView.allowsMultipleSelection = true
        outlineView.autosaveTableColumns = true
        outlineView.autosaveName = options.autosaveName
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(doubleClickAction(_:))

        let contextMenu = NSMenu()
        contextMenu.delegate = self
        outlineView.menu = contextMenu

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)

        guard options.showsFooter else {
            NSLayoutConstraint.activate([
                scrollView.topAnchor.constraint(equalTo: root.topAnchor),
                scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
            view = root
            return
        }

        // Footer
        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        feedbackLabel.font = .systemFont(ofSize: 11)
        feedbackLabel.lineBreakMode = .byTruncatingTail
        feedbackLabel.translatesAutoresizingMaskIntoConstraints = false
        feedbackLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footer.addSubview(feedbackLabel)

        var trailingViews: [NSView] = []

        expandPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        expandPopup.controlSize = .small
        expandPopup.font = .systemFont(ofSize: 11)
        for (title, tag, key) in [
            (String(localized: "Expand 0"), 0, "0"), (String(localized: "Expand 1"), 1, "1"),
            (String(localized: "Expand 2"), 2, "2"),
            (String(localized: "Expand 3"), 3, "3"), (String(localized: "Expand ∞"), 100, "4"),
        ] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: key)
            item.keyEquivalentModifierMask = [.option, .command]
            item.tag = tag
            expandPopup.menu?.addItem(item)
        }
        expandPopup.selectItem(at: 0)
        // UI-verification hook: preselect an expansion depth.
        let debugDepth = UserDefaults.standard.integer(forKey: "MAExpandDepth")
        if debugDepth > 0, let item = expandPopup.menu?.items.first(where: { $0.tag == debugDepth }) {
            expandPopup.select(item)
        }
        expandPopup.target = self
        expandPopup.action = #selector(expandPopupAction(_:))
        trailingViews.append(expandPopup)

        if options.showsPagination {
            backButton = NSButton(
                image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Previous")!,
                target: self, action: #selector(backAction(_:)))
            backButton.toolTip = String(localized: "Previous results (⌥⌘←)")
            backButton.isEnabled = false
            nextButton = NSButton(
                image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Next")!,
                target: self, action: #selector(nextAction(_:)))
            nextButton.toolTip = String(localized: "Next results (⌥⌘→)")
            for button in [backButton!, nextButton!] {
                button.bezelStyle = .texturedRounded
                button.controlSize = .small
            }
            trailingViews.insert(contentsOf: [backButton!, nextButton!], at: 0)
        }

        if options.showsRemoveButton {
            removeButton = NSButton(title: String(localized: "Remove"), target: self, action: #selector(removeAction(_:)))
            removeButton.bezelStyle = .texturedRounded
            removeButton.controlSize = .small
            removeButton.isEnabled = false
            removeButton.toolTip = String(localized: "Remove selected documents (⌘⌫)")
            trailingViews.insert(removeButton, at: 0)
        }

        let trailingStack = NSStackView(views: trailingViews)
        trailingStack.orientation = .horizontal
        trailingStack.spacing = 6
        trailingStack.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(trailingStack)

        root.addSubview(footer)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 26),

            feedbackLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 8),
            feedbackLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            feedbackLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingStack.leadingAnchor, constant: -8),

            trailingStack.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -8),
            trailingStack.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
        view = root
    }

    // MARK: - Text size (Preferences → Results Text Size)

    private static var textSize: CGFloat { Preferences.resultsTextSize }
    private static var rowHeight: CGFloat { Preferences.resultsTextSize + 8 }

    @objc private func preferencesChanged() {
        guard isViewLoaded else { return }
        outlineView.rowHeight = Self.rowHeight
        outlineView.reloadData()
    }

    // MARK: - Display

    func display(documents: [Document], label: String?) {
        display(nodes: OutlineNode.nodes(from: documents), label: label)
    }

    /// Field-per-row display for stats documents (Status tab).
    func display(fields document: Document) {
        display(nodes: OutlineNode.fieldRows(of: document), label: nil)
    }

    private func display(nodes newNodes: [OutlineNode], label: String?) {
        nodes = newNodes
        outlineView.reloadData()
        applyExpansion()
        if let label {
            flashLabel(label, color: .systemGreen)
        } else if options.showsFooter {
            feedbackLabel.stringValue = ""
        }
        updateRemoveButton()
    }

    func displayError(_ message: String) {
        if options.showsFooter {
            nodes = []
            outlineView.reloadData()
            flashLabel(message, color: .systemRed)
        } else {
            // No footer label — surface the error as a row (legacy behavior).
            nodes = [OutlineNode(name: "error", valueText: message, typeText: "")]
            outlineView.reloadData()
        }
    }

    func setLabel(_ text: String) {
        flashLabel(text, color: .systemGreen)
    }

    /// Error feedback that keeps the current rows (unlike `displayError`).
    func displayErrorLabel(_ message: String) {
        flashLabel(message, color: .systemRed)
    }

    func setBackButtonEnabled(_ enabled: Bool) {
        backButton?.isEnabled = enabled
    }

    private func flashLabel(_ text: String, color: NSColor) {
        feedbackLabel.stringValue = text
        feedbackLabel.textColor = color
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.5
                self?.feedbackLabel.animator().textColor = .labelColor
            }
        }
    }

    // MARK: - Selection helpers

    /// Resolves any selected row to its top-level document (legacy rootForItem).
    var selectedRootNodes: [OutlineNode] {
        var roots: [OutlineNode] = []
        for row in outlineView.selectedRowIndexes {
            var item = outlineView.item(atRow: row)
            while let node = item, outlineView.parent(forItem: node) != nil {
                item = outlineView.parent(forItem: node)
            }
            if let root = item as? OutlineNode, !roots.contains(where: { $0 === root }) {
                roots.append(root)
            }
        }
        return roots
    }

    var hasSelection: Bool {
        !outlineView.selectedRowIndexes.isEmpty
    }

    // MARK: - Actions

    @objc private func expandPopupAction(_ sender: Any?) {
        applyExpansion()
    }

    private func applyExpansion() {
        let depth = options.showsFooter ? (expandPopup.selectedTag()) : 0
        switch depth {
        case 0:
            outlineView.collapseItem(nil, collapseChildren: true)
        case 100:
            outlineView.expandItem(nil, expandChildren: true)
        default:
            // Walk rows top-down; expanding reveals children which are then
            // themselves visited (legacy algorithm).
            var row = 0
            while row < outlineView.numberOfRows {
                if let item = outlineView.item(atRow: row) {
                    if outlineView.level(forItem: item) < depth {
                        outlineView.expandItem(item)
                    } else {
                        outlineView.collapseItem(item)
                    }
                }
                row += 1
            }
        }
    }

    @objc private func removeAction(_ sender: Any?) {
        let ids = selectedRootNodes.compactMap(\.documentID)
        guard !ids.isEmpty else { return }
        delegate?.documentOutline(self, deleteDocumentsWithIDs: ids)
    }

    /// Called back by the owner after a successful server-side delete.
    func removeDocuments(withIDs ids: [Primitive]) {
        let idData = ids.map(primitiveKey)
        nodes.removeAll { node in
            guard let id = node.documentID else { return false }
            return idData.contains(primitiveKey(id))
        }
        outlineView.reloadData()
        applyExpansion()
        setLabel(
            ids.count == 1
                ? String(localized: "1 document removed")
                : String(localized: "\(ids.count) documents removed"))
        updateRemoveButton()
    }

    private func primitiveKey(_ primitive: Primitive) -> Data {
        var doc = Document()
        doc["k"] = primitive
        return doc.makeData()
    }

    @objc private func backAction(_ sender: Any?) {
        delegate?.documentOutlinePreviousPage(self)
    }

    @objc private func nextAction(_ sender: Any?) {
        delegate?.documentOutlineNextPage(self)
    }

    @objc private func doubleClickAction(_ sender: Any?) {
        // Double-click on an editable Value cell edits in place; anywhere
        // else opens the JSON editor window (both editors — owner request).
        let row = outlineView.clickedRow
        let column = outlineView.clickedColumn
        if row >= 0, column >= 0,
            outlineView.tableColumns[column].identifier.rawValue == "value",
            let node = outlineView.item(atRow: row) as? OutlineNode,
            isEditable(node)
        {
            beginInlineEdit(row: row)
            return
        }
        guard let document = selectedRootNodes.first?.rootDocument else { return }
        delegate?.documentOutline(self, doubleClickedDocument: document)
    }

    // MARK: - In-place value editing (feature-spec 4.4)

    /// Leaf scalars inside a document that has an `_id` are editable; `_id`
    /// itself is immutable, and `$`/`.`-containing key segments can't be
    /// addressed by an update path (use the JSON editor for those).
    func isEditable(_ node: OutlineNode) -> Bool {
        guard onEditValue != nil,
            node.children.isEmpty,
            let value = node.value, !(value is Document),
            !node.path.isEmpty,
            node.path != ["_id"],
            rootNode(of: node)?.documentID != nil
        else { return false }
        return !node.path.contains { $0.contains(".") || $0.hasPrefix("$") }
    }

    private func rootNode(of node: OutlineNode) -> OutlineNode? {
        var item: Any? = node
        while let current = item, outlineView.parent(forItem: current) != nil {
            item = outlineView.parent(forItem: current)
        }
        return item as? OutlineNode
    }

    func beginInlineEdit(row: Int) {
        guard let node = outlineView.item(atRow: row) as? OutlineNode,
            isEditable(node), let value = node.value,
            let columnIndex = outlineView.tableColumns.firstIndex(where: {
                $0.identifier.rawValue == "value"
            }),
            let cell = outlineView.view(atColumn: columnIndex, row: row, makeIfNecessary: true)
                as? NSTableCellView,
            let field = cell.textField
        else { return }

        // Prefill with a lossless, parseable representation of the value.
        let text =
            (try? ExtendedJSON.stringifyValue(
                value, format: EJSONFormat(mode: .editor, pretty: false))) ?? node.valueText
        endInlineEdit(commit: false)
        field.stringValue = text
        field.isEditable = true
        field.delegate = self
        editingField = field
        editingOriginalText = text
        outlineView.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func endInlineEdit(commit: Bool) {
        guard let field = editingField else { return }
        let text = field.stringValue
        editingField = nil
        field.isEditable = false
        field.delegate = nil
        if commit, text != editingOriginalText,
            let row = rowOfCell(containing: field),
            let node = outlineView.item(atRow: row) as? OutlineNode,
            let root = rootNode(of: node)
        {
            onEditValue?(node, root, text)
        } else if let row = rowOfCell(containing: field),
            let node = outlineView.item(atRow: row) as? OutlineNode
        {
            // Cancelled/unchanged: restore the display rendering, not the
            // Extended JSON editing prefill (owner report).
            field.stringValue = node.valueText
        } else {
            field.stringValue = editingOriginalText
        }
    }

    private func rowOfCell(containing field: NSTextField) -> Int? {
        var view: NSView? = field
        while let current = view, !(current is NSTableCellView) { view = current.superview }
        guard let cell = view else { return nil }
        let row = outlineView.row(for: cell)
        return row >= 0 ? row : nil
    }

    /// Called back by the owner after a successful server-side value update.
    func applyEdit(node: OutlineNode, root: OutlineNode, newValue: Primitive, newRootDocument: Document) {
        node.setValue(newValue)
        root.setRootDocument(newRootDocument)
        outlineView.reloadItem(node)
        setLabel("Saved \(node.path.joined(separator: "."))")
    }

    /// Called back by the owner when the edit was rejected — restores the
    /// cell to the node's (unchanged) value.
    func revertEdit(node: OutlineNode) {
        outlineView.reloadItem(node)
    }

    /// UI-verification hook: expands and begins editing a node's value cell.
    func debugBeginInlineEdit(node: OutlineNode) {
        outlineView.expandItem(nil, expandChildren: true)
        let row = outlineView.row(forItem: node)
        if row >= 0 {
            beginInlineEdit(row: row)
        }
    }

    private func updateRemoveButton() {
        removeButton?.isEnabled = !selectedRootNodes.compactMap(\.documentID).isEmpty
    }

    // MARK: - Copy (documents as an Extended JSON array — legacy parity)

    @objc func copy(_ sender: Any?) {
        let documents = selectedRootNodes.compactMap(\.rootDocument)
        guard !documents.isEmpty else { return }
        var array = Document(isArray: true)
        for (index, document) in documents.enumerated() {
            array[String(index)] = document
        }
        guard let text = try? ExtendedJSON.stringify(array, format: .editor) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)) {
            return !selectedRootNodes.isEmpty
        }
        return true
    }
}

// MARK: - Inline edit field events

extension DocumentOutlineViewController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        endInlineEdit(commit: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            endInlineEdit(commit: false)
            outlineView.window?.makeFirstResponder(outlineView)
            return true
        }
        return false
    }
}

// MARK: - Context menu

extension DocumentOutlineViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? OutlineNode else { return }
        if !outlineView.selectedRowIndexes.contains(row) {
            outlineView.selectRowIndexes([row], byExtendingSelection: false)
        }
        if isEditable(node) {
            let item = menu.addItem(
                withTitle: String(localized: "Edit Value"), action: #selector(editValueMenuAction(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = row
        }
        if onAddField != nil, canAddField(into: node) {
            let item = menu.addItem(
                withTitle: String(localized: "Add Field…"),
                action: #selector(addFieldMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = row
        }
        if onDeleteField != nil, canDeleteField(node) {
            let item = menu.addItem(
                withTitle: String(localized: "Delete Field…"),
                action: #selector(deleteFieldMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = row
        }
        if onEditValue != nil, rootNode(of: node)?.rootDocument != nil {
            let item = menu.addItem(
                withTitle: String(localized: "Open in JSON Editor…"),
                action: #selector(openJSONEditorMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = row
        }
        let copyItem = menu.addItem(
            withTitle: String(localized: "Copy"), action: #selector(copy(_:)), keyEquivalent: "")
        copyItem.target = self
        if onExportResults != nil {
            menu.addItem(.separator())
            let results = menu.addItem(
                withTitle: String(localized: "Export Results…"),
                action: #selector(exportResultsMenuAction(_:)), keyEquivalent: "")
            results.target = self
            if onExportSelected != nil, !selectedRootNodes.compactMap(\.rootDocument).isEmpty {
                let selected = menu.addItem(
                    withTitle: String(localized: "Export Selected Documents…"),
                    action: #selector(exportSelectedMenuAction(_:)), keyEquivalent: "")
                selected.target = self
            }
        }
    }

    @objc private func exportResultsMenuAction(_ sender: Any?) {
        onExportResults?()
    }

    @objc private func exportSelectedMenuAction(_ sender: Any?) {
        let documents = selectedRootNodes.compactMap(\.rootDocument)
        guard !documents.isEmpty else { return }
        onExportSelected?(documents)
    }

    @objc private func editValueMenuAction(_ sender: NSMenuItem) {
        guard let row = sender.representedObject as? Int else { return }
        beginInlineEdit(row: row)
    }

    /// Fields can be added at the root, into a container node, or beside a
    /// leaf (into its parent) — as long as the document has an _id and the
    /// path is addressable.
    private func canAddField(into node: OutlineNode) -> Bool {
        guard rootNode(of: node)?.documentID != nil else { return false }
        return !node.path.contains { $0.contains(".") || $0.hasPrefix("$") }
    }

    private func canDeleteField(_ node: OutlineNode) -> Bool {
        guard rootNode(of: node)?.documentID != nil,
            !node.path.isEmpty, node.path != ["_id"]
        else { return false }
        return !node.path.contains { $0.contains(".") || $0.hasPrefix("$") }
    }

    @objc private func addFieldMenuAction(_ sender: NSMenuItem) {
        guard let row = sender.representedObject as? Int,
            let node = outlineView.item(atRow: row) as? OutlineNode,
            let root = rootNode(of: node)
        else { return }
        onAddField?(node, root)
    }

    @objc private func deleteFieldMenuAction(_ sender: NSMenuItem) {
        guard let row = sender.representedObject as? Int,
            let node = outlineView.item(atRow: row) as? OutlineNode,
            let root = rootNode(of: node)
        else { return }
        onDeleteField?(node, root)
    }

    /// Replaces a root document after a structure edit (add/delete field):
    /// the node subtree is rebuilt, global expansion depth reapplied.
    func replaceRoot(_ root: OutlineNode, with newDocument: Document) {
        guard let index = nodes.firstIndex(where: { $0 === root }) else { return }
        let rebuilt = OutlineNode.nodes(from: [newDocument])
        guard let newRoot = rebuilt.first else { return }
        nodes[index] = newRoot
        outlineView.reloadData()
        applyExpansion()
        outlineView.expandItem(newRoot)
    }

    @objc private func openJSONEditorMenuAction(_ sender: NSMenuItem) {
        guard let row = sender.representedObject as? Int,
            let node = outlineView.item(atRow: row) as? OutlineNode,
            let document = rootNode(of: node)?.rootDocument
        else { return }
        delegate?.documentOutline(self, doubleClickedDocument: document)
    }
}

// MARK: - Outline data source / delegate

extension DocumentOutlineViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? OutlineNode else { return nodes.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? OutlineNode else { return nodes[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? OutlineNode)?.children.isEmpty == false
    }

    func outlineView(
        _ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any
    ) -> NSView? {
        guard let node = item as? OutlineNode, let identifier = tableColumn?.identifier else {
            return nil
        }
        let text: String
        switch identifier.rawValue {
        case "name": text = node.name
        case "value": text = node.valueText
        default: text = node.typeText
        }

        let reuseID = NSUserInterfaceItemIdentifier("cell-\(identifier.rawValue)")
        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: reuseID, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = reuseID
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = text
        cell.textField?.font = Preferences.resultsFont(
            size: Self.textSize, bold: identifier.rawValue == "name")
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        updateRemoveButton()
        delegate?.documentOutlineSelectionDidChange(self)
    }
}

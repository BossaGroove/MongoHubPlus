import AppKit
import BSON
import ExtendedJSON
import MongoService

/// The Index sub-tab: list (⌘R), create via sheet, drop selected
/// (legacy pane + TTL support that legacy lacked — feature-spec 3.8).
@MainActor
final class IndexPaneController: NSViewController, DocumentOutlineDelegate {
    private let context: QueryPaneContext

    private let spinner = QueryPaneUI.spinner()
    private var dropButton: NSButton!
    private let outline = DocumentOutlineViewController(
        options: .init(
            showsFooter: true, showsRemoveButton: false, showsPagination: false,
            autosaveName: "index-outline"))
    private var indexEditor: IndexEditorController?

    init(context: QueryPaneContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView()

        let listButton = NSButton(
            title: String(localized: "Get Indexes"), target: self, action: #selector(reloadIndexes(_:)))
        listButton.image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: nil)
        listButton.imagePosition = .imageLeading
        listButton.keyEquivalent = "r"
        listButton.keyEquivalentModifierMask = .command
        listButton.toolTip = String(localized: "⌘R")

        let createButton = NSButton(
            title: String(localized: "Create Index…"), target: self, action: #selector(createIndexAction(_:)))
        createButton.image = NSImage(named: NSImage.addTemplateName)
        createButton.imagePosition = .imageLeading

        dropButton = NSButton(title: String(localized: "Drop Index"), target: self, action: #selector(dropIndexAction(_:)))
        dropButton.image = NSImage(named: NSImage.stopProgressTemplateName)
        dropButton.imagePosition = .imageLeading
        dropButton.isEnabled = false
        dropButton.keyEquivalent = String(UnicodeScalar(NSBackspaceCharacter)!)
        dropButton.keyEquivalentModifierMask = .command
        dropButton.toolTip = String(localized: "⌘⌫")

        let buttonRow = NSStackView(views: [listButton, createButton, dropButton, spinner])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        outline.delegate = self
        let outlineView = outline.view
        outlineView.translatesAutoresizingMaskIntoConstraints = false
        addChild(outline)

        container.addSubview(buttonRow)
        container.addSubview(outlineView)
        NSLayoutConstraint.activate([
            buttonRow.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            buttonRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),

            outlineView.topAnchor.constraint(equalTo: buttonRow.bottomAnchor, constant: 6),
            outlineView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            outlineView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            outlineView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        reloadIndexes(nil)
    }

    @objc func reloadIndexes(_ sender: Any?) {
        guard let session = context.session() else { return }
        spinner.startAnimation(nil)
        Task {
            do {
                var command = Document()
                command["listIndexes"] = context.collection
                var indexes = try await session.collectCursor(
                    command: command, onDatabase: context.database)

                // Merge $indexStats usage (ops count + counting-since date)
                // into each index; degrade gracefully when unavailable
                // (privileges, views, …). Counters reset at server restart
                // and are per-node on replica sets.
                var usageLabel: String
                do {
                    var pipeline = Document(isArray: true)
                    pipeline["0"] = ["$indexStats": Document()] as Document
                    let stats = try await session.aggregate(
                        database: self.context.database, collection: self.context.collection,
                        pipeline: pipeline)
                    var usageByName: [String: Document] = [:]
                    for stat in stats {
                        guard let name = stat["name"] as? String,
                            let accesses = stat["accesses"] as? Document
                        else { continue }
                        var usage = Document()
                        usage["ops"] = accesses["ops"]
                        usage["since"] = accesses["since"]
                        usageByName[name] = usage
                    }
                    for (position, index) in indexes.enumerated() {
                        guard let name = index["name"] as? String,
                            let usage = usageByName[name]
                        else { continue }
                        var augmented = index
                        augmented["usage"] = usage
                        indexes[position] = augmented
                    }
                    let unused = stats.compactMap { stat -> String? in
                        guard let name = stat["name"] as? String, name != "_id_",
                            Self.intValue(
                                (stat["accesses"] as? Document)?["ops"]) == 0
                        else { return nil }
                        return name
                    }
                    if unused.isEmpty {
                        usageLabel = String(
                            localized: "Usage: all indexes used (since server restart)")
                    } else {
                        let names = unused.joined(separator: ", ")
                        usageLabel = String(
                            localized: "Usage: unused — \(names) (since server restart)")
                    }
                } catch {
                    usageLabel = String(localized: "Index usage unavailable: \(String(describing: error))")
                }
                self.spinner.stopAnimation(nil)
                self.outline.display(documents: indexes, label: usageLabel)
            } catch {
                self.spinner.stopAnimation(nil)
                self.outline.displayError(String(describing: error))
            }
        }
    }

    private static func intValue(_ primitive: Primitive?) -> Int? {
        switch primitive {
        case let value as Int32: return Int(value)
        case let value as Int: return value
        case let value as Double: return Int(value)
        default: return nil
        }
    }

    @objc func createIndexAction(_ sender: Any?) {
        guard indexEditor == nil, let window = view.window else { return }
        let editor = IndexEditorController()
        indexEditor = editor
        guard let sheet = editor.window else { return }
        window.beginSheet(sheet) { [weak self] response in
            defer { self?.indexEditor = nil }
            guard response == .OK, let self, let spec = editor.indexSpecification else { return }
            self.createIndex(spec)
        }
    }

    private func createIndex(_ spec: Document) {
        guard let session = context.session() else { return }
        spinner.startAnimation(nil)
        Task {
            do {
                var command = Document()
                command["createIndexes"] = context.collection
                var indexes = Document(isArray: true)
                indexes["0"] = spec
                command["indexes"] = indexes
                _ = try await session.runCommand(command, onDatabase: context.database)
                self.spinner.stopAnimation(nil)
                self.reloadIndexes(nil)
            } catch {
                self.spinner.stopAnimation(nil)
                QueryPaneUI.alertSheet(
                    in: self.view, title: String(localized: "Create Index Failed"), message: String(describing: error))
            }
        }
    }

    @objc func dropIndexAction(_ sender: Any?) {
        guard let session = context.session(),
            let node = outline.selectedRootNodes.first,
            let name = node.rootDocument?["name"] as? String
        else { return }
        spinner.startAnimation(nil)
        Task {
            do {
                var command = Document()
                command["dropIndexes"] = context.collection
                command["index"] = name
                _ = try await session.runCommand(command, onDatabase: context.database)
                self.spinner.stopAnimation(nil)
                self.reloadIndexes(nil)
            } catch {
                self.spinner.stopAnimation(nil)
                QueryPaneUI.alertSheet(
                    in: self.view, title: String(localized: "Drop Index Failed"), message: String(describing: error))
            }
        }
    }

    func documentOutlineSelectionDidChange(_ controller: DocumentOutlineViewController) {
        dropButton.isEnabled = controller.selectedRootNodes.count == 1
    }
}

/// The Create Index sheet (legacy MHIndexEditor + TTL). Produces a spec
/// document for the `createIndexes` command.
@MainActor
final class IndexEditorController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private struct KeyRow {
        var name: String = ""
        var sorting: Int = 0  // 0 asc, 1 desc, 2 hashed
    }

    private let nameField = NSTextField(string: "")
    private let uniqueCheckbox = NSButton(checkboxWithTitle: "Unique", target: nil, action: nil)
    private let sparseCheckbox = NSButton(checkboxWithTitle: "Sparse", target: nil, action: nil)
    private let ttlCheckbox = NSButton(checkboxWithTitle: "TTL — expire after", target: nil, action: nil)
    private let ttlSecondsField = NSTextField(string: "")
    private let tableView = NSTableView()
    private var addKeyButton: NSButton!
    private var removeKeyButton: NSButton!
    private var saveButton: NSButton!
    private var keys: [KeyRow] = []

    /// Set when the sheet ends with `.OK`.
    private(set) var indexSpecification: Document?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
            styleMask: [.titled], backing: .buffered, defer: false)
        self.init(window: window)
        buildContent()
    }

    private func buildContent() {
        guard let window else { return }
        let content = NSView()
        content.widthAnchor.constraint(equalToConstant: 460).isActive = true

        nameField.placeholderString = String(localized: "Optional")
        for checkbox in [uniqueCheckbox, sparseCheckbox, ttlCheckbox] {
            checkbox.target = self
            checkbox.action = #selector(updateControls(_:))
        }
        ttlSecondsField.placeholderString = String(localized: "seconds")
        ttlSecondsField.alignment = .right
        ttlSecondsField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let ttlRow = NSStackView(views: [ttlCheckbox, ttlSecondsField, NSTextField(labelWithString: String(localized: "seconds"))])
        ttlRow.orientation = .horizontal
        ttlRow.spacing = 6

        let flagsRow = NSStackView(views: [uniqueCheckbox, sparseCheckbox])
        flagsRow.orientation = .horizontal
        flagsRow.spacing = 16

        // Key table
        let nameColumn = NSTableColumn(identifier: .init("name"))
        nameColumn.title = String(localized: "Field")
        nameColumn.width = 220
        let sortColumn = NSTableColumn(identifier: .init("sorting"))
        sortColumn.title = String(localized: "Order")
        sortColumn.width = 130
        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(sortColumn)
        tableView.rowSizeStyle = .default
        tableView.dataSource = self
        tableView.delegate = self
        let tableScroll = NSScrollView()
        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .bezelBorder
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        tableScroll.heightAnchor.constraint(equalToConstant: 140).isActive = true

        addKeyButton = NSButton(
            image: NSImage(named: NSImage.addTemplateName)!, target: self,
            action: #selector(addKeyAction(_:)))
        removeKeyButton = NSButton(
            image: NSImage(named: NSImage.removeTemplateName)!, target: self,
            action: #selector(removeKeyAction(_:)))
        let keyButtons = NSStackView(views: [addKeyButton, removeKeyButton])
        keyButtons.orientation = .horizontal
        keyButtons.spacing = 6

        let cancelButton = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancelAction(_:)))
        cancelButton.keyEquivalent = "\u{1b}"
        saveButton = NSButton(title: String(localized: "Save"), target: self, action: #selector(saveAction(_:)))
        saveButton.keyEquivalent = "\r"
        let buttonRow = NSStackView(views: [NSView(), cancelButton, saveButton])
        buttonRow.orientation = .horizontal

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: String(localized: "Name:")), nameField],
            [NSView(), flagsRow],
            [NSView(), ttlRow],
            [NSTextField(labelWithString: String(localized: "Keys:")), tableScroll],
            [NSView(), keyButtons],
            [NSView(), buttonRow],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 60
        grid.column(at: 1).xPlacement = .fill
        grid.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        window.contentView = content
        window.setContentSize(content.fittingSize)

        addKeyAction(nil)
        updateControls(nil)
    }

    // MARK: - Keys table

    func numberOfRows(in tableView: NSTableView) -> Int {
        keys.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier else { return nil }
        if identifier.rawValue == "name" {
            let field = NSTextField(string: keys[row].name)
            field.placeholderString = String(localized: "field name")
            field.isBordered = false
            field.backgroundColor = .clear
            field.delegate = self
            field.tag = row
            return field
        }
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: ["Ascending", "Descending", "Hashed"])
        popup.selectItem(at: keys[row].sorting)
        popup.tag = row
        popup.target = self
        popup.action = #selector(sortingChanged(_:))
        // A hashed index must be single-key (legacy rule).
        popup.menu?.items.last?.isEnabled = keys.count == 1
        popup.autoenablesItems = false
        return popup
    }

    @objc private func sortingChanged(_ sender: NSPopUpButton) {
        guard keys.indices.contains(sender.tag) else { return }
        keys[sender.tag].sorting = sender.indexOfSelectedItem
        updateControls(nil)
    }

    @objc private func addKeyAction(_ sender: Any?) {
        keys.append(KeyRow())
        tableView.reloadData()
        updateControls(nil)
        tableView.editColumn(0, row: keys.count - 1, with: nil, select: true)
    }

    @objc private func removeKeyAction(_ sender: Any?) {
        let row = tableView.selectedRow
        guard keys.indices.contains(row) else { return }
        keys.remove(at: row)
        tableView.reloadData()
        updateControls(nil)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateControls(nil)
    }

    @objc private func updateControls(_ sender: Any?) {
        ttlSecondsField.isEnabled = ttlCheckbox.state == .on
        removeKeyButton.isEnabled = tableView.selectedRow >= 0
        // Hashed must be single-key.
        addKeyButton.isEnabled = !(keys.count == 1 && keys[0].sorting == 2)
        saveButton.isEnabled = !keys.isEmpty
    }

    // MARK: - Save / cancel

    @objc private func saveAction(_ sender: Any?) {
        window?.makeFirstResponder(nil)  // commit in-progress cell edits
        var keySpec = Document()
        for key in keys {
            let name = key.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            switch key.sorting {
            case 1: keySpec[name] = Int32(-1)
            case 2: keySpec[name] = "hashed"
            default: keySpec[name] = Int32(1)
            }
        }
        guard !keySpec.isEmpty else {
            NSSound.beep()
            return
        }
        var spec = Document()
        spec["key"] = keySpec
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        spec["name"] = name.isEmpty
            ? keySpec.pairs.map { "\($0.key)_\(BSONDisplay.valueString($0.value))" }.joined(separator: "_")
            : name
        if uniqueCheckbox.state == .on { spec["unique"] = true }
        if sparseCheckbox.state == .on { spec["sparse"] = true }
        if ttlCheckbox.state == .on, let seconds = Int32(ttlSecondsField.stringValue) {
            spec["expireAfterSeconds"] = seconds
        }
        indexSpecification = spec
        window.map { $0.sheetParent?.endSheet($0, returnCode: .OK) }
    }

    @objc private func cancelAction(_ sender: Any?) {
        window.map { $0.sheetParent?.endSheet($0, returnCode: .cancel) }
    }
}

extension IndexEditorController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, keys.indices.contains(field.tag) else { return }
        keys[field.tag].name = field.stringValue
        updateControls(nil)
    }
}

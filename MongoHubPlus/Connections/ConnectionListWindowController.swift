import AppKit

/// The connection manager window (legacy MongoHub's main window),
/// modernized (owner decision 2026-09-01): card grid following the system
/// appearance, toolbar with search + add, empty-state call to action.
/// Interactions kept from legacy: double-click/Return connects, context
/// menu, menu-bar actions via the responder chain.
@MainActor
final class ConnectionListWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private let store = ConnectionStore.shared
    private var collectionView: ConnectionCollectionView!
    private var scrollView: NSScrollView!
    private var emptyStateView: NSStackView!
    private var emptyTitleLabel: NSTextField!
    private var emptyCaptionLabel: NSTextField!
    private var emptyAddButton: NSButton!
    private var searchQuery = ""

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = String(localized: "MongoHub Plus")
        window.setFrameAutosaveName("ConnectionList")  // restores the size…
        window.minSize = NSSize(width: 480, height: 280)
        window.toolbarStyle = .unified
        window.center()  // …but startup position is always centered (owner request)
        self.init(window: window)
        window.delegate = self
        buildContent()
        buildToolbar()
        reload()
        NotificationCenter.default.addObserver(
            self, selector: #selector(storeChanged), name: .connectionStoreDidChange, object: nil)
    }

    // MARK: - Layout

    private func buildContent() {
        guard let window else { return }
        let content = NSView()

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 230, height: 64)
        layout.minimumInteritemSpacing = 10
        layout.minimumLineSpacing = 10
        layout.sectionInset = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        collectionView = ConnectionCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.menuDelegate = self
        collectionView.register(
            ConnectionItem.self,
            forItemWithIdentifier: ConnectionItem.identifier)

        scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Empty state (no connections yet, or no search matches).
        let emptyIcon = NSImageView(
            image: NSImage(
                systemSymbolName: "cylinder.split.1x2",
                accessibilityDescription: nil)!
                .withSymbolConfiguration(.init(pointSize: 40, weight: .light))!)
        emptyIcon.contentTintColor = .tertiaryLabelColor
        emptyTitleLabel = NSTextField(labelWithString: "")
        emptyTitleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        emptyTitleLabel.textColor = .secondaryLabelColor
        emptyTitleLabel.alignment = .center
        emptyCaptionLabel = NSTextField(labelWithString: "")
        emptyCaptionLabel.font = .systemFont(ofSize: 12)
        emptyCaptionLabel.textColor = .tertiaryLabelColor
        emptyCaptionLabel.alignment = .center
        emptyAddButton = NSButton(
            title: String(localized: "Add Connection"), target: self,
            action: #selector(addConnectionAction(_:)))
        emptyAddButton.bezelStyle = .rounded
        emptyAddButton.keyEquivalent = "\r"

        emptyStateView = NSStackView(views: [
            emptyIcon, emptyTitleLabel, emptyCaptionLabel, emptyAddButton,
        ])
        emptyStateView.orientation = .vertical
        emptyStateView.alignment = .centerX
        emptyStateView.spacing = 8
        emptyStateView.setCustomSpacing(14, after: emptyIcon)
        emptyStateView.setCustomSpacing(16, after: emptyCaptionLabel)
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(scrollView)
        content.addSubview(emptyStateView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            emptyStateView.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: content.centerYAnchor, constant: -12),
        ])

        window.contentView = content
    }

    private func buildToolbar() {
        guard let window else { return }
        let toolbar = NSToolbar(identifier: "ConnectionListToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
    }

    // MARK: - Data (filtered by the toolbar search field)

    private var visibleConnections: [MongoConnection] {
        guard !searchQuery.isEmpty else { return store.connections }
        return store.connections.filter {
            $0.alias.localizedCaseInsensitiveContains(searchQuery)
                || $0.displaySubtitle.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    private func reload() {
        collectionView.reloadData()
        let hasConnections = !store.connections.isEmpty
        let hasResults = !visibleConnections.isEmpty
        emptyStateView.isHidden = hasResults
        if !hasConnections {
            emptyTitleLabel.stringValue = String(localized: "No Connections")
            emptyCaptionLabel.stringValue = String(localized: "Add a connection to get started.")
            emptyCaptionLabel.isHidden = false
            emptyAddButton.isHidden = false
        } else if !hasResults {
            emptyTitleLabel.stringValue = String(localized: "No Results")
            emptyCaptionLabel.isHidden = true
            emptyAddButton.isHidden = true
        }
    }

    @objc private func storeChanged() {
        reload()
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        searchQuery = sender.stringValue.trimmingCharacters(in: .whitespaces)
        reload()
    }

    private var selectedConnection: MongoConnection? {
        guard let indexPath = collectionView.selectionIndexPaths.first,
            indexPath.item < visibleConnections.count
        else { return nil }
        return visibleConnections[indexPath.item]
    }

    // MARK: - Actions (also reached from the menu bar via the responder chain)

    @objc func addConnectionAction(_ sender: Any?) {
        presentEditor(ConnectionEditorController(mode: .new(prefill: nil, password: nil)))
    }

    @objc func addConnectionWithURLAction(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "New Connection With URL")
        alert.informativeText = String(localized: "Paste a mongodb:// or mongodb+srv:// connection string.")
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = String(localized: "mongodb+srv://user:pass@cluster.example.mongodb.net/db")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.createConnection(from: field.stringValue)
        }
    }

    /// URL-scheme entry point (mongodb:// links from a browser/terminal).
    func openConnectionEditor(withURL url: String) {
        createConnection(from: url)
    }

    /// Pasted/typed URLs open the editor in "Connection String" mode with the
    /// string preserved verbatim (Compass-style; password → Keychain on save).
    private func createConnection(from url: String) {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedURL.hasPrefix("mongodb://") || trimmedURL.hasPrefix("mongodb+srv://") else {
            presentError(
                title: String(localized: "Invalid Connection String"),
                message: "Connection strings must start with mongodb:// or mongodb+srv://.")
            return
        }
        let (stripped, password) = MongoConnection.extractPassword(from: trimmedURL)
        var prefill = MongoConnection()
        prefill.kind = .connectionString
        prefill.rawConnectionString = stripped
        prefill.alias = MongoConnection.aliasSuggestion(for: trimmedURL)
        presentEditor(ConnectionEditorController(mode: .new(prefill: prefill, password: password)))
    }

    @objc func editConnectionAction(_ sender: Any?) {
        guard let connection = selectedConnection else { return }
        presentEditor(ConnectionEditorController(mode: .edit(connection)))
    }

    @objc func duplicateConnectionAction(_ sender: Any?) {
        guard var copy = selectedConnection else { return }
        let original = copy
        copy.id = UUID()
        copy.alias = store.duplicateAlias(for: copy.alias)
        let password = Keychain.password(for: original.id, kind: .mongo)
        presentEditor(ConnectionEditorController(mode: .new(prefill: copy, password: password)))
    }

    @objc func deleteConnectionAction(_ sender: Any?) {
        guard let connection = selectedConnection, let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete \"\(connection.alias)\"?"
        alert.informativeText = String(localized: "Deleted connections cannot be restored.")
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.buttons[1].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            self?.store.delete(id: connection.id)
        }
    }

    @objc func openConnectionAction(_ sender: Any?) {
        guard let connection = selectedConnection else { return }
        (NSApp.delegate as? AppDelegate)?.openConnection(connection)
    }

    @objc func openInNewWindowAction(_ sender: Any?) {
        guard let connection = selectedConnection else { return }
        (NSApp.delegate as? AppDelegate)?.openConnection(connection, forceNewWindow: true)
    }

    @objc func togglePinAction(_ sender: Any?) {
        guard let connection = selectedConnection else { return }
        store.setPinned(!connection.isPinned, id: connection.id)
    }

    @objc func copy(_ sender: Any?) {
        guard let connection = selectedConnection else { return }
        let url = connection.connectionString(password: nil)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        guard let string = NSPasteboard.general.string(forType: .string),
            string.hasPrefix("mongodb")
        else {
            NSSound.beep()
            return
        }
        createConnection(from: string.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func presentEditor(_ editor: ConnectionEditorController) {
        guard let window, let sheet = editor.window else { return }
        activeEditor = editor
        window.beginSheet(sheet) { [weak self] _ in
            self?.activeEditor = nil
        }
    }

    private var activeEditor: ConnectionEditorController?

    /// UI-verification hook: opens the editor for the first saved connection.
    func debugEditFirstConnection() {
        guard let first = store.connections.first else { return }
        presentEditor(ConnectionEditorController(mode: .edit(first)))
    }

    private func presentError(title: String, message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }

    // MARK: - Menu validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(editConnectionAction(_:)),
            #selector(duplicateConnectionAction(_:)),
            #selector(deleteConnectionAction(_:)),
            #selector(openConnectionAction(_:)),
            #selector(openInNewWindowAction(_:)),
            #selector(copy(_:)):
            return selectedConnection != nil
        case #selector(paste(_:)):
            return NSPasteboard.general.string(forType: .string)?.hasPrefix("mongodb") == true
        default:
            return true
        }
    }
}

// MARK: - Toolbar

extension ConnectionListWindowController: NSToolbarDelegate {
    private static let addItemID = NSToolbarItem.Identifier("addConnection")
    private static let searchItemID = NSToolbarItem.Identifier("searchConnections")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.searchItemID, Self.addItemID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case Self.addItemID:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = String(localized: "Add Connection")
            item.toolTip = String(localized: "Add Connection")
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")
            item.target = self
            item.action = #selector(addConnectionAction(_:))
            item.isBordered = true
            return item
        case Self.searchItemID:
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            item.searchField.target = self
            item.searchField.action = #selector(searchChanged(_:))
            item.searchField.sendsSearchStringImmediately = true
            item.preferredWidthForSearchField = 180
            return item
        default:
            return nil
        }
    }
}

// MARK: - Collection view plumbing

extension ConnectionListWindowController: NSCollectionViewDataSource, NSCollectionViewDelegate,
    NSCollectionViewDelegateFlowLayout
{
    /// Centres the grid instead of letting the cards drift apart.
    ///
    /// AppKit's flow layout spreads a row's leftover width *between* its items
    /// (iOS left-aligns instead), so at two columns the cards ended up pinned
    /// to opposite edges with a canyon down the middle. Widening the side
    /// insets to swallow the leftover leaves the row with no slack to spread,
    /// which centres the block and keeps the cards their natural distance
    /// apart at every window width.
    func collectionView(
        _ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
        insetForSectionAt section: Int
    ) -> NSEdgeInsets {
        guard let flow = collectionViewLayout as? NSCollectionViewFlowLayout else {
            return NSEdgeInsets()
        }
        let base = flow.sectionInset
        let itemWidth = flow.itemSize.width
        let spacing = flow.minimumInteritemSpacing
        let width = collectionView.bounds.width
        let available = width - base.left - base.right
        guard available >= itemWidth else { return base }
        let columns = max(1, ((available + spacing) / (itemWidth + spacing)).rounded(.down))
        let used = columns * itemWidth + (columns - 1) * spacing
        let side = max(base.left, (width - used) / 2)
        return NSEdgeInsets(top: base.top, left: side, bottom: base.bottom, right: side)
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        visibleConnections.count
    }

    func collectionView(
        _ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(
            withIdentifier: ConnectionItem.identifier, for: indexPath)
        if let item = item as? ConnectionItem, indexPath.item < visibleConnections.count {
            item.configure(with: visibleConnections[indexPath.item])
            item.onDoubleClick = { [weak self] in
                self?.openConnectionAction(nil)
            }
        }
        return item
    }
}

extension ConnectionListWindowController: ConnectionCollectionViewMenuDelegate {
    func connectionCollectionView(
        _ view: ConnectionCollectionView, menuForItemAt indexPath: IndexPath?
    ) -> NSMenu? {
        guard window?.attachedSheet == nil else { return nil }
        let menu = NSMenu()
        if let indexPath {
            view.deselectAll(nil)
            view.selectItems(at: [indexPath], scrollPosition: [])
            menu.addItem(withTitle: String(localized: "Open Connection"), action: #selector(openConnectionAction(_:)), keyEquivalent: "")
            menu.addItem(withTitle: String(localized: "Open in New Window"), action: #selector(openInNewWindowAction(_:)), keyEquivalent: "")
            menu.addItem(withTitle: String(localized: "Edit Connection…"), action: #selector(editConnectionAction(_:)), keyEquivalent: "")
            menu.addItem(withTitle: String(localized: "Duplicate Connection…"), action: #selector(duplicateConnectionAction(_:)), keyEquivalent: "")
            let pinned = indexPath.item < visibleConnections.count
                && visibleConnections[indexPath.item].isPinned
            menu.addItem(
                withTitle: pinned
                    ? String(localized: "Unpin Connection")
                    : String(localized: "Pin Connection"),
                action: #selector(togglePinAction(_:)), keyEquivalent: "")
            menu.addItem(withTitle: String(localized: "Copy URL"), action: #selector(copy(_:)), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: String(localized: "Delete Connection…"), action: #selector(deleteConnectionAction(_:)), keyEquivalent: "")
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: String(localized: "New Connection…"), action: #selector(addConnectionAction(_:)), keyEquivalent: "")
        for item in menu.items {
            item.target = self
        }
        return menu
    }
}

/// Collection view that routes right-clicks to a context-menu delegate and
/// connects the selection on Return.
@MainActor
protocol ConnectionCollectionViewMenuDelegate: AnyObject {
    func connectionCollectionView(
        _ view: ConnectionCollectionView, menuForItemAt indexPath: IndexPath?) -> NSMenu?
}

final class ConnectionCollectionView: NSCollectionView {
    weak var menuDelegate: ConnectionCollectionViewMenuDelegate?

    private var widthAtLastLayout: CGFloat = -1

    /// Re-runs the layout when the view gets wider or narrower, so the
    /// delegate's centring insets are recomputed for the new width. The
    /// layout's own `shouldInvalidateLayout(forBoundsChange:)` is not called
    /// for a resize, so without this the grid keeps the insets it was first
    /// laid out with and the row spreads to fill whatever width it now has.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard newSize.width != widthAtLastLayout else { return }
        widthAtLastLayout = newSize.width
        collectionViewLayout?.invalidateLayout()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let indexPath = indexPathForItem(at: point)
        return menuDelegate?.connectionCollectionView(self, menuForItemAt: indexPath)
    }

    override func keyDown(with event: NSEvent) {
        // Return/Enter connects the selected card.
        if event.keyCode == 36 || event.keyCode == 76, !selectionIndexPaths.isEmpty {
            NSApp.sendAction(
                #selector(ConnectionListWindowController.openConnectionAction(_:)), to: nil,
                from: self)
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Connection card

final class ConnectionItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ConnectionItem")

    var onDoubleClick: (() -> Void)?

    private let iconCircle = NSView()
    private let iconView = NSImageView()
    private let sshBadge = NSImageView()
    private let pinBadge = NSImageView()
    private let aliasLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    override func loadView() {
        view = CardView(item: self)

        iconCircle.wantsLayer = true
        iconCircle.layer?.cornerRadius = 18
        iconCircle.translatesAutoresizingMaskIntoConstraints = false

        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        sshBadge.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "SSH")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        sshBadge.contentTintColor = .secondaryLabelColor
        sshBadge.translatesAutoresizingMaskIntoConstraints = false

        pinBadge.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Pinned")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        pinBadge.contentTintColor = .systemYellow
        pinBadge.translatesAutoresizingMaskIntoConstraints = false

        aliasLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        aliasLabel.textColor = .labelColor
        aliasLabel.lineBreakMode = .byTruncatingTail
        aliasLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(iconCircle)
        iconCircle.addSubview(iconView)
        view.addSubview(sshBadge)
        view.addSubview(pinBadge)
        view.addSubview(aliasLabel)
        view.addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            iconCircle.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            iconCircle.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            iconCircle.widthAnchor.constraint(equalToConstant: 36),
            iconCircle.heightAnchor.constraint(equalToConstant: 36),

            iconView.centerXAnchor.constraint(equalTo: iconCircle.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconCircle.centerYAnchor),

            sshBadge.trailingAnchor.constraint(equalTo: iconCircle.trailingAnchor, constant: 3),
            sshBadge.bottomAnchor.constraint(equalTo: iconCircle.bottomAnchor, constant: 3),

            pinBadge.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            pinBadge.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),

            aliasLabel.leadingAnchor.constraint(equalTo: iconCircle.trailingAnchor, constant: 10),
            aliasLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            aliasLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),

            subtitleLabel.leadingAnchor.constraint(equalTo: aliasLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: aliasLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: aliasLabel.bottomAnchor, constant: 2),
        ])
    }

    func configure(with connection: MongoConnection) {
        let (symbol, color) = Self.style(for: connection.kind)
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        iconView.contentTintColor = color
        iconCircle.layer?.backgroundColor = color.withAlphaComponent(0.16).cgColor
        sshBadge.isHidden = !(connection.useSSH && connection.supportsSSHTunnel)
        pinBadge.isHidden = !connection.isPinned
        aliasLabel.stringValue = connection.alias
        subtitleLabel.stringValue = connection.displaySubtitle
    }

    private static func style(for kind: MongoConnection.Kind) -> (String, NSColor) {
        switch kind {
        case .standalone: return ("cylinder.split.1x2.fill", .systemTeal)
        case .replicaSet: return ("square.stack.3d.up.fill", .systemGreen)
        case .shardedCluster: return ("square.grid.3x2.fill", .systemOrange)
        case .srv: return ("cloud.fill", .systemBlue)
        case .connectionString: return ("link", .systemPurple)
        }
    }

    override var isSelected: Bool {
        didSet { view.needsDisplay = true }
    }

    /// Rounded card: quiet fill, hover highlight, accent ring when selected.
    private final class CardView: NSView {
        private unowned let item: ConnectionItem
        private var isHovered = false
        private var trackingArea: NSTrackingArea?

        init(item: ConnectionItem) {
            self.item = item
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(
                rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            isHovered = true
            needsDisplay = true
        }

        override func mouseExited(with event: NSEvent) {
            isHovered = false
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            let card = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
            (isHovered ? NSColor.tertiarySystemFill : NSColor.quaternarySystemFill).setFill()
            card.fill()
            if item.isSelected {
                NSColor.controlAccentColor.setStroke()
                card.lineWidth = 2
                card.stroke()
            }
        }

        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
            if event.clickCount == 2 {
                item.onDoubleClick?()
            }
        }
    }
}

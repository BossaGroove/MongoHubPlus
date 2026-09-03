import AppKit
import BSON
import MongoService
import SSHTunnel

/// One window per open connection (legacy MHConnectionWindowController):
/// toolbar, database/collection sidebar, and the tab host.
@MainActor
final class ConnectionWindowController: NSWindowController, NSWindowDelegate {
    private(set) var connection: MongoConnection
    private(set) var session: ConnectionSession?
    private var tunnel: SSHTunnel?

    var onClose: (() -> Void)?

    // Sidebar model
    final class DatabaseNode {
        let name: String
        var collections: [CollectionNode]?
        /// Created locally, not on the server yet (legacy "extra database":
        /// MongoDB only materializes a database once it has a collection).
        var isTemporary = false
        init(name: String) { self.name = name }
    }
    final class CollectionNode {
        let database: String
        let name: String
        init(database: String, name: String) {
            self.database = database
            self.name = name
        }
        var absoluteName: String { "\(database).\(name)" }
    }
    private var databases: [DatabaseNode] = []

    private let sidebarOutline = NSOutlineView()
    let tabHost = TabHostViewController()
    private var statusTab: StatusTabController?
    private var activityTab: ActivityMonitorTabController?
    private var queryTabs: [String: QueryTabController] = [:]

    init(connection: MongoConnection) {
        self.connection = connection
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "\(connection.alias), Connecting…"
        window.minSize = NSSize(width: 640, height: 400)
        super.init(window: window)
        window.delegate = self
        // Toolbar first: it changes the content-area geometry, and the frame
        // autosave must restore into the final geometry (a stale
        // contentLayoutRect at first display shifted the whole content down
        // until the next resize).
        buildToolbar()
        buildContent()
        window.setFrameAutosaveName("ConnectionWindow")
        tabHost.onTabRemoved = { [weak self] tab in
            self?.tabClosed(tab)
        }
        connectToServer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    private func buildContent() {
        guard let window else { return }

        // Sidebar
        let column = NSTableColumn(identifier: .init("name"))
        sidebarOutline.addTableColumn(column)
        sidebarOutline.outlineTableColumn = column
        sidebarOutline.headerView = nil
        sidebarOutline.selectionHighlightStyle = .sourceList
        sidebarOutline.rowSizeStyle = .small
        sidebarOutline.allowsMultipleSelection = false
        sidebarOutline.dataSource = self
        sidebarOutline.delegate = self
        sidebarOutline.target = self
        sidebarOutline.doubleAction = #selector(sidebarDoubleAction(_:))

        let sidebarScroll = NSScrollView()
        sidebarScroll.documentView = sidebarOutline
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.drawsBackground = false

        // Sidebar context menu (legacy MHDatabaseCollectionOutlineView).
        let contextMenu = NSMenu()
        contextMenu.delegate = self
        sidebarOutline.menu = contextMenu

        let sidebarContainer = NSVisualEffectView()
        sidebarContainer.material = .sidebar
        sidebarContainer.blendingMode = .behindWindow
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false
        sidebarContainer.addSubview(sidebarScroll)

        // Bottom bar: "+" pull-down (Add Database…/Add Collection…), "−" drop
        // (Xcode-style: hairline on top, symbol buttons, no pull-down arrow).
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)

        let addPopup = NSPopUpButton(frame: .zero, pullsDown: true)
        addPopup.isBordered = false
        (addPopup.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        let addMenu = NSMenu()
        let iconItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        iconItem.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")?
            .withSymbolConfiguration(symbolConfig)
        addMenu.addItem(iconItem)
        addMenu.addItem(withTitle: String(localized: "Add Database…"), action: #selector(createDatabaseAction(_:)), keyEquivalent: "")
        addMenu.addItem(withTitle: String(localized: "Add Collection…"), action: #selector(createCollectionAction(_:)), keyEquivalent: "")
        for item in addMenu.items { item.target = self }
        addPopup.menu = addMenu
        addPopup.toolTip = String(localized: "Add a database or collection")
        addPopup.translatesAutoresizingMaskIntoConstraints = false

        let removeButton = NSButton(
            image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Drop")!
                .withSymbolConfiguration(symbolConfig)!,
            target: self, action: #selector(dropSelectedAction(_:)))
        removeButton.bezelStyle = .smallSquare
        removeButton.isBordered = false
        removeButton.toolTip = String(localized: "Drop the selected database or collection")
        removeButton.translatesAutoresizingMaskIntoConstraints = false

        let barSeparator = NSBox()
        barSeparator.boxType = .separator
        barSeparator.translatesAutoresizingMaskIntoConstraints = false

        let bottomBar = NSStackView(views: [addPopup, removeButton])
        bottomBar.orientation = .horizontal
        bottomBar.spacing = 6
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        sidebarContainer.addSubview(bottomBar)
        sidebarContainer.addSubview(barSeparator)

        NSLayoutConstraint.activate([
            sidebarScroll.topAnchor.constraint(equalTo: sidebarContainer.topAnchor),
            sidebarScroll.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor),
            sidebarScroll.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            sidebarScroll.bottomAnchor.constraint(equalTo: barSeparator.topAnchor),

            barSeparator.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor),
            barSeparator.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            barSeparator.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            addPopup.widthAnchor.constraint(equalToConstant: 28),
            removeButton.widthAnchor.constraint(equalToConstant: 28),
            bottomBar.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor, constant: 8),
            bottomBar.bottomAnchor.constraint(equalTo: sidebarContainer.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 26),
        ])

        // Split view
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.autosaveName = "ConnectionSplitView"
        split.addArrangedSubview(sidebarContainer)
        split.addArrangedSubview(tabHost.view)
        sidebarContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        tabHost.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 400).isActive = true
        split.setHoldingPriority(.defaultLow + 10, forSubviewAt: 0)

        // Pin with constraints — autoresizing can miss content-geometry
        // changes that happen while the window is offscreen.
        let container = NSView()
        split.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: container.topAnchor),
            split.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container
        container.layoutSubtreeIfNeeded()
        split.setPosition(210, ofDividerAt: 0)
        self.splitView = split
    }

    private var splitView: NSSplitView?

    /// UI-verification hook: dumps first-layout frames to the app container.
    func debugDumpLayout() {
        guard let window, let content = window.contentView, let split = splitView else { return }
        var out = "window.frame=\(window.frame)\n"
        out += "contentView.frame=\(content.frame) safeArea=\(content.safeAreaInsets)\n"
        out += "contentLayoutRect=\(window.contentLayoutRect)\n"
        out += "split.frame=\(split.frame)\n"
        for (i, pane) in split.arrangedSubviews.enumerated() {
            out += "pane[\(i)].frame=\(pane.frame)\n"
        }
        out += "tabHost.view.frame=\(tabHost.view.frame)\n"
        for sub in tabHost.view.subviews {
            out += "  tabHost.sub \(type(of: sub)) frame=\(sub.frame)\n"
        }
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? Data(out.utf8).write(
            to: support.appendingPathComponent("MongoHub Plus/layout-dump.txt"))
    }

    // MARK: - Toolbar

    private enum ToolbarID {
        static let serverStatus = NSToolbarItem.Identifier("serverStatus")
        static let databaseStats = NSToolbarItem.Identifier("databaseStats")
        static let collectionStats = NSToolbarItem.Identifier("collectionStats")
        static let query = NSToolbarItem.Identifier("query")
        static let importFile = NSToolbarItem.Identifier("importFile")
        static let exportFile = NSToolbarItem.Identifier("exportFile")
        static let activityMonitor = NSToolbarItem.Identifier("activityMonitor")
    }

    /// File → New Window (⇧⌘N): another window for this connection.
    @objc func newConnectionWindowAction(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.openConnection(connection, forceNewWindow: true)
    }

    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "ConnectionWindowToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window?.toolbar = toolbar
        window?.toolbarStyle = .expanded
    }

    // MARK: - Connect flow (legacy-architecture.md §6.1)

    private func connectToServer() {
        let alias = connection.alias
        Task {
            do {
                var hostRewrite: [String: Int]?
                if self.connection.useSSH, self.connection.supportsSSHTunnel {
                    self.window?.title = "\(alias), Connecting (SSH tunnel)…"
                    hostRewrite = try await self.establishTunnel()
                }
                let uri = Preferences.applyingTimeouts(
                    to: self.connection.connectionString(
                        password: Keychain.password(for: self.connection.id, kind: .mongo),
                        hostRewrite: hostRewrite))
                LogStore.shared.add(
                    level: "debug", domain: "\(alias).url",
                    message: Preferences.applyingTimeouts(
                        to: self.connection.connectionString(
                            password: "x", redacted: true, hostRewrite: hostRewrite)))
                let session = try ConnectionSession(connectionString: uri) { level, message in
                    LogStore.log(level: level, domain: "\(alias).driver", message: message)
                }
                try await session.connect()
                LogStore.shared.add(level: "info", domain: "\(alias)", message: "Connected")
                self.session = session
                self.window?.title = self.connection.alias
                self.showServerStatusTab()
                await self.reloadDatabaseList()

                if UserDefaults.standard.bool(forKey: "MAShowMonitor") {
                    self.showActivityMonitorAction(nil)
                }
                // UI-verification hook: --args -MAOpenQuery db.collection
                if let target = UserDefaults.standard.string(forKey: "MAOpenQuery"),
                    let dot = target.firstIndex(of: ".")
                {
                    let node = CollectionNode(
                        database: String(target[..<dot]),
                        name: String(target[target.index(after: dot)...]))
                    self.openQueryTab(for: node)
                    // UI-verification hooks: preset criteria/fields first.
                    // (base64 variants — defaults parse brace-values as plists)
                    func hookString(_ key: String) -> String? {
                        if let plain = UserDefaults.standard.string(forKey: key) { return plain }
                        guard let encoded = UserDefaults.standard.string(forKey: key + "64"),
                            let data = Data(base64Encoded: encoded)
                        else { return nil }
                        return String(data: data, encoding: .utf8)
                    }
                    (self.queryTabs[node.absoluteName])?.debugSetQuery(
                        criteria: hookString("MAQueryCriteria"),
                        fields: hookString("MAQueryFields"),
                        sort: hookString("MAQuerySort"))
                    if let segment = UserDefaults.standard.string(forKey: "MAQuerySegment") {
                        (self.queryTabs[node.absoluteName])?.selectSegment(named: segment)
                    } else {
                        (self.queryTabs[node.absoluteName])?.runQuery(nil)
                    }
                    // UI-verification hook: show the export save panel.
                    if UserDefaults.standard.bool(forKey: "MAShowExportPanel"),
                        let session = self.session, let window = self.window
                    {
                        ImportExport.exportCollection(
                            database: node.database, collection: node.name,
                            session: session, window: window)
                    }
                    // UI-verification hook: show collection stats for the node.
                    if UserDefaults.standard.bool(forKey: "MAShowCollStats") {
                        let tab = self.ensureStatusTab()
                        tab.showCollectionStats(database: node.database, collection: node.name)
                        self.tabHost.select(tab: tab)
                    }
                    // UI-verification hook: select a tab by title substring.
                    if let fragment = UserDefaults.standard.string(forKey: "MASelectTab"),
                        let tab = self.tabHost.tabs.first(where: {
                            ($0.title ?? "").localizedCaseInsensitiveContains(fragment)
                        })
                    {
                        self.tabHost.select(tab: tab)
                    }
                    // UI-verification hook: export the current results.
                    if let path = UserDefaults.standard.string(forKey: "MAExportResults") {
                        (self.queryTabs[node.absoluteName])?.debugExportResults(
                            to: URL(fileURLWithPath: path))
                    }
                    // UI-verification hooks: CSV round trip without panels.
                    if let path = UserDefaults.standard.string(forKey: "MAExportCSV"),
                        let session = self.session, let window = self.window
                    {
                        ImportExport.debugExportCSV(
                            to: URL(fileURLWithPath: path), database: node.database,
                            collection: node.name, session: session, window: window)
                    }
                    if let path = UserDefaults.standard.string(forKey: "MAExportBSON"),
                        let session = self.session, let window = self.window
                    {
                        ImportExport.debugExportBSON(
                            to: URL(fileURLWithPath: path), database: node.database,
                            collection: node.name, session: session, window: window)
                    }
                    if let path = UserDefaults.standard.string(forKey: "MAImportCSV"),
                        let session = self.session, let window = self.window
                    {
                        ImportExport.debugImportCSV(
                            from: URL(fileURLWithPath: path), database: node.database,
                            collection: node.name, session: session, window: window)
                    }
                }
            } catch {
                self.window?.title = "\(self.connection.alias) — connection failed"
                LogStore.shared.add(
                    level: "error", domain: "\(alias)", message: String(describing: error))
                self.presentError(
                    title: "Could Not Connect to \(self.connection.alias)",
                    message: String(describing: error))
            }
        }
    }

    /// Starts the SSH tunnel: builds auth from the Keychain / key file,
    /// prompts for unknown or changed host keys, persists TOFU approval,
    /// and returns the `"host:port" → local port` mapping.
    private func establishTunnel() async throws -> [String: Int] {
        let alias = connection.alias
        let authentication: SSHTunnelAuthentication
        let sshSecret = Keychain.password(for: connection.id, kind: .ssh) ?? ""
        if connection.sshKeyFileName.isEmpty {
            authentication = .password(sshSecret)
        } else {
            authentication = .privateKey(
                openSSHKey: try readKeyFile(),
                passphrase: sshSecret.isEmpty ? nil : sshSecret)
        }

        let tunnel = SSHTunnel(
            configuration: .init(
                host: connection.sshHost,
                port: connection.sshPort,
                username: connection.sshUser.isEmpty ? NSUserName() : connection.sshUser,
                authentication: authentication),
            knownHostKey: connection.sshKnownHostKey,
            onHostKeyPrompt: { [weak self] fingerprint, changed in
                await self?.confirmHostKey(fingerprint: fingerprint, changed: changed) ?? false
            })
        self.tunnel = tunnel

        let targets = connection.forwardTargets.map {
            SSHForwardTarget(host: $0.host, port: $0.port)
        }
        let mapping = try await tunnel.start(
            forwarding: targets.isEmpty ? [SSHForwardTarget(host: "127.0.0.1", port: 27017)] : targets)
        for (target, port) in mapping {
            LogStore.shared.add(
                level: "info", domain: "\(alias).ssh",
                message: "Forwarding 127.0.0.1:\(port) → \(target)")
        }

        // Persist the newly approved host key for TOFU.
        if let approved = await tunnel.approvedHostKey, approved != connection.sshKnownHostKey {
            connection.sshKnownHostKey = approved
            ConnectionStore.shared.upsert(connection)
        }
        return mapping
    }

    /// Reads the OpenSSH private key file (via the sandbox bookmark when
    /// available, else the raw path).
    private func readKeyFile() throws -> String {
        let path = (connection.sshKeyFileName as NSString).expandingTildeInPath
        if let bookmark = connection.sshKeyBookmark {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark, options: .withSecurityScope,
                relativeTo: nil, bookmarkDataIsStale: &stale)
            {
                let accessing = url.startAccessingSecurityScopedResource()
                defer {
                    if accessing { url.stopAccessingSecurityScopedResource() }
                }
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    return text
                }
            }
        }
        do {
            return try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            struct KeyFileError: Error, CustomStringConvertible {
                let path: String
                var description: String {
                    "Could not read the SSH key file at \(path) — re-select it in the connection editor"
                }
            }
            throw KeyFileError(path: path)
        }
    }

    private func confirmHostKey(fingerprint: String, changed: Bool) async -> Bool {
        // UI-verification hook: trust unknown (not changed) keys silently.
        if UserDefaults.standard.bool(forKey: "MATrustHostKeys"), !changed {
            LogStore.shared.add(
                level: "info", domain: "\(connection.alias).ssh",
                message: "Host key auto-trusted by MATrustHostKeys: \(fingerprint)")
            return true
        }
        guard let window else { return false }
        return await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.alertStyle = changed ? .critical : .warning
            alert.messageText =
                changed
                ? "SSH host key has CHANGED for \(connection.sshHost)"
                : "Verify SSH host key for \(connection.sshHost)"
            alert.informativeText =
                (changed
                    ? "The key does not match the one this connection trusted before. "
                        + "This can indicate a man-in-the-middle attack — continue only "
                        + "if you know the server was reinstalled.\n\n"
                    : "This is the first connection to this SSH host. Verify the "
                        + "fingerprint out-of-band if possible.\n\n")
                + "Fingerprint: \(fingerprint)"
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.addButton(withTitle: changed ? "Trust New Key" : "Trust")
            if changed {
                alert.buttons[1].hasDestructiveAction = true
            }
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertSecondButtonReturn)
            }
        }
    }

    private func reloadDatabaseList() async {
        guard let session else { return }
        do {
            let names = try await session.listDatabaseNames()
            let existing = Dictionary(uniqueKeysWithValues: databases.map { ($0.name, $0) })
            var nodes = names.map { name -> DatabaseNode in
                let node = existing[name] ?? DatabaseNode(name: name)
                node.isTemporary = false
                return node
            }
            let temporary = databases.filter { $0.isTemporary && !names.contains($0.name) }
            nodes.append(contentsOf: temporary)
            databases = nodes.sorted { $0.name < $1.name }
            sidebarOutline.reloadData()
        } catch {
            presentError(title: String(localized: "Could Not List Databases"), message: String(describing: error))
        }
    }

    private func loadCollections(for database: DatabaseNode, expandWhenLoaded: Bool = false) {
        guard let session else { return }
        Task {
            do {
                let names = try await session.listCollectionNames(database: database.name)
                database.collections = names.map {
                    CollectionNode(database: database.name, name: $0)
                }
                self.sidebarOutline.reloadItem(database, reloadChildren: true)
                if expandWhenLoaded {
                    self.sidebarOutline.expandItem(database)
                }
            } catch {
                self.presentError(
                    title: "Could Not List Collections in \(database.name)",
                    message: String(describing: error))
            }
        }
    }

    // MARK: - Tabs

    private func showServerStatusTab() {
        let tab = ensureStatusTab()
        tab.showServerStatus()
        tabHost.select(tab: tab)
    }

    private func ensureStatusTab() -> StatusTabController {
        if let statusTab { return statusTab }
        let tab = StatusTabController(session: sessionProvider)
        statusTab = tab
        tabHost.addTab(tab)
        return tab
    }

    private var sessionProvider: () -> ConnectionSession? {
        { [weak self] in self?.session }
    }

    func openQueryTab(for collection: CollectionNode) {
        if let existing = queryTabs[collection.absoluteName] {
            tabHost.select(tab: existing)
            return
        }
        let tab = QueryTabController(
            connectionID: connection.id,
            database: collection.database,
            collection: collection.name,
            session: sessionProvider)
        queryTabs[collection.absoluteName] = tab
        tabHost.addTab(tab)
    }

    // MARK: - Sidebar interaction

    private var selectedDatabaseNode: DatabaseNode? {
        let item = sidebarOutline.item(atRow: sidebarOutline.selectedRow)
        if let database = item as? DatabaseNode { return database }
        if let collection = item as? CollectionNode {
            return databases.first { $0.name == collection.database }
        }
        return nil
    }

    private var selectedCollectionNode: CollectionNode? {
        sidebarOutline.item(atRow: sidebarOutline.selectedRow) as? CollectionNode
    }

    @objc private func sidebarDoubleAction(_ sender: Any?) {
        let row = sidebarOutline.clickedRow >= 0 ? sidebarOutline.clickedRow : sidebarOutline.selectedRow
        let item = sidebarOutline.item(atRow: row)
        if let collection = item as? CollectionNode {
            openQueryTab(for: collection)
        } else if let database = item as? DatabaseNode {
            // Double-clicking a database toggles its collection list (owner
            // request 2026-09-03); the first expand loads the names lazily.
            if sidebarOutline.isItemExpanded(database) {
                sidebarOutline.collapseItem(database)
            } else if database.collections == nil {
                loadCollections(for: database, expandWhenLoaded: true)
            } else {
                sidebarOutline.expandItem(database)
            }
        }
    }

    // MARK: - Toolbar actions

    @objc func showServerStatusAction(_ sender: Any?) {
        showServerStatusTab()
    }

    @objc func showDatabaseStatsAction(_ sender: Any?) {
        guard let database = selectedDatabaseNode else { return }
        let tab = ensureStatusTab()
        tab.showDatabaseStats(database: database.name)
        tabHost.select(tab: tab)
    }

    @objc func showCollectionStatsAction(_ sender: Any?) {
        guard let collection = selectedCollectionNode else { return }
        let tab = ensureStatusTab()
        tab.showCollectionStats(database: collection.database, collection: collection.name)
        tabHost.select(tab: tab)
    }

    @objc func openQueryAction(_ sender: Any?) {
        guard let collection = selectedCollectionNode else { return }
        openQueryTab(for: collection)
    }

    @objc func importFromFileAction(_ sender: Any?) {
        guard let collection = selectedCollectionNode, let session, let window else { return }
        ImportExport.importCollection(
            database: collection.database, collection: collection.name,
            session: session, window: window)
    }

    @objc func exportToFileAction(_ sender: Any?) {
        guard let collection = selectedCollectionNode, let session, let window else { return }
        ImportExport.exportCollection(
            database: collection.database, collection: collection.name,
            session: session, window: window)
    }

    @objc func showActivityMonitorAction(_ sender: Any?) {
        guard session != nil else { return }
        if let activityTab {
            tabHost.select(tab: activityTab)
            return
        }
        let tab = ActivityMonitorTabController(session: sessionProvider)
        activityTab = tab
        tabHost.addTab(tab)
    }

    // MARK: - Window behavior

    /// ⌘W closes the selected tab until one remains, then the window
    /// (legacy windowShouldClose).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard NSApp.currentEvent?.type == .keyDown else { return true }
        guard tabHost.tabs.count > 1, let selected = tabHost.selectedTab else { return true }
        tabHost.removeTab(selected)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        let session = self.session
        let tunnel = self.tunnel
        self.session = nil
        self.tunnel = nil
        Task {
            await session?.disconnect()
            await tunnel?.stop()
        }
        onClose?()
    }

    private func presentError(title: String, message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }
}

// MARK: - Database / collection CRUD (feature-spec 2.3–2.5)

extension ConnectionWindowController: NSMenuDelegate {
    /// Single-field prompt sheet (replaces legacy MHEditNameWindow).
    private func promptForName(
        title: String, placeholder: String, initialValue: String = "",
        completion: @escaping (String) -> Void
    ) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = placeholder
        field.stringValue = initialValue
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            completion(name)
        }
    }

    @objc func createDatabaseAction(_ sender: Any?) {
        promptForName(title: String(localized: "New Database Name:"), placeholder: "Database Name") { [weak self] name in
            guard let self else { return }
            if !self.databases.contains(where: { $0.name == name }) {
                let node = DatabaseNode(name: name)
                node.isTemporary = true
                node.collections = []
                self.databases.append(node)
                self.databases.sort { $0.name < $1.name }
                self.sidebarOutline.reloadData()
            }
        }
    }

    @objc func createCollectionAction(_ sender: Any?) {
        guard let database = selectedDatabaseNode, let session else { return }
        promptForName(title: String(localized: "New Collection Name:"), placeholder: "Collection Name") { [weak self] name in
            guard let self else { return }
            Task {
                do {
                    var command = Document()
                    command["create"] = name
                    _ = try await session.runCommand(command, onDatabase: database.name)
                    database.isTemporary = false
                    self.loadCollections(for: database, expandWhenLoaded: true)
                } catch {
                    self.presentError(
                        title: String(localized: "Could Not Create Collection"), message: String(describing: error))
                }
            }
        }
    }

    @objc func renameCollectionAction(_ sender: Any?) {
        guard let collection = selectedCollectionNode, let session else { return }
        promptForName(
            title: String(localized: "Rename \(collection.absoluteName):"),
            placeholder: String(localized: "Collection Name"),
            initialValue: collection.name
        ) { [weak self] newName in
            guard let self, newName != collection.name else { return }
            Task {
                do {
                    var command = Document()
                    command["renameCollection"] = collection.absoluteName
                    command["to"] = "\(collection.database).\(newName)"
                    _ = try await session.runCommand(command, onDatabase: "admin")
                    // Re-key an open query tab (legacy re-titled it live).
                    if let tab = self.queryTabs.removeValue(forKey: collection.absoluteName) {
                        self.tabHost.removeTab(tab)
                    }
                    if let database = self.databases.first(where: { $0.name == collection.database }) {
                        self.loadCollections(for: database)
                    }
                } catch {
                    self.presentError(
                        title: String(localized: "Could Not Rename Collection"), message: String(describing: error))
                }
            }
        }
    }

    @objc func dropSelectedAction(_ sender: Any?) {
        if selectedCollectionNode != nil {
            dropCollectionAction(sender)
        } else if selectedDatabaseNode != nil {
            dropDatabaseAction(sender)
        }
    }

    @objc func dropCollectionAction(_ sender: Any?) {
        guard let collection = selectedCollectionNode, let session, let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "Drop \"\(collection.absoluteName)\"?")
        alert.informativeText = String(
            localized: "Dropping \"\(collection.absoluteName)\" cannot be undone.")
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Drop"))
        alert.buttons[1].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertSecondButtonReturn else { return }
            Task {
                do {
                    var command = Document()
                    command["drop"] = collection.name
                    _ = try await session.runCommand(command, onDatabase: collection.database)
                    if let tab = self.queryTabs.removeValue(forKey: collection.absoluteName) {
                        self.tabHost.removeTab(tab)
                    }
                    if let database = self.databases.first(where: { $0.name == collection.database }) {
                        self.loadCollections(for: database)
                    }
                } catch {
                    self.presentError(
                        title: String(localized: "Could Not Drop Collection"), message: String(describing: error))
                }
            }
        }
    }

    @objc func dropDatabaseAction(_ sender: Any?) {
        guard let database = selectedDatabaseNode, let window else { return }
        if database.isTemporary {
            databases.removeAll { $0 === database }
            sidebarOutline.reloadData()
            return
        }
        guard let session else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "Drop \"\(database.name)\"?")
        alert.informativeText = String(
            localized: "Dropping \"\(database.name)\" cannot be undone.")
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Drop"))
        alert.buttons[1].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertSecondButtonReturn else { return }
            Task {
                do {
                    _ = try await session.runCommand(["dropDatabase": 1], onDatabase: database.name)
                    for (key, tab) in self.queryTabs where key.hasPrefix("\(database.name).") {
                        self.queryTabs[key] = nil
                        self.tabHost.removeTab(tab)
                    }
                    await self.reloadDatabaseList()
                } catch {
                    self.presentError(
                        title: String(localized: "Could Not Drop Database"), message: String(describing: error))
                }
            }
        }
    }

    /// Right-click context menu (legacy row menus).
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard window?.attachedSheet == nil else { return }
        let row = sidebarOutline.clickedRow
        if row >= 0 {
            sidebarOutline.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            sidebarOutline.deselectAll(nil)
        }
        func add(_ title: String, _ action: Selector) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        if let collection = selectedCollectionNode {
            add(String(localized: "Open \(collection.name)"), #selector(openQueryAction(_:)))
            add(String(localized: "\(collection.name) Stats"), #selector(showCollectionStatsAction(_:)))
            add(String(localized: "Rename \(collection.name)…"), #selector(renameCollectionAction(_:)))
            add(String(localized: "Drop \(collection.name)…"), #selector(dropCollectionAction(_:)))
            menu.addItem(.separator())
            add(String(localized: "New Database…"), #selector(createDatabaseAction(_:)))
            add(String(localized: "New Collection…"), #selector(createCollectionAction(_:)))
        } else if let database = selectedDatabaseNode {
            add(String(localized: "\(database.name) Stats"), #selector(showDatabaseStatsAction(_:)))
            add(String(localized: "Drop \(database.name)…"), #selector(dropDatabaseAction(_:)))
            menu.addItem(.separator())
            add(String(localized: "New Database…"), #selector(createDatabaseAction(_:)))
            add(String(localized: "New Collection…"), #selector(createCollectionAction(_:)))
        } else {
            add(String(localized: "New Database…"), #selector(createDatabaseAction(_:)))
        }
    }
}

// MARK: - Tab bookkeeping

extension ConnectionWindowController {
    private func tabClosed(_ tab: TabItemViewController) {
        if tab === statusTab {
            statusTab = nil
        } else if tab === activityTab {
            activityTab = nil
        } else if let key = queryTabs.first(where: { $0.value === tab })?.key {
            queryTabs[key] = nil
        }
    }
}

// MARK: - Sidebar data source / delegate

extension ConnectionWindowController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return databases.count }
        if let database = item as? DatabaseNode { return database.collections?.count ?? 0 }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let database = item as? DatabaseNode {
            return database.collections![index]
        }
        return databases[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is DatabaseNode
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let database = notification.userInfo?["NSObject"] as? DatabaseNode,
            database.collections == nil
        else { return }
        loadCollections(for: database)
    }

    func outlineView(
        _ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any
    ) -> NSView? {
        let reuseID = NSUserInterfaceItemIdentifier("sidebarCell")
        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: reuseID, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = reuseID
            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            let field = NSTextField(labelWithString: "")
            field.font = .systemFont(ofSize: 12)
            field.lineBreakMode = .byTruncatingMiddle
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(imageView)
            cell.addSubview(field)
            cell.imageView = imageView
            cell.textField = field
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 14),
                imageView.heightAnchor.constraint(equalToConstant: 14),
                field.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        if let database = item as? DatabaseNode {
            cell.imageView?.image = NSImage(
                systemSymbolName: "cylinder.split.1x2", accessibilityDescription: "Database")
            let count = database.collections?.count
            cell.textField?.stringValue =
                count.map { "\(database.name)  (\($0))" } ?? database.name
        } else if let collection = item as? CollectionNode {
            cell.imageView?.image = NSImage(
                systemSymbolName: "tablecells", accessibilityDescription: "Collection")
            cell.textField?.stringValue = collection.name
        }
        return cell
    }

    /// Selection drives the Status tab (legacy behavior): collection →
    /// collection stats; database → db stats; nothing → server status.
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard session != nil else { return }
        if let collection = selectedCollectionNode {
            // If a query tab is open for this collection, prefer it (legacy).
            if let queryTab = queryTabs[collection.absoluteName] {
                tabHost.select(tab: queryTab)
            } else {
                showCollectionStatsAction(nil)
            }
        } else if selectedDatabaseNode != nil {
            showDatabaseStatsAction(nil)
        } else {
            showServerStatusAction(nil)
        }
    }
}

// MARK: - Toolbar delegate

extension ConnectionWindowController: NSToolbarDelegate, NSToolbarItemValidation {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ToolbarID.serverStatus, ToolbarID.databaseStats, ToolbarID.collectionStats,
            ToolbarID.query, ToolbarID.activityMonitor, .flexibleSpace,
            ToolbarID.exportFile, ToolbarID.importFile,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space, .flexibleSpace]
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier {
        case ToolbarID.serverStatus:
            item.label = String(localized: "Server Status")
            item.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)
            item.action = #selector(showServerStatusAction(_:))
        case ToolbarID.databaseStats:
            item.label = String(localized: "Database Stats")
            item.image = NSImage(
                systemSymbolName: "cylinder.split.1x2", accessibilityDescription: nil)
            item.action = #selector(showDatabaseStatsAction(_:))
        case ToolbarID.collectionStats:
            item.label = String(localized: "Collection Stats")
            item.image = NSImage(systemSymbolName: "tablecells", accessibilityDescription: nil)
            item.action = #selector(showCollectionStatsAction(_:))
        case ToolbarID.query:
            item.label = String(localized: "Query")
            item.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
            item.action = #selector(openQueryAction(_:))
        case ToolbarID.importFile:
            item.label = String(localized: "Import (File)")
            item.image = NSImage(
                systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)
            item.action = #selector(importFromFileAction(_:))
        case ToolbarID.exportFile:
            item.label = String(localized: "Export (File)")
            item.image = NSImage(
                systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
            item.action = #selector(exportToFileAction(_:))
        case ToolbarID.activityMonitor:
            item.label = String(localized: "Activity Monitor")
            item.image = NSImage(
                systemSymbolName: "waveform.path.ecg", accessibilityDescription: nil)
            item.action = #selector(showActivityMonitorAction(_:))
        default:
            return nil
        }
        item.target = self
        item.isBordered = true
        return item
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard session != nil else { return false }
        switch item.itemIdentifier {
        case ToolbarID.serverStatus:
            return true
        case ToolbarID.databaseStats:
            return selectedDatabaseNode != nil
        case ToolbarID.collectionStats, ToolbarID.query,
            ToolbarID.importFile, ToolbarID.exportFile:
            return selectedCollectionNode != nil
        default:
            return true
        }
    }
}

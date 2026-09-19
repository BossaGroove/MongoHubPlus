import AppKit
import Sparkle

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    private var connectionListWindowController: ConnectionListWindowController?
    private var connectionWindowControllers: [UUID: [ConnectionWindowController]] = [:]
    private var preferencesWindowController: PreferencesWindowController?
    private var logWindowController: LogWindowController?

    /// Sparkle stays dormant in Debug builds, and in any build whose
    /// SUPublicEDKey is empty (docs/release.md) — the latter has no feed to
    /// check. Exposed so the Settings "Software Update" section can bind to
    /// the updater.
    ///
    /// The Debug half matters because the key is no longer empty anywhere:
    /// once it went into project.yml, a dev build polled the public appcast
    /// like any other, and accepting the update let Sparkle replace the app
    /// in DerivedData with the notarized release — after which rebuilding
    /// over it fails on macOS App Management. A build you are developing
    /// should not be able to overwrite itself with a shipped one.
    private let updateChannelDelegate = UpdateChannelDelegate()
    lazy var updaterController: SPUStandardUpdaterController? = {
        #if DEBUG
            return nil
        #else
            guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
                !key.isEmpty
            else { return nil }
            return SPUStandardUpdaterController(
                startingUpdater: true, updaterDelegate: updateChannelDelegate,
                userDriverDelegate: nil)
        #endif
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Preferences.applyAppearance()
        NSApp.mainMenu = buildMainMenu()
        openConnectionListWindow(nil)
        NSApp.activate()

        // UI-verification hooks (used by automated screenshot checks):
        //   open …/MongoHub Plus.app --args -MAEditFirstConnection YES
        if UserDefaults.standard.bool(forKey: "MAEditFirstConnection") {
            connectionListWindowController?.debugEditFirstConnection()
        }
        if UserDefaults.standard.bool(forKey: "MAConnectFirst"),
            let first = ConnectionStore.shared.connections.first
        {
            openConnection(first)
        }
        if let alias = UserDefaults.standard.string(forKey: "MAConnect"),
            let connection = ConnectionStore.shared.connection(alias: alias)
        {
            openConnection(connection)
        }
        if let alias = UserDefaults.standard.string(forKey: "MAConnectNew"),
            let connection = ConnectionStore.shared.connection(alias: alias)
        {
            openConnection(connection, forceNewWindow: true)
        }
        if UserDefaults.standard.bool(forKey: "MAKeychainProbe") {
            runKeychainProbe()
        }
        if UserDefaults.standard.bool(forKey: "MAShowPreferences") {
            openPreferences(nil)
        }
        if UserDefaults.standard.bool(forKey: "MADumpLayout") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.connectionWindowControllers.values.first?.first?.debugDumpLayout()
            }
        }
    }

    /// UI-verification hook: round-trips a throwaway password through the
    /// Keychain and writes the outcome next to the connection store.
    private func runKeychainProbe() {
        let id = UUID()
        var result: String
        do {
            try Keychain.setPassword("probe-secret", for: id, kind: .mongo)
            let read = Keychain.password(for: id, kind: .mongo)
            result = read == "probe-secret" ? "OK" : "MISMATCH: \(read ?? "nil")"
        } catch {
            result = "ERROR: \(error)"
        }
        Keychain.deleteAll(for: id)
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? Data(result.utf8).write(
            to: support.appendingPathComponent("MongoHub Plus/keychain-probe.txt"))
    }

    // Legacy behavior: the app stays alive with no windows…
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // …and re-shows the connection list when reactivated with none visible.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            openConnectionListWindow(nil)
        }
        return true
    }

    // MARK: - Windows

    @objc func openConnectionListWindow(_ sender: Any?) {
        if connectionListWindowController == nil {
            connectionListWindowController = ConnectionListWindowController()
        }
        connectionListWindowController?.showWindow(nil)
        connectionListWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    /// Re-opening focuses the existing window; `forceNewWindow` opens
    /// another one for the same connection (M4d, feature-spec 1.11).
    func openConnection(_ connection: MongoConnection, forceNewWindow: Bool = false) {
        if !forceNewWindow, let existing = connectionWindowControllers[connection.id]?.first {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = ConnectionWindowController(connection: connection)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.connectionWindowControllers[connection.id]?.removeAll { $0 === controller }
        }
        let siblings = connectionWindowControllers[connection.id] ?? []
        connectionWindowControllers[connection.id] = siblings + [controller]
        controller.showWindow(nil)
        // Cascade extra windows so they don't stack exactly.
        if let reference = siblings.last?.window, let window = controller.window {
            let origin = NSPoint(
                x: reference.frame.minX + 28,
                y: reference.frame.maxY - window.frame.height - 28)
            window.setFrameOrigin(origin)
        }
    }

    // MARK: - Dock menu (legacy: one entry per connection)

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let connectionsMenu = NSMenu()
        for connection in ConnectionStore.shared.connections {
            let item = NSMenuItem(
                title: connection.alias, action: #selector(dockOpenConnection(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = connection.id
            connectionsMenu.addItem(item)
        }
        let menu = NSMenu()
        let connections = NSMenuItem(title: String(localized: "Connections"), action: nil, keyEquivalent: "")
        connections.submenu = connectionsMenu
        menu.addItem(connections)
        return menu
    }

    @objc private func dockOpenConnection(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
            let connection = ConnectionStore.shared.connection(id: id)
        else { return }
        openConnection(connection)
    }

    // MARK: - Main menu

    private func buildMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            item.submenu = menu
            mainMenu.addItem(item)
            return menu
        }

        // Application menu
        let appMenu = submenu("MongoHub Plus")
        appMenu.addItem(
            withTitle: String(localized: "About MongoHub Plus"),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        if let updaterController {
            let check = appMenu.addItem(
                withTitle: String(localized: "Check for Updates…"),
                action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                keyEquivalent: "")
            check.target = updaterController
        }
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: String(localized: "Settings…"), action: #selector(openPreferences(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Hide MongoHub Plus"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(
            withTitle: String(localized: "Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: String(localized: "Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Quit MongoHub Plus"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File
        let fileMenu = submenu("File")
        let newWindow = fileMenu.addItem(
            withTitle: String(localized: "New Window"),
            action: #selector(ConnectionWindowController.newConnectionWindowAction(_:)),
            keyEquivalent: "n")
        newWindow.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        // Edit (standard responder-chain actions)
        let editMenu = submenu("Edit")
        editMenu.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(findMenuItem())

        // Connection (legacy menu, legacy-architecture.md §4)
        let connectionMenu = submenu("Connection")
        connectionMenu.addItem(
            withTitle: String(localized: "Add Connection"),
            action: #selector(ConnectionListWindowController.addConnectionAction(_:)),
            keyEquivalent: "n")
        let withURL = connectionMenu.addItem(
            withTitle: String(localized: "Add Connection With URL…"),
            action: #selector(ConnectionListWindowController.addConnectionWithURLAction(_:)),
            keyEquivalent: "n")
        withURL.keyEquivalentModifierMask = [.command, .option]
        connectionMenu.addItem(
            withTitle: String(localized: "Edit Connection"),
            action: #selector(ConnectionListWindowController.editConnectionAction(_:)),
            keyEquivalent: "e")
        connectionMenu.addItem(
            withTitle: String(localized: "Duplicate Connection"),
            action: #selector(ConnectionListWindowController.duplicateConnectionAction(_:)),
            keyEquivalent: "d")
        connectionMenu.addItem(
            withTitle: String(localized: "Delete Connection"),
            action: #selector(ConnectionListWindowController.deleteConnectionAction(_:)),
            keyEquivalent: "")
        connectionMenu.addItem(.separator())
        connectionMenu.addItem(
            withTitle: String(localized: "Connect"),
            action: #selector(ConnectionListWindowController.openConnectionAction(_:)),
            keyEquivalent: "")

        // Window
        let windowMenu = submenu("Window")
        windowMenu.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: String(localized: "Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            withTitle: String(localized: "Connection List"),
            action: #selector(openConnectionListWindow(_:)), keyEquivalent: "l")
        let logsItem = windowMenu.addItem(
            withTitle: String(localized: "Logs"), action: #selector(openLogWindow(_:)), keyEquivalent: "l")
        logsItem.keyEquivalentModifierMask = [.command, .option]
        NSApp.windowsMenu = windowMenu

        // Help
        let helpMenu = submenu("Help")
        helpMenu.addItem(
            withTitle: String(localized: "MongoHub Plus on GitHub"),
            action: #selector(openRepository(_:)), keyEquivalent: "")

        return mainMenu
    }

    /// Edit ▸ Find — the standard text-finder items, targetless so they run
    /// down the responder chain to whichever text view is focused: the JSON
    /// editor window and the query JSON boxes opt in. Same five items and
    /// tags the legacy menu carried (legacy MHMainMenu.xib).
    ///
    /// "Use Selection for Find" keeps its place but not legacy's ⌘E (owner
    /// decision 2026-09-19): legacy bound the same key to Connection ▸ Edit
    /// Connection, so ⌘E meant one thing or the other depending on what had
    /// focus, and the find half is a silent action — it loads the selection
    /// into the search string and shows nothing until the next ⌘G. ⌘E now
    /// belongs to Edit Connection alone; the item still works from the menu.
    private func findMenuItem() -> NSMenuItem {
        // Keyed rather than titled "Find" so it does not share a translation
        // with the Find *query tab*, which several languages render as "query".
        let item = NSMenuItem(
            title: String(localized: "menu.edit.find", defaultValue: "Find"), action: nil,
            keyEquivalent: "")
        let menu = NSMenu(title: item.title)

        func add(_ title: String, _ action: NSFindPanelAction, keyEquivalent: String) {
            let entry = menu.addItem(
                withTitle: title, action: #selector(NSTextView.performFindPanelAction(_:)),
                keyEquivalent: keyEquivalent)
            entry.tag = Int(action.rawValue)
        }

        add(String(localized: "Find…"), .showFindPanel, keyEquivalent: "f")
        add(String(localized: "Find Next"), .next, keyEquivalent: "g")
        add(String(localized: "Find Previous"), .previous, keyEquivalent: "G")
        add(String(localized: "Use Selection for Find"), .setFindString, keyEquivalent: "")
        menu.addItem(
            withTitle: String(localized: "Jump to Selection"),
            action: #selector(NSResponder.centerSelectionInVisibleArea(_:)), keyEquivalent: "j")

        item.submenu = menu
        return item
    }

    @objc func openPreferences(_ sender: Any?) {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController()
        }
        preferencesWindowController?.showWindow(nil)
        preferencesWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func openLogWindow(_ sender: Any?) {
        if logWindowController == nil {
            logWindowController = LogWindowController()
        }
        logWindowController?.showWindow(nil)
        logWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    /// mongodb:// / mongodb+srv:// URL scheme (legacy kAEGetURL handler):
    /// opens the connection editor prefilled with the URL.
    func application(_ application: NSApplication, open urls: [URL]) {
        openConnectionListWindow(nil)
        for url in urls {
            connectionListWindowController?.openConnectionEditor(withURL: url.absoluteString)
        }
    }

    @objc private func openRepository(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/BossaGroove/MongoHubPlus")!)
    }
}

/// Restricts the appcast channels Sparkle considers (feature-spec 6.2).
/// Not MainActor: Sparkle may consult its delegate off the main thread, so
/// this reads the raw default rather than going through `Preferences`.
final class UpdateChannelDelegate: NSObject, SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UserDefaults.standard.bool(forKey: Preferences.includeBetaUpdatesKey) ? ["beta"] : []
    }
}

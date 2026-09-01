import AppKit
import MongoService

/// The Add/Edit Connection sheet — field-for-field the legacy editor
/// (legacy-architecture.md §5) plus the "Atlas / DNS Seed List" type that
/// legacy never had (feature-spec 1.5).
@MainActor
final class ConnectionEditorController: NSWindowController, NSTextFieldDelegate {
    enum Mode {
        case new(prefill: MongoConnection?, password: String?)
        case edit(MongoConnection)
    }

    private let mode: Mode
    private let store = ConnectionStore.shared

    // Fields
    private let aliasField = NSTextField(string: "")
    private let typePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let typeTabs = NSTabView()

    private let hostField = NSTextField(string: "")
    private let hostPortField = NSTextField(string: "")
    private let secondaryOKCheckbox = NSButton(checkboxWithTitle: String(localized: "Secondary OK"), target: nil, action: nil)

    private let replicaNameField = NSTextField(string: "")
    private let replicaServersField = NSTextField(string: "")
    private let readModePopup = NSPopUpButton(frame: .zero, pullsDown: false)

    private let shardedServersField = NSTextField(string: "")

    private let srvHostField = NSTextField(string: "")
    private let connectionStringField = NSTextField(string: "")

    private let userField = NSTextField(string: "")
    private let passwordField = NSSecureTextField(string: "")
    private let databaseField = NSTextField(string: "")

    private let tlsCheckbox = NSButton(checkboxWithTitle: String(localized: "TLS/SSL"), target: nil, action: nil)
    private let weakCertCheckbox = NSButton(checkboxWithTitle: String(localized: "Weak Certificate"), target: nil, action: nil)

    private let sshCheckbox = NSButton(checkboxWithTitle: String(localized: "Use SSH Tunnel"), target: nil, action: nil)
    private let sshHostField = NSTextField(string: "")
    private let sshPortField = NSTextField(string: "")
    private let sshUserField = NSTextField(string: "")
    private let sshPasswordField = NSSecureTextField(string: "")
    private let sshKeyField = NSTextField(string: "")
    private let sshKeyButton = NSButton(title: String(localized: "Select…"), target: nil, action: nil)

    private let saveButton = NSButton(title: String(localized: "Add"), target: nil, action: nil)
    private var typeTabsHeight: NSLayoutConstraint!
    private var typeGrids: [String: NSGridView] = [:]

    init(mode: Mode) {
        self.mode = mode
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = String(localized: "Add New Connection")
        super.init(window: window)
        buildContent()
        populate()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    private func buildContent() {
        guard let window else { return }

        func label(_ text: String) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.alignment = .right
            return l
        }

        aliasField.placeholderString = String(localized: "Label")
        hostField.placeholderString = String(localized: "127.0.0.1")
        hostPortField.placeholderString = String(localized: "27017")
        replicaNameField.placeholderString = String(localized: "Replica Set Name")
        replicaServersField.placeholderString = String(localized: "host1:port1,host2:port2…")
        shardedServersField.placeholderString = String(localized: "host1:port1,host2:port2…")
        srvHostField.placeholderString = String(localized: "cluster0.example.mongodb.net")
        connectionStringField.placeholderString =
            "mongodb+srv://user:password@cluster0.example.mongodb.net/db?retryWrites=true"
        connectionStringField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        connectionStringField.lineBreakMode = .byCharWrapping
        connectionStringField.cell?.wraps = true
        connectionStringField.setContentHuggingPriority(.init(1), for: .horizontal)
        userField.placeholderString = String(localized: "Username (optional)")
        passwordField.placeholderString = String(localized: "Password (optional)")
        databaseField.placeholderString = String(localized: "Database Name (optional)")
        sshHostField.placeholderString = String(localized: "SSH Host")
        sshPortField.placeholderString = String(localized: "22")
        sshUserField.placeholderString = NSUserName()
        sshKeyField.placeholderString = String(localized: "~/.ssh/id_ed25519")

        userField.delegate = self
        typePopup.addItems(withTitles: MongoConnection.Kind.allCases.map(\.displayName))
        typePopup.target = self
        typePopup.action = #selector(typeChanged(_:))

        readModePopup.addItems(withTitles: MongoConnection.ReadMode.allCases.map(\.displayName))

        tlsCheckbox.target = self
        tlsCheckbox.action = #selector(tlsChanged(_:))

        // Server-type tabs (borderless, driven by the popup — like legacy)
        typeTabs.tabViewType = .noTabsNoBorder
        typeTabs.translatesAutoresizingMaskIntoConstraints = false

        func gridTab(_ identifier: String, _ rows: [[NSView]]) {
            let grid = NSGridView(views: rows)
            grid.rowSpacing = 8
            grid.columnSpacing = 8
            grid.column(at: 0).xPlacement = .trailing
            grid.column(at: 0).width = 80
            if grid.numberOfColumns > 1 {
                grid.column(at: 1).xPlacement = .fill
            }
            grid.translatesAutoresizingMaskIntoConstraints = false
            typeGrids[identifier] = grid
            let item = NSTabViewItem(identifier: identifier)
            let container = NSView()
            container.addSubview(grid)
            NSLayoutConstraint.activate([
                grid.topAnchor.constraint(equalTo: container.topAnchor),
                grid.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                grid.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                grid.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
            ])
            item.view = container
            typeTabs.addTabViewItem(item)
        }

        hostPortField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        hostField.setContentHuggingPriority(.init(1), for: .horizontal)
        let hostRow = NSStackView(views: [hostField, label(":"), hostPortField])
        hostRow.orientation = .horizontal
        gridTab("standalone", [
            [label(String(localized: "Address:")), hostRow],
            [NSView(), secondaryOKCheckbox],
        ])
        gridTab("replicaSet", [
            [label(String(localized: "Set Name:")), replicaNameField],
            [label(String(localized: "Servers:")), replicaServersField],
            [label(String(localized: "Read Mode:")), readModePopup],
        ])
        gridTab("shardedCluster", [
            [label(String(localized: "Servers:")), shardedServersField],
        ])
        let srvNote = NSTextField(wrappingLabelWithString: "TLS is always on for mongodb+srv:// connections.")
        srvNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        srvNote.textColor = .secondaryLabelColor
        gridTab("srv", [
            [label(String(localized: "Host:")), srvHostField],
            [NSView(), srvNote],
        ])
        let rawNote = NSTextField(
            wrappingLabelWithString:
                "Paste the whole connection string, exactly as Atlas or Compass gives it. "
                + "On save, the password is moved into the macOS Keychain.")
        rawNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        rawNote.textColor = .secondaryLabelColor
        connectionStringField.heightAnchor.constraint(equalToConstant: 48).isActive = true
        gridTab("connectionString", [
            [label(String(localized: "URI:")), connectionStringField],
            [NSView(), rawNote],
        ])

        // SSH section (feature-spec 2.8).
        sshCheckbox.target = self
        sshCheckbox.action = #selector(sshToggled(_:))
        sshKeyButton.target = self
        sshKeyButton.action = #selector(selectKeyFileAction(_:))
        sshPasswordField.toolTip =
            "SSH password — used as the key passphrase when a key file is set"
        sshPortField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        sshHostField.setContentHuggingPriority(.init(1), for: .horizontal)
        sshKeyField.setContentHuggingPriority(.init(1), for: .horizontal)
        let sshHostRow = NSStackView(views: [sshHostField, label(":"), sshPortField])
        sshHostRow.orientation = .horizontal
        let sshKeyRow = NSStackView(views: [sshKeyField, sshKeyButton])
        sshKeyRow.orientation = .horizontal

        let tlsRow = NSStackView(views: [tlsCheckbox, weakCertCheckbox])
        tlsRow.orientation = .horizontal
        tlsRow.spacing = 16

        func formGrid(_ rows: [[NSView]]) -> NSGridView {
            let grid = NSGridView(views: rows)
            grid.rowSpacing = 8
            grid.columnSpacing = 8
            grid.column(at: 0).xPlacement = .trailing
            grid.column(at: 0).width = 80
            grid.column(at: 1).xPlacement = .fill
            grid.translatesAutoresizingMaskIntoConstraints = false
            return grid
        }
        let topGrid = formGrid([
            [label(String(localized: "Name:")), aliasField],
            [label(String(localized: "Type:")), typePopup],
        ])
        let bottomGrid = formGrid([
            [label(String(localized: "User:")), userField],
            [label(String(localized: "Password:")), passwordField],
            [label(String(localized: "Database:")), databaseField],
            [NSView(), tlsRow],
            [NSView(), sshCheckbox],
            [label(String(localized: "SSH Host:")), sshHostRow],
            [label(String(localized: "User:")), sshUserField],
            [label(String(localized: "Password:")), sshPasswordField],
            [label(String(localized: "Key file:")), sshKeyRow],
        ])
        let mainGrid = NSStackView(views: [topGrid, typeTabs, bottomGrid])
        mainGrid.orientation = .vertical
        mainGrid.alignment = .leading
        mainGrid.spacing = 8
        mainGrid.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            topGrid.leadingAnchor.constraint(equalTo: mainGrid.leadingAnchor),
            topGrid.trailingAnchor.constraint(equalTo: mainGrid.trailingAnchor),
            typeTabs.leadingAnchor.constraint(equalTo: mainGrid.leadingAnchor),
            typeTabs.trailingAnchor.constraint(equalTo: mainGrid.trailingAnchor),
            bottomGrid.leadingAnchor.constraint(equalTo: mainGrid.leadingAnchor),
            bottomGrid.trailingAnchor.constraint(equalTo: mainGrid.trailingAnchor),
        ])
        typeTabsHeight = typeTabs.heightAnchor.constraint(equalToConstant: 96)
        typeTabsHeight.isActive = true

        let cancelButton = NSButton(
            title: String(localized: "Cancel"), target: self, action: #selector(cancelAction(_:)))
        cancelButton.keyEquivalent = "\u{1b}"
        saveButton.target = self
        saveButton.action = #selector(saveAction(_:))
        saveButton.keyEquivalent = "\r"
        let buttonRow = NSStackView(views: [NSView(), cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.widthAnchor.constraint(equalToConstant: 560).isActive = true
        content.addSubview(mainGrid)
        content.addSubview(buttonRow)
        NSLayoutConstraint.activate([
            mainGrid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            mainGrid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            mainGrid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            buttonRow.topAnchor.constraint(equalTo: mainGrid.bottomAnchor, constant: 20),
            buttonRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            buttonRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttonRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        window.contentView = content
        window.setContentSize(content.fittingSize)
    }

    // MARK: - Populate

    private func populate() {
        let connection: MongoConnection
        var password: String?
        switch mode {
        case .new(let prefill, let prefillPassword):
            connection = prefill ?? MongoConnection()
            password = prefillPassword
            saveButton.title = String(localized: "Add")
        case .edit(let existing):
            connection = existing
            password = Keychain.password(for: existing.id, kind: .mongo)
            saveButton.title = String(localized: "Save")
            window?.title = String(localized: "Edit Connection")
        }

        aliasField.stringValue = connection.alias
        typePopup.selectItem(at: MongoConnection.Kind.allCases.firstIndex(of: connection.kind) ?? 0)
        switch connection.kind {
        case .standalone:
            let parts = (connection.serverList.first ?? "").split(separator: ":")
            hostField.stringValue = parts.first.map(String.init) ?? ""
            hostPortField.stringValue = parts.count > 1 ? String(parts[1]) : ""
            secondaryOKCheckbox.state =
                connection.defaultReadMode == .secondaryPreferred ? .on : .off
        case .replicaSet:
            replicaNameField.stringValue = connection.replicaSetName
            replicaServersField.stringValue = connection.servers
            readModePopup.selectItem(
                at: MongoConnection.ReadMode.allCases.firstIndex(of: connection.defaultReadMode) ?? 0)
        case .shardedCluster:
            shardedServersField.stringValue = connection.servers
        case .srv:
            srvHostField.stringValue = connection.servers
        case .connectionString:
            // Defensive: normalize a password that was hand-edited into the
            // stored string; the display is always the password-free form.
            let (stripped, embedded) = MongoConnection.extractPassword(
                from: connection.rawConnectionString ?? "")
            if let embedded, !embedded.isEmpty { password = embedded }
            connectionStringField.stringValue = stripped
        }
        userField.stringValue = connection.adminUser
        if connection.kind == .connectionString {
            userField.stringValue = MongoConnection.username(
                in: connectionStringField.stringValue) ?? ""
        }
        passwordField.stringValue = password ?? ""
        databaseField.stringValue = connection.defaultDatabase
        tlsCheckbox.state = connection.useTLS ? .on : .off
        weakCertCheckbox.state = connection.weakCertificate ? .on : .off
        sshCheckbox.state = connection.useSSH ? .on : .off
        sshHostField.stringValue = connection.sshHost
        sshPortField.stringValue = connection.sshPort == 22 ? "" : String(connection.sshPort)
        sshUserField.stringValue = connection.sshUser
        sshKeyField.stringValue = connection.sshKeyFileName
        if case .edit(let existing) = mode {
            sshPasswordField.stringValue = Keychain.password(for: existing.id, kind: .ssh) ?? ""
        }
        typeChanged(nil)
        updateSSHControls()
    }

    // MARK: - Field behavior

    @objc private func typeChanged(_ sender: Any?) {
        let kind = MongoConnection.Kind.allCases[typePopup.indexOfSelectedItem]
        typeTabs.selectTabViewItem(withIdentifier: kind.rawValue)
        if let grid = typeGrids[kind.rawValue] {
            typeTabsHeight.constant = grid.fittingSize.height + 2
            if let content = window?.contentView {
                content.layoutSubtreeIfNeeded()
                window?.setContentSize(content.fittingSize)
            }
        }
        // Legacy copied the servers string when switching between multi-host modes.
        switch kind {
        case .replicaSet where replicaServersField.stringValue.isEmpty:
            replicaServersField.stringValue = shardedServersField.stringValue
        case .shardedCluster where shardedServersField.stringValue.isEmpty:
            shardedServersField.stringValue = replicaServersField.stringValue
        default: break
        }
        // Switching away from a raw string: carry what we can into the fields.
        if previousKind == .connectionString, kind != .connectionString,
            let (parsed, password) = try? MongoConnection.parse(
                connectionString: connectionStringField.stringValue.trimmingCharacters(
                    in: .whitespacesAndNewlines))
        {
            hostField.stringValue = parsed.serverList.first?.split(separator: ":").first.map(String.init) ?? ""
            replicaServersField.stringValue = parsed.servers
            shardedServersField.stringValue = parsed.servers
            srvHostField.stringValue = parsed.kind == .srv ? parsed.servers : srvHostField.stringValue
            replicaNameField.stringValue = parsed.replicaSetName
            userField.stringValue = parsed.adminUser
            if let password { passwordField.stringValue = password }
            databaseField.stringValue = parsed.defaultDatabase
            tlsCheckbox.state = parsed.useTLS ? .on : .off
        }
        previousKind = kind

        // A raw string carries its own settings; the masked Password field
        // stays active as the home of the extracted password.
        let usesFields = kind != .connectionString
        userField.isEnabled = usesFields
        databaseField.isEnabled = usesFields
        passwordField.isEnabled = true
        tlsCheckbox.isEnabled = usesFields && kind != .srv
        weakCertCheckbox.isEnabled = usesFields && (kind == .srv || tlsCheckbox.state == .on)
    }

    private var previousKind: MongoConnection.Kind = .standalone

    @objc private func sshToggled(_ sender: Any?) {
        updateSSHControls()
    }

    private func updateSSHControls() {
        let kind = MongoConnection.Kind.allCases[typePopup.indexOfSelectedItem]
        let available = kind != .srv && kind != .connectionString
        sshCheckbox.isEnabled = available
        sshCheckbox.toolTip =
            available ? nil : "SSH tunneling needs explicit hosts (not SRV or raw strings)"
        if !available {
            sshCheckbox.state = .off
        }
        let on = available && sshCheckbox.state == .on
        for control in [sshHostField, sshPortField, sshUserField, sshPasswordField, sshKeyField]
            as [NSControl]
        {
            control.isEnabled = on
        }
        sshKeyButton.isEnabled = on
    }

    private var selectedKeyURL: URL?

    @objc private func selectKeyFileAction(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.selectedKeyURL = url
            self?.sshKeyField.stringValue = url.path
        }
    }

    @objc private func tlsChanged(_ sender: Any?) {
        weakCertCheckbox.isEnabled = tlsCheckbox.state == .on
        if !weakCertCheckbox.isEnabled { weakCertCheckbox.state = .off }
    }

    /// Legacy behavior: leaving the user field prefills the password from the
    /// Keychain (only sensible in edit mode, where the UUID is stable).
    func controlTextDidEndEditing(_ obj: Notification) {
        guard obj.object as? NSTextField === userField,
            case .edit(let connection) = mode,
            passwordField.stringValue.isEmpty,
            let stored = Keychain.password(for: connection.id, kind: .mongo)
        else { return }
        passwordField.stringValue = stored
    }

    /// Strip a pasted scheme prefix from server fields (legacy behavior).
    func controlTextDidChange(_ obj: Notification) {
        for field in [replicaServersField, shardedServersField, srvHostField, hostField] {
            if field.stringValue.hasPrefix("mongodb://") {
                field.stringValue = String(field.stringValue.dropFirst("mongodb://".count))
            } else if field.stringValue.hasPrefix("mongodb+srv://") {
                field.stringValue = String(field.stringValue.dropFirst("mongodb+srv://".count))
            }
        }
    }

    // MARK: - Save / validation (legacy rules, legacy-architecture.md §5)

    @objc private func saveAction(_ sender: Any?) {
        var connection: MongoConnection
        switch mode {
        case .new(let prefill, _): connection = prefill ?? MongoConnection()
        case .edit(let existing): connection = existing
        }

        func trimmed(_ field: NSTextField) -> String {
            field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func fail(_ message: String, focus: NSControl) {
            presentValidationError(message)
            window?.makeFirstResponder(focus)
        }

        let alias = trimmed(aliasField)
        guard !alias.isEmpty else {
            return fail("The connection needs a name.", focus: aliasField)
        }
        guard !store.isAliasInUse(alias, excluding: connection.id) else {
            return fail("Name already in use!", focus: aliasField)
        }

        let kind = MongoConnection.Kind.allCases[typePopup.indexOfSelectedItem]
        connection.kind = kind
        connection.alias = alias
        var rawPassword: String?

        switch kind {
        case .standalone:
            let host = trimmed(hostField)
            let portText = trimmed(hostPortField)
            if !portText.isEmpty {
                guard let port = Int(portText), (1...65535).contains(port) else {
                    return fail("Host port should be between 1 and 65535 (or empty).", focus: hostPortField)
                }
                connection.servers = host.isEmpty ? "127.0.0.1:\(port)" : "\(host):\(port)"
            } else {
                connection.servers = host
            }
            connection.replicaSetName = ""
            connection.defaultReadMode = secondaryOKCheckbox.state == .on ? .secondaryPreferred : .primary
        case .replicaSet:
            let servers = trimmed(replicaServersField)
            guard servers.split(separator: ",").count > 1 else {
                return fail("You need to set more than one server.", focus: replicaServersField)
            }
            let name = trimmed(replicaNameField)
            guard !name.isEmpty else {
                return fail("You need to set a replica set name.", focus: replicaNameField)
            }
            connection.servers = servers
            connection.replicaSetName = name
            connection.defaultReadMode =
                MongoConnection.ReadMode.allCases[readModePopup.indexOfSelectedItem]
        case .shardedCluster:
            let servers = trimmed(shardedServersField)
            guard !servers.isEmpty else {
                return fail("You need to set at least one server.", focus: shardedServersField)
            }
            connection.servers = servers
            connection.replicaSetName = ""
        case .srv:
            let host = trimmed(srvHostField)
            guard !host.isEmpty, !host.contains(","), !host.contains(":") else {
                return fail("mongodb+srv:// takes a single host name, without a port.", focus: srvHostField)
            }
            connection.servers = host
            connection.replicaSetName = ""
        case .connectionString:
            let raw = trimmed(connectionStringField)
            guard raw.hasPrefix("mongodb://") || raw.hasPrefix("mongodb+srv://") else {
                return fail(
                    "The connection string must start with mongodb:// or mongodb+srv://.",
                    focus: connectionStringField)
            }
            let (stripped, extracted) = MongoConnection.extractPassword(from: raw)
            connection.rawConnectionString = stripped
            connection.servers = ""
            connection.replicaSetName = ""
            rawPassword = extracted
        }

        let password: String
        if kind == .connectionString {
            password = rawPassword ?? passwordField.stringValue
        } else {
            connection.adminUser = trimmed(userField)
            password = passwordField.stringValue
            if !password.isEmpty && connection.adminUser.isEmpty {
                return fail("You need to set a user name if you enter a password.", focus: userField)
            }
            connection.defaultDatabase = trimmed(databaseField)
            connection.useTLS = kind == .srv || tlsCheckbox.state == .on
            connection.weakCertificate = weakCertCheckbox.state == .on
        }

        // SSH tunnel settings (legacy validation rules).
        connection.useSSH = connection.supportsSSHTunnel && sshCheckbox.state == .on
        if connection.useSSH {
            let sshHost = trimmed(sshHostField)
            guard !sshHost.isEmpty else {
                return fail("Tunneling requires an SSH host.", focus: sshHostField)
            }
            let sshPortText = trimmed(sshPortField)
            var sshPort = 22
            if !sshPortText.isEmpty {
                guard let port = Int(sshPortText), (1...65535).contains(port) else {
                    return fail("SSH port should be between 1 and 65535 (or empty).", focus: sshPortField)
                }
                sshPort = port
            }
            connection.sshHost = sshHost
            connection.sshPort = sshPort
            connection.sshUser = trimmed(sshUserField).isEmpty ? NSUserName() : trimmed(sshUserField)
            connection.sshKeyFileName = trimmed(sshKeyField)
            if let url = selectedKeyURL {
                connection.sshKeyBookmark = try? url.bookmarkData(
                    options: .withSecurityScope, includingResourceValuesForKeys: nil,
                    relativeTo: nil)
            } else if connection.sshKeyFileName.isEmpty {
                connection.sshKeyBookmark = nil
            }
            do {
                try Keychain.setPassword(
                    sshPasswordField.stringValue, for: connection.id, kind: .ssh)
            } catch {
                return fail("Could not store the SSH password in the Keychain: \(error)",
                    focus: sshPasswordField)
            }
        }

        // Final check: the driver must accept the URI (legacy did the same).
        let uri = connection.connectionString(password: password.isEmpty ? nil : password)
        do {
            _ = try ConnectionSession(connectionString: uri)
        } catch {
            return fail("Invalid connection: \(error)", focus: aliasField)
        }

        do {
            try Keychain.setPassword(password, for: connection.id, kind: .mongo)
        } catch {
            return fail("Could not store the password in the Keychain: \(error)", focus: passwordField)
        }
        store.upsert(connection)
        dismissSheet(returnCode: .OK)
    }

    @objc private func cancelAction(_ sender: Any?) {
        dismissSheet(returnCode: .cancel)
    }

    private func dismissSheet(returnCode: NSApplication.ModalResponse) {
        guard let window else { return }
        window.sheetParent?.endSheet(window, returnCode: returnCode)
    }

    private func presentValidationError(_ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.beginSheetModal(for: window)
    }
}

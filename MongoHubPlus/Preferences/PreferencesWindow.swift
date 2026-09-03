import AppKit
import ExtendedJSON
import Sparkle
import SwiftUI

/// The Settings window (legacy MHPreferenceWindow, modernized): the
/// System Settings idiom — `NavigationSplitView` sidebar of sections on the
/// left, a grouped `Form` on the right. All native SwiftUI components.
@MainActor
final class PreferencesWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = String(localized: "Settings")
        // No separator line under the titlebar — matches System Settings.
        window.titlebarSeparatorStyle = .none
        self.init(window: window)
        window.contentViewController = NSHostingController(rootView: SettingsRootView())
        window.setContentSize(NSSize(width: 760, height: 500))
        window.center()
        window.setFrameAutosaveName("MASettingsWindow")
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, results, syntax, editor, connection
    case softwareUpdate = "update"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return String(localized: "General")
        case .results: return String(localized: "Results")
        case .syntax: return String(localized: "Syntax")
        case .editor: return String(localized: "Editor")
        case .connection: return String(localized: "Connection")
        case .softwareUpdate: return String(localized: "Software Update")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .results: return "tablecells"
        case .syntax: return "textformat"
        case .editor: return "curlybraces"
        case .connection: return "network"
        case .softwareUpdate: return "arrow.triangle.2.circlepath"
        }
    }
}

private struct SettingsRootView: View {
    @State private var selection: SettingsSection = {
        // UI-verification hook: -MAPrefsSection general|results|editor|connection
        if let raw = UserDefaults.standard.string(forKey: "MAPrefsSection"),
            let section = SettingsSection(rawValue: raw)
        {
            return section
        }
        return .general
    }()

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label {
                    Text(section.title)
                } icon: {
                    Image(systemName: section.symbol)
                }
                .tag(section)
            }
            // Fixed sections — the collapse button is just clutter here.
            .toolbar(removing: .sidebarToggle)
            // Fixed width: the min/ideal/max variant is unreliably applied on
            // macOS, and 215 fits the longest section name in every language.
            .navigationSplitViewColumnWidth(215)
        } detail: {
            Group {
                switch selection {
                case .general: GeneralSettings()
                case .results: ResultsSettings()
                case .syntax: SyntaxSettings()
                case .editor: EditorSettings()
                case .connection: ConnectionSettings()
                case .softwareUpdate: UpdateSettings()
                }
            }
            .formStyle(.grouped)
            .navigationTitle(selection.title)
        }
        .frame(minWidth: 680, minHeight: 420)
    }
}

// MARK: - General (language, appearance)

private struct GeneralSettings: View {
    @State private var language = Preferences.language
    @State private var appearance = Preferences.appearance

    var body: some View {
        Form {
            Picker("Language:", selection: $language) {
                Text("Follow System").tag(Preferences.AppLanguage.system)
                Text(verbatim: "English").tag(Preferences.AppLanguage.en)
                Text(verbatim: "日本語").tag(Preferences.AppLanguage.ja)
                Text(verbatim: "Deutsch").tag(Preferences.AppLanguage.de)
                Text(verbatim: "繁體中文").tag(Preferences.AppLanguage.zhHant)
                Text(verbatim: "简体中文").tag(Preferences.AppLanguage.zhHans)
                Text(verbatim: "Français").tag(Preferences.AppLanguage.fr)
            }
            .onChange(of: language) { _, newValue in
                Preferences.language = newValue
                Preferences.promptRelaunch()
            }

            Picker("Appearance:", selection: $appearance) {
                Text("Follow System").tag(Preferences.AppAppearance.system)
                Text("Light").tag(Preferences.AppAppearance.light)
                Text("Dark").tag(Preferences.AppAppearance.dark)
            }
            .onChange(of: appearance) { _, newValue in
                Preferences.appearance = newValue
                Preferences.applyAppearance()
            }
        }
    }
}

// MARK: - Results (sort, key order, font)

private struct ResultsSettings: View {
    @State private var sortAscending = Preferences.defaultSortAscending
    @State private var keyOrder = Preferences.jsonKeyOrder
    @State private var resultsFontName = Preferences.resultsFontName
    @State private var resultsTextSize = Preferences.resultsTextSize

    var body: some View {
        Form {
            Section {
                Picker("Default Sort Order:", selection: $sortAscending) {
                    Text("Ascending {_id: 1}").tag(true)
                    Text("Descending {_id: -1}").tag(false)
                }
                .onChange(of: sortAscending) { _, newValue in
                    Preferences.defaultSortAscending = newValue
                }

                Picker("JSON Key Order:", selection: $keyOrder) {
                    Text("Document Order").tag(EJSONFormat.KeyOrder.document)
                    Text("Ascending").tag(EJSONFormat.KeyOrder.ascending)
                    Text("Descending").tag(EJSONFormat.KeyOrder.descending)
                }
                .onChange(of: keyOrder) { _, newValue in
                    Preferences.jsonKeyOrder = newValue
                }
            }

            Section {
                Picker("Results Font:", selection: $resultsFontName) {
                    Text("System").tag("System")
                    Text("SF Mono").tag("SF Mono")
                    Text("Menlo").tag("Menlo")
                    Text("Monaco").tag("Monaco")
                    Text("Courier New").tag("Courier New")
                }
                .onChange(of: resultsFontName) { _, newValue in
                    Preferences.resultsFontName = newValue
                }

                Picker("Results Text Size:", selection: $resultsTextSize) {
                    Text("Small (11 pt)").tag(11.0)
                    Text("Medium (13 pt)").tag(13.0)
                    Text("Large (15 pt)").tag(15.0)
                }
                .onChange(of: resultsTextSize) { _, newValue in
                    Preferences.resultsTextSize = newValue
                }
            }
        }
    }
}

// MARK: - Syntax (how values are written out, per surface)

/// One row per surface. They are separate settings on purpose: reading a
/// value in a table, editing one in place, copying, and editing a whole
/// document are different jobs. Typing always accepts both dialects, and
/// exported files are always Extended JSON.
private struct SyntaxSettings: View {
    @State private var resultsSyntax = Preferences.resultsSyntax
    @State private var inlineEditSyntax = Preferences.inlineEditSyntax
    @State private var copySyntax = Preferences.copySyntax
    @State private var jsonEditorSyntax = Preferences.jsonEditorSyntax

    var body: some View {
        Form {
            Section {
                Picker("Results:", selection: $resultsSyntax) {
                    Text("Compact").tag(Preferences.ResultsSyntax.compact)
                    Text("Extended JSON").tag(Preferences.ResultsSyntax.extendedJSON)
                }
                .onChange(of: resultsSyntax) { _, newValue in Preferences.resultsSyntax = newValue }

                dialectPicker("Editing a Value:", $inlineEditSyntax) {
                    Preferences.inlineEditSyntax = $0
                }
                dialectPicker("Copy:", $copySyntax) { Preferences.copySyntax = $0 }
                dialectPicker("JSON Editor:", $jsonEditorSyntax) {
                    Preferences.jsonEditorSyntax = $0
                }
            } footer: {
                Text(
                    "Both syntaxes are always accepted when you type, whatever you choose here. Exported files are always Extended JSON."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        // Read the stored values again whenever the section is shown, so the
        // rows cannot drift from a preference changed elsewhere.
        .onAppear {
            resultsSyntax = Preferences.resultsSyntax
            inlineEditSyntax = Preferences.inlineEditSyntax
            copySyntax = Preferences.copySyntax
            jsonEditorSyntax = Preferences.jsonEditorSyntax
        }
    }

    private func dialectPicker(
        _ label: LocalizedStringKey, _ selection: Binding<Preferences.ValueSyntax>,
        onChange: @escaping (Preferences.ValueSyntax) -> Void
    ) -> some View {
        Picker(label, selection: selection) {
            Text("Extended JSON").tag(Preferences.ValueSyntax.extendedJSON)
            Text("Shell (mongosh)").tag(Preferences.ValueSyntax.shell)
        }
        .onChange(of: selection.wrappedValue) { _, newValue in onChange(newValue) }
    }
}

// MARK: - Editor (JSON theme colors + font)

private struct EditorSettings: View {
    @State private var theme = JSONTheme.current
    @State private var fontSize: Double = Double(JSONTheme.current.font.pointSize)
    // The stored font's PostScript name (e.g. "Menlo-Regular" or the system
    // monospaced font's dotted name) never equals a display choice — select
    // by family, treating the system monospaced font as SF Mono.
    @State private var fontName: String = {
        let font = JSONTheme.current.font
        let family = font.familyName ?? font.fontName
        return ["SF Mono", "Menlo", "Monaco", "Courier New"].contains(family) ? family : "SF Mono"
    }()

    private let fontChoices = ["SF Mono", "Menlo", "Monaco", "Courier New"]

    var body: some View {
        Form {
            Section {
                colorRow("Background:", \.background)
                colorRow("Text:", \.text)
                colorRow("Keys:", \.key)
                colorRow("Strings:", \.string)
                colorRow("Numbers & Types:", \.number)
                colorRow("Booleans:", \.boolean)
                colorRow("null / undefined:", \.null)
                colorRow("Punctuation:", \.punctuation)
            }

            Section {
                Picker("Font:", selection: $fontName) {
                    ForEach(fontChoices, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: fontName) { _, _ in commitFont() }

                Stepper(value: $fontSize, in: 9...24, step: 1) {
                    LabeledContent("Size:", value: "\(Int(fontSize)) pt")
                }
                .onChange(of: fontSize) { _, _ in commitFont() }
            }

            Section {
                Button("Reset to Defaults") {
                    JSONTheme.resetToDefault()
                    theme = JSONTheme.current
                    fontSize = Double(theme.font.pointSize)
                    fontName = theme.font.fontName
                }
            }
        }
    }

    private func colorRow(
        _ label: LocalizedStringKey, _ keyPath: WritableKeyPath<JSONTheme, NSColor>
    ) -> some View {
        ColorPicker(
            label,
            selection: Binding(
                get: { Color(nsColor: theme[keyPath: keyPath]) },
                set: { newValue in
                    theme[keyPath: keyPath] = NSColor(newValue)
                    if keyPath == \.text {
                        theme.insertionPoint = NSColor(newValue)
                    }
                    theme.save()
                }
            ))
    }

    private func commitFont() {
        let base = NSFont(name: fontName, size: fontSize)
        theme.font = base ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        theme.save()
    }
}

// MARK: - Connection (timeouts)

private struct ConnectionSettings: View {
    @State private var connectTimeout = Preferences.connectTimeoutMS
    @State private var socketTimeout = Preferences.socketTimeoutMS
    @State private var timeoutWarning = ""

    var body: some View {
        Form {
            Section {
                TextField("Connect Timeout (ms):", value: $connectTimeout, format: .number)
                    .onSubmit { commitTimeouts() }
                TextField("Socket Timeout (ms):", value: $socketTimeout, format: .number)
                    .onSubmit { commitTimeouts() }
            } header: {
                Text("Timeouts (0 = driver default, otherwise ≥ 500 ms)")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if !timeoutWarning.isEmpty {
                        Text(timeoutWarning).foregroundStyle(.red)
                    }
                    Text("Applied to new connections.")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
        .onDisappear { commitTimeouts() }
    }

    private func commitTimeouts() {
        // Legacy rule: below 500ms (and not 0) is rejected.
        if (connectTimeout != 0 && connectTimeout < 500)
            || (socketTimeout != 0 && socketTimeout < 500)
        {
            timeoutWarning = String(localized: "Timeouts should be 0 or at least 500 ms.")
            return
        }
        timeoutWarning = ""
        Preferences.connectTimeoutMS = connectTimeout
        Preferences.socketTimeoutMS = socketTimeout
    }
}

// MARK: - Software Update (Sparkle; feature-spec 4.6/6.2)

private struct UpdateSettings: View {
    private var updater: SPUUpdater? {
        (NSApp.delegate as? AppDelegate)?.updaterController?.updater
    }

    @State private var autoCheck = false
    @State private var autoDownload = false
    @State private var includeBeta = Preferences.includeBetaUpdates
    @State private var lastCheck: Date?
    @State private var changelog: [Changelog.Line] = []

    var body: some View {
        Form {
            if updater != nil {
                Section {
                    Toggle("Automatically check for updates", isOn: $autoCheck)
                        .onChange(of: autoCheck) { _, newValue in
                            updater?.automaticallyChecksForUpdates = newValue
                        }
                    Toggle("Automatically download and install updates", isOn: $autoDownload)
                        .disabled(!autoCheck)
                        .onChange(of: autoDownload) { _, newValue in
                            updater?.automaticallyDownloadsUpdates = newValue
                        }
                }

                Section {
                    Toggle("Include beta versions", isOn: $includeBeta)
                        .onChange(of: includeBeta) { _, newValue in
                            Preferences.includeBetaUpdates = newValue
                        }
                } footer: {
                    Text("Beta versions may be less stable than regular releases.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent("Last checked:", value: lastCheckText)
                    Button("Check for Updates Now") {
                        updater?.checkForUpdates()
                        // The check runs asynchronously; pick the date up when
                        // the user next looks (good enough for a status line).
                        lastCheck = updater?.lastUpdateCheckDate
                    }
                }
            } else {
                Section {
                    Text("Updates are unavailable in this build.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("Version:", value: versionText)
            }

            if !changelog.isEmpty {
                Section {
                    ChangelogView(lines: changelog)
                } header: {
                    Text("What's New in \(shortVersion)")
                }
            }
        }
        .onAppear {
            autoCheck = updater?.automaticallyChecksForUpdates ?? false
            autoDownload = updater?.automaticallyDownloadsUpdates ?? false
            lastCheck = updater?.lastUpdateCheckDate
            changelog = Changelog.entryForCurrentVersion()
        }
    }

    private var lastCheckText: String {
        guard let lastCheck else { return String(localized: "Never") }
        return lastCheck.formatted(date: .abbreviated, time: .shortened)
    }

    private var versionText: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(shortVersion) (\(build))"
    }

    private var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}

/// Renders one version's `CHANGELOG.md` entry — the same text the update
/// notification shows for a version being offered.
private struct ChangelogView: View {
    let lines: [Changelog.Line]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                switch line {
                case .heading(let text):
                    Text(text)
                        .font(.subheadline.weight(.semibold))
                        .padding(.top, 2)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: "•").foregroundStyle(.secondary)
                        Text(inline(text))
                    }
                case .paragraph(let text):
                    Text(inline(text))
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Emphasis, code spans and links inside a line; block structure has
    /// already been parsed out by `Changelog`.
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

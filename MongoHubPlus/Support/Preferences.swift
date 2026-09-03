import AppKit
import BSON
import ExtendedJSON
import Foundation

/// Typed access to the app preferences (legacy MHPreferenceWindow keys,
/// modern storage). All read at point-of-use; the Preferences window posts
/// `.preferencesDidChange` after edits.
enum Preferences {
    private static var defaults: UserDefaults { .standard }

    /// Find tab default sort: `{_id: 1}` (ascending) or `{_id: -1}`.
    static var defaultSortAscending: Bool {
        get { !defaults.bool(forKey: "defaultSortDescending") }
        set {
            defaults.set(!newValue, forKey: "defaultSortDescending")
            post()
        }
    }

    /// Key order in results outlines and the document editor.
    static var jsonKeyOrder: EJSONFormat.KeyOrder {
        get {
            switch defaults.string(forKey: "jsonKeyOrder") {
            case "ascending": return .ascending
            case "descending": return .descending
            default: return .document
            }
        }
        set {
            let value: String
            switch newValue {
            case .ascending: value = "ascending"
            case .descending: value = "descending"
            case .document: value = "document"
            }
            defaults.set(value, forKey: "jsonKeyOrder")
            post()
        }
    }

    /// UI language: follow the system, or force a specific localization.
    /// Implemented via the per-app `AppleLanguages` override — the standard
    /// mechanism, so all bundle localization resolves consistently. Needs a
    /// relaunch to take effect.
    enum AppLanguage: String, CaseIterable {
        case system
        case en
        case ja
        case de
        case zhHant = "zh-Hant"
        case zhHans = "zh-Hans"
        case fr
    }

    static var language: AppLanguage {
        get { AppLanguage(rawValue: defaults.string(forKey: "appLanguage") ?? "") ?? .system }
        set {
            defaults.set(newValue.rawValue, forKey: "appLanguage")
            if newValue == .system {
                defaults.removeObject(forKey: "AppleLanguages")
            } else {
                defaults.set([newValue.rawValue], forKey: "AppleLanguages")
            }
            post()
        }
    }

    /// Offers to relaunch so a language change takes effect.
    @MainActor
    static func promptRelaunch() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Relaunch to change the language?")
        alert.informativeText = String(
            localized: "The new language takes effect the next time MongoHub Plus starts.")
        alert.addButton(withTitle: String(localized: "Relaunch Now"))
        alert.addButton(withTitle: String(localized: "Later"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL, configuration: configuration
        ) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// App appearance: follow the system, or force light/dark.
    enum AppAppearance: String, CaseIterable {
        case system, light, dark
    }

    static var appearance: AppAppearance {
        get { AppAppearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system }
        set {
            defaults.set(newValue.rawValue, forKey: "appearance")
            post()
        }
    }

    /// Applies the stored appearance app-wide (call at launch and on change).
    @MainActor
    static func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// Point size for the results/stats outlines (row height follows).
    static var resultsTextSize: Double {
        get {
            let value = defaults.double(forKey: "resultsTextSize")
            return value > 0 ? value : 11
        }
        set {
            defaults.set(newValue, forKey: "resultsTextSize")
            post()
        }
    }

    /// Font family for the results/stats outlines ("System" = default UI font).
    static var resultsFontName: String {
        get { defaults.string(forKey: "resultsFontName") ?? "System" }
        set {
            defaults.set(newValue, forKey: "resultsFontName")
            post()
        }
    }

    /// Resolves the results font preference (SF Mono maps to the system
    /// monospaced font, which needs no font installation).
    static func resultsFont(size: CGFloat, bold: Bool) -> NSFont {
        switch resultsFontName {
        case "System":
            return bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        case "SF Mono":
            return .monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
        default:
            guard let font = NSFont(name: resultsFontName, size: size) else {
                return .monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
            }
            return bold ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
        }
    }

    /// How BSON values are written out as text. Each surface has its own
    /// setting (docs/json-dialects.md) — reading a value in a table, editing
    /// one in place, copying, and editing a whole document are different jobs
    /// with different right answers. Input always accepts both dialects, and
    /// file export is always Extended JSON regardless.
    enum ValueSyntax: String, CaseIterable, Sendable {
        case extendedJSON
        case shell

        var serializerMode: EJSONFormat.Mode {
            switch self {
            case .extendedJSON: return .editor
            case .shell: return .shell
            }
        }
    }

    /// The results outline additionally offers its compact table rendering —
    /// bare strings, local-time dates — which is not a dialect at all.
    enum ResultsSyntax: String, CaseIterable, Sendable {
        case compact
        case extendedJSON
    }

    private static func valueSyntax(_ key: String, default fallback: ValueSyntax) -> ValueSyntax {
        ValueSyntax(rawValue: defaults.string(forKey: key) ?? "") ?? fallback
    }

    private static func setValueSyntax(_ value: ValueSyntax, _ key: String) {
        defaults.set(value.rawValue, forKey: key)
        post()
    }

    /// Results outline, and everything else drawn in it: Stats, Explain,
    /// the Index pane, Tail.
    static var resultsSyntax: ResultsSyntax {
        get { ResultsSyntax(rawValue: defaults.string(forKey: "resultsSyntax") ?? "") ?? .compact }
        set {
            defaults.set(newValue.rawValue, forKey: "resultsSyntax")
            post()
        }
    }

    /// Editing a single value in place in the results.
    static var inlineEditSyntax: ValueSyntax {
        get { valueSyntax("inlineEditSyntax", default: .shell) }
        set { setValueSyntax(newValue, "inlineEditSyntax") }
    }

    /// ⌘C. Defaults to Extended JSON because copied text leaves the app and
    /// has to paste into Compass, a driver, or a ticket — not just mongosh.
    static var copySyntax: ValueSyntax {
        get { valueSyntax("copySyntax", default: .extendedJSON) }
        set { setValueSyntax(newValue, "copySyntax") }
    }

    /// The JSON editor window.
    static var jsonEditorSyntax: ValueSyntax {
        get { valueSyntax("jsonEditorSyntax", default: .extendedJSON) }
        set { setValueSyntax(newValue, "jsonEditorSyntax") }
    }

    static func format(
        _ syntax: ValueSyntax, pretty: Bool, applyKeyOrder: Bool = false
    ) -> EJSONFormat {
        EJSONFormat(
            mode: syntax.serializerMode, pretty: pretty,
            keyOrder: applyKeyOrder ? jsonKeyOrder : .document)
    }

    /// The results outline's Value column.
    static func resultsValueText(for value: Primitive) -> String {
        switch resultsSyntax {
        case .compact:
            return BSONDisplay.valueString(value)
        case .extendedJSON:
            guard let text = try? ExtendedJSON.stringifyValue(
                value, format: EJSONFormat(mode: .editor, pretty: false))
            else { return BSONDisplay.valueString(value) }
            // A container renders its whole subtree here; one table row does
            // not need all of it.
            let limit = 300
            return text.count > limit ? text.prefix(limit) + "…" : text
        }
    }

    /// Opt into Sparkle's "beta" appcast channel (feature-spec 6.2 — the
    /// legacy beta-channel preference). Read by `UpdateChannelDelegate`,
    /// which uses the raw key because Sparkle may ask off the main thread.
    static let includeBetaUpdatesKey = "includeBetaUpdates"
    static var includeBetaUpdates: Bool {
        get { defaults.bool(forKey: includeBetaUpdatesKey) }
        set { defaults.set(newValue, forKey: includeBetaUpdatesKey) }
    }

    /// Mongo timeouts in milliseconds; 0 = driver default (legacy semantics:
    /// values below 500 are rejected by the Preferences UI).
    static var connectTimeoutMS: Int {
        get { defaults.integer(forKey: "connectTimeoutMS") }
        set {
            defaults.set(newValue, forKey: "connectTimeoutMS")
            post()
        }
    }

    static var socketTimeoutMS: Int {
        get { defaults.integer(forKey: "socketTimeoutMS") }
        set {
            defaults.set(newValue, forKey: "socketTimeoutMS")
            post()
        }
    }

    /// Appends the global timeout preferences to a connection string
    /// (only when set, and only when the string doesn't already carry them).
    static func applyingTimeouts(to uri: String) -> String {
        var options: [String] = []
        let lower = uri.lowercased()
        if connectTimeoutMS > 0, !lower.contains("connecttimeoutms=") {
            options.append("connectTimeoutMS=\(connectTimeoutMS)")
        }
        if socketTimeoutMS > 0, !lower.contains("sockettimeoutms=") {
            options.append("socketTimeoutMS=\(socketTimeoutMS)")
        }
        guard !options.isEmpty else { return uri }
        return uri + (uri.contains("?") ? "&" : "?") + options.joined(separator: "&")
    }

    private static func post() {
        NotificationCenter.default.post(name: .preferencesDidChange, object: nil)
    }
}

extension Notification.Name {
    static let preferencesDidChange = Notification.Name("MongoHubPlus.preferencesDidChange")
}

import AppKit
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

    /// Which dialect the document editor, the results-outline inline editor
    /// and ⌘C copy *render* (docs/json-dialects.md). Input always accepts both
    /// dialects regardless, and file export is always Extended JSON.
    enum DocumentSyntax: String, CaseIterable, Sendable {
        case extendedJSON
        case shell

        var serializerMode: EJSONFormat.Mode {
            switch self {
            case .extendedJSON: return .editor
            case .shell: return .shell
            }
        }
    }

    static var documentSyntax: DocumentSyntax {
        get {
            DocumentSyntax(rawValue: defaults.string(forKey: "documentSyntax") ?? "")
                ?? .extendedJSON
        }
        set {
            defaults.set(newValue.rawValue, forKey: "documentSyntax")
            post()
        }
    }

    /// The output format for every value the user reads or edits in place.
    static func documentFormat(pretty: Bool, applyKeyOrder: Bool = false) -> EJSONFormat {
        EJSONFormat(
            mode: documentSyntax.serializerMode, pretty: pretty,
            keyOrder: applyKeyOrder ? jsonKeyOrder : .document)
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

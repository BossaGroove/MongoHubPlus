import AppKit

/// Syntax colors for the document editor. Defaults reproduce the legacy
/// MongoHub theme (black background, Monaco-style mono font, yellow
/// punctuation, blue keys, orange numbers/types — SyntaxDefinition.plist).
/// User-customizable colors arrive with Preferences in M2.
struct JSONTheme {
    var background = NSColor.black
    var insertionPoint = NSColor.white
    var text = NSColor.white
    var punctuation = NSColor(red: 1, green: 1, blue: 0, alpha: 1)
    var key = NSColor(red: 0.26, green: 0.67, blue: 1, alpha: 1)
    var string = NSColor.white
    var number = NSColor(red: 1, green: 0.565, blue: 0, alpha: 1)
    var boolean = NSColor(red: 0, green: 1, blue: 0, alpha: 1)
    var null = NSColor(red: 1, green: 0, blue: 0, alpha: 1)
    var font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    @MainActor static let `default` = JSONTheme()

    /// The active (possibly user-customized) theme.
    @MainActor static var current = JSONTheme.load()

    // MARK: - Persistence (UserDefaults, sRGB components + font descriptor)

    private static let defaultsKey = "jsonTheme.v1"

    private struct Stored: Codable {
        var colors: [String: [Double]]
        var fontName: String
        var fontSize: Double
    }

    private static func components(_ color: NSColor) -> [Double] {
        let converted = color.usingColorSpace(.sRGB) ?? color
        return [
            Double(converted.redComponent), Double(converted.greenComponent),
            Double(converted.blueComponent), Double(converted.alphaComponent),
        ]
    }

    private static func color(_ components: [Double]?) -> NSColor? {
        guard let c = components, c.count == 4 else { return nil }
        return NSColor(
            srgbRed: CGFloat(c[0]), green: CGFloat(c[1]), blue: CGFloat(c[2]),
            alpha: CGFloat(c[3]))
    }

    @MainActor static func load() -> JSONTheme {
        var theme = JSONTheme()
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
            let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return theme }
        theme.background = color(stored.colors["background"]) ?? theme.background
        theme.text = color(stored.colors["text"]) ?? theme.text
        theme.insertionPoint = theme.text
        theme.punctuation = color(stored.colors["punctuation"]) ?? theme.punctuation
        theme.key = color(stored.colors["key"]) ?? theme.key
        theme.string = color(stored.colors["string"]) ?? theme.string
        theme.number = color(stored.colors["number"]) ?? theme.number
        theme.boolean = color(stored.colors["boolean"]) ?? theme.boolean
        theme.null = color(stored.colors["null"]) ?? theme.null
        if let font = NSFont(name: stored.fontName, size: stored.fontSize) {
            theme.font = font
        } else {
            theme.font = .monospacedSystemFont(ofSize: stored.fontSize, weight: .regular)
        }
        return theme
    }

    @MainActor func save() {
        let stored = Stored(
            colors: [
                "background": Self.components(background),
                "text": Self.components(text),
                "punctuation": Self.components(punctuation),
                "key": Self.components(key),
                "string": Self.components(string),
                "number": Self.components(number),
                "boolean": Self.components(boolean),
                "null": Self.components(null),
            ],
            fontName: font.fontName,
            fontSize: Double(font.pointSize))
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
        JSONTheme.current = self
        NotificationCenter.default.post(name: .preferencesDidChange, object: nil)
    }

    @MainActor static func resetToDefault() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        current = JSONTheme()
        NotificationCenter.default.post(name: .preferencesDidChange, object: nil)
    }
}

/// A small single-pass tokenizer that colors Extended JSON in an NSTextView.
/// Full-document re-highlight on every edit — documents in the editor are
/// single BSON documents (≤16MB, typically tiny), so this stays instant.
@MainActor
final class JSONHighlighter {
    private(set) var theme: JSONTheme

    init(theme: JSONTheme? = nil) {
        self.theme = theme ?? .current
    }

    /// Re-reads the active theme and re-applies it (Preferences changes).
    func refresh(_ textView: NSTextView) {
        theme = .current
        apply(to: textView)
    }

    func apply(to textView: NSTextView) {
        textView.backgroundColor = theme.background
        textView.insertionPointColor = theme.insertionPoint
        textView.font = theme.font
        textView.textColor = theme.text
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isRichText = false
        highlight(textView)
    }

    func highlight(_ textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let text = storage.string
        let full = NSRange(location: 0, length: (text as NSString).length)
        storage.beginEditing()
        storage.setAttributes([.foregroundColor: theme.text, .font: theme.font], range: full)

        let scalars = Array(text.utf16)
        var i = 0
        func setColor(_ color: NSColor, _ range: NSRange) {
            storage.addAttribute(.foregroundColor, value: color, range: range)
        }

        while i < scalars.count {
            let c = scalars[i]
            switch c {
            case UInt16(UInt8(ascii: "\"")), UInt16(UInt8(ascii: "'")):
                // String literal; decide key vs value by what follows.
                let start = i
                let quote = c
                i += 1
                while i < scalars.count {
                    if scalars[i] == UInt16(UInt8(ascii: "\\")) {
                        i += 2
                        continue
                    }
                    if scalars[i] == quote {
                        i += 1
                        break
                    }
                    i += 1
                }
                var j = i
                while j < scalars.count,
                    scalars[j] == UInt16(UInt8(ascii: " ")) || scalars[j] == UInt16(UInt8(ascii: "\t"))
                {
                    j += 1
                }
                let isKey = j < scalars.count && scalars[j] == UInt16(UInt8(ascii: ":"))
                setColor(isKey ? theme.key : theme.string, NSRange(location: start, length: min(i, scalars.count) - start))
            case UInt16(UInt8(ascii: "{")), UInt16(UInt8(ascii: "}")), UInt16(UInt8(ascii: "[")),
                UInt16(UInt8(ascii: "]")), UInt16(UInt8(ascii: ",")), UInt16(UInt8(ascii: ":")):
                setColor(theme.punctuation, NSRange(location: i, length: 1))
                i += 1
            case UInt16(UInt8(ascii: "0"))...UInt16(UInt8(ascii: "9")), UInt16(UInt8(ascii: "-")), UInt16(UInt8(ascii: "+")):
                let start = i
                i += 1
                while i < scalars.count, isNumberScalar(scalars[i]) {
                    i += 1
                }
                setColor(theme.number, NSRange(location: start, length: i - start))
            case let letter where isIdentifierStart(letter):
                let start = i
                i += 1
                while i < scalars.count, isIdentifierScalar(scalars[i]) {
                    i += 1
                }
                let word = String(utf16CodeUnits: Array(scalars[start..<i]), count: i - start)
                let range = NSRange(location: start, length: i - start)
                switch word {
                case "true", "false":
                    setColor(theme.boolean, range)
                case "null", "undefined":
                    setColor(theme.null, range)
                case "ObjectId", "ISODate", "Date", "NumberInt", "NumberLong", "NumberDecimal",
                    "Timestamp", "BinData", "UUID", "MinKey", "MaxKey", "Code", "RegExp", "new",
                    "NaN", "Infinity":
                    setColor(theme.number, range)
                default:
                    break
                }
            default:
                i += 1
            }
        }
        storage.endEditing()
    }

    private func isNumberScalar(_ c: UInt16) -> Bool {
        (UInt16(UInt8(ascii: "0"))...UInt16(UInt8(ascii: "9"))).contains(c)
            || c == UInt16(UInt8(ascii: ".")) || c == UInt16(UInt8(ascii: "e")) || c == UInt16(UInt8(ascii: "E"))
            || c == UInt16(UInt8(ascii: "-")) || c == UInt16(UInt8(ascii: "+"))
    }

    private func isIdentifierStart(_ c: UInt16) -> Bool {
        (UInt16(UInt8(ascii: "a"))...UInt16(UInt8(ascii: "z"))).contains(c)
            || (UInt16(UInt8(ascii: "A"))...UInt16(UInt8(ascii: "Z"))).contains(c)
            || c == UInt16(UInt8(ascii: "$")) || c == UInt16(UInt8(ascii: "_"))
    }

    private func isIdentifierScalar(_ c: UInt16) -> Bool {
        isIdentifierStart(c) || (UInt16(UInt8(ascii: "0"))...UInt16(UInt8(ascii: "9"))).contains(c)
            || c == UInt16(UInt8(ascii: "."))
    }
}

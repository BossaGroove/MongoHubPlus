import BSON
import Foundation

/// Output formatting options. See docs/extended-json.md §2.
public struct EJSONFormat: Sendable {
    public enum Mode: Sendable {
        /// Canonical Extended JSON — every type wrapped, fully lossless.
        /// Used for file export.
        case canonical
        /// "Relaxed with type fidelity" — human-readable like relaxed EJSON,
        /// but with canonical wrappers wherever plain JSON would lose the BSON
        /// type (int64, special doubles, out-of-range dates). Lossless.
        /// Used by the document editor and clipboard. Matches Compass.
        case editor
        /// mongosh syntax — single-quoted strings, unquoted keys, constructor
        /// calls. Deliberately *not* valid JSON; a display format only, never
        /// written to a file. Everything it emits parses back to the identical
        /// BSON, so the editor's round-trip check holds. See
        /// docs/json-dialects.md.
        case shell
    }

    public enum KeyOrder: Sendable {
        case document, ascending, descending
    }

    public var mode: Mode
    public var pretty: Bool
    public var keyOrder: KeyOrder

    public init(mode: Mode, pretty: Bool = false, keyOrder: KeyOrder = .document) {
        self.mode = mode
        self.pretty = pretty
        self.keyOrder = keyOrder
    }

    public static let canonical = EJSONFormat(mode: .canonical)
    public static let editor = EJSONFormat(mode: .editor, pretty: true)
    public static let shell = EJSONFormat(mode: .shell, pretty: true)
}

struct EJSONSerializer {
    let format: EJSONFormat
    private var out = ""
    private var depth = 0

    init(format: EJSONFormat) {
        self.format = format
    }

    mutating func serialize(_ document: Document) throws -> String {
        out = ""
        depth = 0
        try writeDocument(document)
        return out
    }

    mutating func serializeValue(_ value: Primitive) throws -> String {
        out = ""
        depth = 0
        try writeValue(value)
        return out
    }

    // MARK: - Layout helpers

    private mutating func newlineAndIndent() {
        guard format.pretty else { return }
        out += "\n"
        out += String(repeating: "  ", count: depth)
    }

    private mutating func writeKeySeparator() {
        out += format.pretty ? ": " : ":"
    }

    // MARK: - Documents & arrays

    private mutating func writeDocument(_ document: Document) throws {
        if document.isArray {
            try writeArray(document)
            return
        }
        if document.isEmpty {
            out += "{}"
            return
        }
        out += "{"
        depth += 1
        var keys = document.keys
        switch format.keyOrder {
        case .document: break
        case .ascending: keys.sort()
        case .descending: keys.sort(by: >)
        }
        var first = true
        for key in keys {
            guard let value = document[key] else { continue }
            if !first { out += "," }
            first = false
            newlineAndIndent()
            writeKey(key)
            writeKeySeparator()
            try writeValue(value)
        }
        depth -= 1
        newlineAndIndent()
        out += "}"
    }

    private mutating func writeArray(_ document: Document) throws {
        if document.isEmpty {
            out += "[]"
            return
        }
        out += "["
        depth += 1
        var first = true
        for value in document.values {
            if !first { out += "," }
            first = false
            newlineAndIndent()
            try writeValue(value)
        }
        depth -= 1
        newlineAndIndent()
        out += "]"
    }

    // MARK: - Values

    private mutating func writeValue(_ value: Primitive) throws {
        switch value {
        case let document as Document:
            try writeDocument(document)
        case let string as String:
            writeString(string)
        case let bool as Bool:
            out += bool ? "true" : "false"
        case is Null:
            out += "null"
        case let int32 as Int32:
            switch format.mode {
            case .canonical: writeWrapped("$numberInt", String(int32))
            case .editor, .shell: out += String(int32)
            }
        case let int64 as Int:
            // Always wrapped, even in editor mode: a plain integer would
            // re-parse as Int32 when it fits — the type would silently change.
            if format.mode == .shell {
                writeCall("NumberLong", String(int64))
            } else {
                writeWrapped("$numberLong", String(int64))
            }
        case let double as Double:
            writeDouble(double)
        case let date as Date:
            writeDate(date)
        case let objectId as ObjectId:
            if format.mode == .shell {
                writeCall("ObjectId", objectId.hexString)
            } else {
                writeWrapped("$oid", objectId.hexString)
            }
        case let binary as Binary:
            writeBinary(binary)
        case let regex as RegularExpression:
            writeRegex(regex)
        case let timestamp as Timestamp:
            let t = UInt32(bitPattern: timestamp.timestamp)
            let i = UInt32(bitPattern: timestamp.increment)
            if format.mode == .shell {
                out += "Timestamp(\(t), \(i))"
            } else {
                out += "{\"$timestamp\":"
                if format.pretty { out += " " }
                out += "{\"t\":\(t),\"i\":\(i)}}"
            }
        case let decimal as Decimal128:
            let text = Decimal128Codec.string(from: decimal)
            if format.mode == .shell {
                writeCall("NumberDecimal", text)
            } else {
                writeWrapped("$numberDecimal", text)
            }
        case let code as JavaScriptCode:
            if format.mode == .shell {
                writeCall("Code", code.code)
            } else {
                writeWrapped("$code", code.code)
            }
        case let codeWithScope as JavaScriptCodeWithScope:
            if format.mode == .shell {
                out += "Code("
                writeString(codeWithScope.code)
                out += ", "
                try writeDocument(codeWithScope.scope)
                out += ")"
                return
            }
            out += "{\"$code\":"
            if format.pretty { out += " " }
            writeString(codeWithScope.code)
            out += ",\"$scope\":"
            if format.pretty { out += " " }
            try writeDocument(codeWithScope.scope)
            out += "}"
        case is MinKey:
            if format.mode == .shell { out += "MinKey()" } else { writeWrappedRaw("$minKey", "1") }
        case is MaxKey:
            if format.mode == .shell { out += "MaxKey()" } else { writeWrappedRaw("$maxKey", "1") }
        default:
            throw EJSONError("Cannot serialize unsupported BSON type \(type(of: value))")
        }
    }

    private mutating func writeWrapped(_ key: String, _ stringValue: String) {
        out += "{\"\(key)\":"
        if format.pretty { out += " " }
        writeString(stringValue)
        out += "}"
    }

    /// `Name('argument')` — a shell constructor with one quoted argument.
    private mutating func writeCall(_ name: String, _ argument: String) {
        out += name
        out += "("
        writeString(argument)
        out += ")"
    }

    /// Keys are bare in shell mode when they are plain identifiers. Anything
    /// else — including a `$`-prefixed name, which unquoted could be mistaken
    /// for an Extended JSON wrapper on the way back in — stays quoted.
    private mutating func writeKey(_ key: String) {
        guard format.mode == .shell, Self.isPlainIdentifier(key) else {
            writeString(key)
            return
        }
        out += key
    }

    private static func isPlainIdentifier(_ key: String) -> Bool {
        var first = true
        for scalar in key.unicodeScalars {
            let isLetter = (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z")
            let isDigit = scalar >= "0" && scalar <= "9"
            if first {
                guard isLetter || scalar == "_" else { return false }
                first = false
            } else {
                guard isLetter || isDigit || scalar == "_" else { return false }
            }
        }
        return !first
    }

    private mutating func writeWrappedRaw(_ key: String, _ raw: String) {
        out += "{\"\(key)\":"
        if format.pretty { out += " " }
        out += raw
        out += "}"
    }

    // MARK: - Scalars

    private mutating func writeDouble(_ double: Double) {
        let text: String
        if double.isNaN {
            text = "NaN"
        } else if double.isInfinite {
            text = double > 0 ? "Infinity" : "-Infinity"
        } else {
            // Swift's shortest round-trip description always contains '.' or 'e',
            // so the value re-parses as a double — never as an int.
            text = String(double)
        }
        switch format.mode {
        case .canonical:
            writeWrapped("$numberDouble", text)
        case .editor:
            if double.isFinite {
                out += text
            } else {
                writeWrapped("$numberDouble", text)
            }
        case .shell:
            // NaN / Infinity / -Infinity are JavaScript literals, and the
            // parser reads them back as doubles.
            out += text
        }
    }

    private mutating func writeDate(_ date: Date) {
        let millis = Int((date.timeIntervalSince1970 * 1000).rounded())
        let inRelaxedRange = millis >= 0 && millis < 253_402_300_800_000  // year 1970..<10000
        if format.mode == .shell {
            // Outside the ISO-8601 range mongosh itself uses millis.
            if inRelaxedRange {
                writeCall("ISODate", ISO8601.format(date))
            } else {
                out += "new Date(\(millis))"
            }
            return
        }
        if format.mode == .editor && inRelaxedRange {
            writeWrapped("$date", ISO8601.format(date))
        } else {
            out += "{\"$date\":"
            if format.pretty { out += " " }
            out += "{\"$numberLong\":\"\(millis)\"}}"
        }
    }

    private mutating func writeBinary(_ binary: Binary) {
        var payload = binary.data
        if binary.subType.rawSubType == 0x02, payload.count >= 4 {
            // Subtype 0x02 ("binary old") embeds an int32 length prefix;
            // Extended JSON base64 carries only the bare data.
            var inner: UInt32 = 0
            for i in (0..<4).reversed() { inner = inner << 8 | UInt32(payload[payload.startIndex + i]) }
            if Int(inner) == payload.count - 4 {
                payload = payload.dropFirst(4)
            }
        }
        if format.mode == .shell {
            let base64 = payload.base64EncodedString()
            if binary.subType.rawSubType == 0x04, payload.count == 16 {
                writeCall("UUID", Self.uuidString(from: payload))
            } else {
                out += "BinData(\(binary.subType.rawSubType), "
                writeString(base64)
                out += ")"
            }
            return
        }
        out += "{\"$binary\":"
        if format.pretty { out += " " }
        out += "{\"base64\":"
        if format.pretty { out += " " }
        writeString(payload.base64EncodedString())
        out += ",\"subType\":"
        if format.pretty { out += " " }
        writeString(String(format: "%02x", binary.subType.rawSubType))
        out += "}}"
    }

    private mutating func writeRegex(_ regex: RegularExpression) {
        if format.mode == .shell {
            let options = String(regex.options.sorted())
            // A `/…/` literal cannot carry a slash or a newline; fall back to
            // the constructor rather than emit something that will not parse.
            let literalIsSafe =
                !regex.pattern.isEmpty
                && !regex.pattern.contains("/")
                && !regex.pattern.contains(where: \.isNewline)
            if literalIsSafe {
                out += "/\(regex.pattern)/\(options)"
            } else {
                out += "RegExp("
                writeString(regex.pattern)
                if !options.isEmpty {
                    out += ", "
                    writeString(options)
                }
                out += ")"
            }
            return
        }
        out += "{\"$regularExpression\":"
        if format.pretty { out += " " }
        out += "{\"pattern\":"
        if format.pretty { out += " " }
        writeString(regex.pattern)
        out += ",\"options\":"
        if format.pretty { out += " " }
        writeString(String(regex.options.sorted()))
        out += "}}"
    }

    /// Canonical 8-4-4-4-12 text for 16 raw bytes.
    private static func uuidString(from data: Data) -> String {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let groups = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32]
        return groups.map { range in
            String(Array(hex)[range])
        }.joined(separator: "-")
    }

    private mutating func writeString(_ string: String) {
        let shell = format.mode == .shell
        out += shell ? "'" : "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += shell ? "\"" : "\\\""
            case "'": out += shell ? "\\'" : "'"
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let s where s.value < 0x20:
                out += String(format: "\\u%04x", s.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out += shell ? "'" : "\""
    }
}

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
            writeString(key)
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
            case .editor: out += String(int32)
            }
        case let int64 as Int:
            // Always wrapped, even in editor mode: a plain integer would
            // re-parse as Int32 when it fits — the type would silently change.
            writeWrapped("$numberLong", String(int64))
        case let double as Double:
            writeDouble(double)
        case let date as Date:
            writeDate(date)
        case let objectId as ObjectId:
            writeWrapped("$oid", objectId.hexString)
        case let binary as Binary:
            writeBinary(binary)
        case let regex as RegularExpression:
            writeRegex(regex)
        case let timestamp as Timestamp:
            out += "{\"$timestamp\":"
            if format.pretty { out += " " }
            out +=
                "{\"t\":\(UInt32(bitPattern: timestamp.timestamp)),\"i\":\(UInt32(bitPattern: timestamp.increment))}}"
        case let decimal as Decimal128:
            writeWrapped("$numberDecimal", Decimal128Codec.string(from: decimal))
        case let code as JavaScriptCode:
            writeWrapped("$code", code.code)
        case let codeWithScope as JavaScriptCodeWithScope:
            out += "{\"$code\":"
            if format.pretty { out += " " }
            writeString(codeWithScope.code)
            out += ",\"$scope\":"
            if format.pretty { out += " " }
            try writeDocument(codeWithScope.scope)
            out += "}"
        case is MinKey:
            writeWrappedRaw("$minKey", "1")
        case is MaxKey:
            writeWrappedRaw("$maxKey", "1")
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
        }
    }

    private mutating func writeDate(_ date: Date) {
        let millis = Int((date.timeIntervalSince1970 * 1000).rounded())
        let inRelaxedRange = millis >= 0 && millis < 253_402_300_800_000  // year 1970..<10000
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

    private mutating func writeString(_ string: String) {
        out += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
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
        out += "\""
    }
}

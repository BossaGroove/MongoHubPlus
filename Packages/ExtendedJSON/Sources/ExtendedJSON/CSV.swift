import BSON
import Foundation

/// CSV export/import for collections (feature-spec 5.3, owner decisions
/// 2026-08-31):
///
/// - **Export** flattens every document into dotted column paths
///   (`profile.city`, `tags.0`), columns ordered by first appearance.
///   Cells are spreadsheet-friendly plain values — CSV is the *lossy*
///   interchange format; JSON-Lines remains the lossless one.
/// - **Import** parses each cell as Extended JSON (with shell
///   conveniences), then tries strict ISO 8601 dates, then falls back to a
///   raw string. Dotted headers rebuild nested documents; a group whose
///   keys are all integers becomes an array (compacted in index order).
///   Empty cells are omitted (not null).
public enum CSV {
    // MARK: - Flattening (export)

    /// Depth-first (path, value) pairs for one document. Empty documents
    /// and arrays are kept as leaves so they survive as `{}` / `[]`.
    public static func flatten(_ document: Document) -> [(path: String, value: Primitive)] {
        var result: [(String, Primitive)] = []
        flatten(document, prefix: "", into: &result)
        return result
    }

    private static func flatten(
        _ document: Document, prefix: String, into result: inout [(String, Primitive)]
    ) {
        for pair in document.pairs {
            let path = prefix.isEmpty ? pair.key : "\(prefix).\(pair.key)"
            if let child = pair.value as? Document, !child.isEmpty {
                flatten(child, prefix: path, into: &result)
            } else {
                result.append((path, pair.value))
            }
        }
    }

    // MARK: - Cell formatting (export)

    /// Spreadsheet-friendly plain rendering (no Extended JSON wrappers).
    public static func cellText(_ value: Primitive) -> String {
        switch value {
        case is Null: return ""
        case let string as String: return string
        case let bool as Bool: return bool ? "true" : "false"
        case let int32 as Int32: return String(int32)
        case let int64 as Int: return String(int64)
        case let double as Double:
            if double.isNaN { return "NaN" }
            if double.isInfinite { return double > 0 ? "Infinity" : "-Infinity" }
            return String(double)
        case let date as Date: return isoWithFraction.format(date)
        case let objectId as ObjectId: return objectId.hexString
        case let decimal as Decimal128: return Decimal128Codec.string(from: decimal)
        case let regex as RegularExpression: return "/\(regex.pattern)/\(regex.options)"
        case let binary as Binary: return binary.data.base64EncodedString()
        case let document as Document: return document.isArray ? "[]" : "{}"
        default:
            return (try? ExtendedJSON.stringifyValue(
                value, format: EJSONFormat(mode: .editor, pretty: false))) ?? ""
        }
    }

    private static let isoWithFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoPlain = Date.ISO8601FormatStyle()

    // MARK: - RFC 4180 encoding

    public static func encodeRow(_ fields: [String]) -> String {
        fields.map { field in
            if field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
                return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return field
        }.joined(separator: ",")
    }

    // MARK: - RFC 4180 parsing

    /// Parses a whole CSV text (quoted fields may contain commas, quotes,
    /// and newlines). Accepts LF and CRLF. A UTF-8 BOM is stripped.
    public static func parse(_ text: String) -> [[String]] {
        var text = Substring(text)
        if text.hasPrefix("\u{FEFF}") { text = text.dropFirst() }

        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var index = text.startIndex

        func endField() {
            row.append(field)
            field = ""
        }
        func endRow() {
            endField()
            rows.append(row)
            row = []
        }

        while index < text.endIndex {
            let char = text[index]
            if inQuotes {
                if char == "\"" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        index = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(char)
                }
            } else {
                switch char {
                case "\"" where field.isEmpty: inQuotes = true
                case ",": endField()
                // Swift iterates grapheme clusters: CRLF is ONE Character.
                case "\r\n", "\n", "\r": endRow()
                default: field.append(char)
                }
            }
            index = text.index(after: index)
        }
        if !field.isEmpty || !row.isEmpty {
            endRow()
        }
        return rows
    }

    // MARK: - Cell typing + document assembly (import)

    /// Extended JSON per cell, then strict ISO 8601 → Date, else raw string.
    public static func cellValue(_ text: String) -> Primitive {
        if let date = (try? isoWithFraction.parse(text)) ?? (try? isoPlain.parse(text)) {
            return date
        }
        if let value = try? ExtendedJSON.parseValue(text) {
            return value
        }
        return text
    }

    /// Builds one document from a header row and a data row. Empty cells
    /// (and empty headers) are skipped.
    public static func document(headers: [String], row: [String]) -> Document {
        var root = Group()
        for (index, header) in headers.enumerated() where !header.isEmpty {
            guard index < row.count, !row[index].isEmpty else { continue }
            root.set(
                path: header.split(separator: ".").map(String.init),
                value: cellValue(row[index]))
        }
        return root.materialize(asArray: false)
    }

    /// Ordered intermediate tree — needed so arrays can be compacted in
    /// index order regardless of column order.
    private struct Group {
        private(set) var keys: [String] = []
        private var values: [String: Primitive] = [:]
        private var groups: [String: Group] = [:]

        mutating func set(path: [String], value: Primitive) {
            guard let key = path.first else { return }
            if !keys.contains(key) { keys.append(key) }
            if path.count == 1 {
                values[key] = value
            } else {
                var child = groups[key] ?? Group()
                child.set(path: Array(path.dropFirst()), value: value)
                groups[key] = child
            }
        }

        func materialize(asArray: Bool) -> Document {
            var document = Document(isArray: asArray)
            let ordered =
                asArray
                ? keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
                : keys
            for key in ordered {
                let value: Primitive
                if let group = groups[key] {
                    let childIsArray = group.keys.allSatisfy { Int($0) != nil }
                    value = group.materialize(asArray: childIsArray && !group.keys.isEmpty)
                } else if let leaf = values[key] {
                    value = leaf
                } else {
                    continue
                }
                if asArray {
                    document.append(value)
                } else {
                    document[key] = value
                }
            }
            return document
        }
    }
}

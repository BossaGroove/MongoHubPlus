import BSON
import Foundation

/// Display strings for the results outline's Value / Type columns
/// (docs/extended-json.md §5). Display-only — not a serialization format.
public enum BSONDisplay {
    public static func typeName(_ value: Primitive) -> String {
        switch value {
        case let document as Document:
            if document.isArray {
                switch document.count {
                case 0: return "Array, no item"
                case 1: return "Array, 1 item"
                default: return "Array, \(document.count) items"
                }
            }
            if let ref = document["$ref"] as? String {
                if let db = document["$db"] as? String {
                    return "Ref(\(db).\(ref))"
                }
                return "Ref(\(ref))"
            }
            switch document.count {
            case 0: return "Object, no item"
            case 1: return "Object, 1 item"
            default: return "Object, \(document.count) items"
            }
        case is Double: return "Double"
        case is Int32: return "Integer"
        case is Int: return "Long Integer"
        case is Bool: return "Boolean"
        case is Date: return "Date"
        case is ObjectId: return "ObjectId"
        case is RegularExpression: return "Regex"
        case is Timestamp: return "Timestamp"
        case let binary as Binary:
            return binary.subType.rawSubType == 0x04 ? "UUID" : "Binary"
        case is String: return "String"
        case is Null: return "Null"
        case is JavaScriptCode: return "Code"
        case is JavaScriptCodeWithScope: return "CodeWithScope"
        case is MinKey: return "MinKey"
        case is MaxKey: return "MaxKey"
        case is Decimal128: return "Decimal"
        default: return String(describing: type(of: value))
        }
    }

    // Legacy displayed dates in the local time zone (issue #174).
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public static func valueString(_ value: Primitive) -> String {
        switch value {
        case is Document: return ""
        case let double as Double:
            if double.isNaN { return "NaN" }
            if double.isInfinite { return double > 0 ? "Infinity" : "-Infinity" }
            return String(double)
        case let int32 as Int32: return String(int32)
        case let int64 as Int: return String(int64)
        case let bool as Bool: return bool ? "true" : "false"
        case let date as Date: return dateFormatter.string(from: date)
        case let objectId as ObjectId: return "ObjectId(\"\(objectId.hexString)\")"
        case let regex as RegularExpression: return "/\(regex.pattern)/\(regex.options)"
        case let timestamp as Timestamp:
            return "Timestamp(\(UInt32(bitPattern: timestamp.timestamp)), \(UInt32(bitPattern: timestamp.increment)))"
        case let binary as Binary:
            let subType = binary.subType.rawSubType
            if subType == 0x04, binary.data.count == 16 {
                let uuid = binary.data.withUnsafeBytes { raw in
                    UUID(uuid: raw.load(as: uuid_t.self))
                }
                return "UUID(\"\(uuid.uuidString.lowercased())\")"
            }
            return "BinData(\(subType), \"\(binary.data.base64EncodedString())\")"
        case let string as String: return string
        case is Null: return "null"
        case let code as JavaScriptCode: return code.code
        case let codeWithScope as JavaScriptCodeWithScope: return codeWithScope.code
        case is MinKey: return "MinKey"
        case is MaxKey: return "MaxKey"
        case let decimal as Decimal128: return Decimal128Codec.string(from: decimal)
        default: return ""
        }
    }
}

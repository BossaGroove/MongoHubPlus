import BSON
import Foundation

/// MongoDB Extended JSON v2 for MongoHub Plus.
///
/// - Parsing accepts canonical + relaxed Extended JSON plus the mongosh shell
///   conveniences Compass accepts (unquoted keys, single quotes, `ObjectId(…)`,
///   `ISODate(…)`, `/regex/`, …). See docs/extended-json.md §1.
/// - Serialization is lossless in both modes (`.canonical` for export,
///   `.editor` for the document editor / clipboard). See §2.
public enum ExtendedJSON {
    /// Parses a top-level object or array.
    public static func parseDocument(_ json: String) throws -> Document {
        var parser = EJSONParser(json)
        return try parser.parseDocument()
    }

    /// Parses any single value (object, array, or scalar).
    public static func parseValue(_ json: String) throws -> Primitive {
        var parser = EJSONParser(json)
        return try parser.parseSingleValue()
    }

    /// Serializes a document (or array document).
    public static func stringify(
        _ document: Document, format: EJSONFormat = .canonical
    ) throws -> String {
        var serializer = EJSONSerializer(format: format)
        return try serializer.serialize(document)
    }

    /// Serializes any single value (used by the in-place value editor to
    /// prefill the edit field with a parseable, lossless representation).
    public static func stringifyValue(
        _ value: Primitive, format: EJSONFormat = .canonical
    ) throws -> String {
        var serializer = EJSONSerializer(format: format)
        return try serializer.serializeValue(value)
    }

    /// Verifies that `document` survives a serialize→parse round trip
    /// byte-for-byte. The document editor refuses to open a document as
    /// editable when this fails (it would silently corrupt values on save).
    public static func verifyRoundTrip(
        _ document: Document, format: EJSONFormat = .editor
    ) -> RoundTripResult {
        do {
            let text = try stringify(document, format: format)
            let reparsed = try parseDocument(text)
            if reparsed.makeData() == document.makeData() {
                return .lossless
            }
            return .lossy(reason: "re-parsed document differs from the original")
        } catch {
            return .lossy(reason: String(describing: error))
        }
    }

    public enum RoundTripResult: Equatable, Sendable {
        case lossless
        case lossy(reason: String)
    }
}

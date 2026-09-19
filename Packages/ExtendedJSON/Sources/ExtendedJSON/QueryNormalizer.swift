import BSON
import Foundation

/// The "type an id, get a query" shortcut — the core UX carried over from
/// MongoHub. Turns bare user input into a full criteria document string.
/// Rules: docs/extended-json.md §3.
public enum QueryNormalizer {
    /// Normalizes raw criteria-field text into Extended JSON query text.
    /// Returns an empty string for blank input when `emptyIsValid`, else `{}`.
    /// Normalizes the body of an update operator (`$set`, `$inc`, …).
    ///
    /// Deliberately *not* `normalizeCriteria`: an operand is a document of
    /// field/value pairs, not a query, so the "type an id" shortcut
    /// (feature-spec 3.3) must not apply here. Running an operand through the
    /// query normalizer turned a mistyped bare word into `{_id: "word"}`,
    /// which is an update that rewrites the `_id` of every matched document
    /// — it should be a parse error instead, and the caller reports it.
    ///
    /// The one convenience kept is the outer braces: `currency: 'HKD'` means
    /// the same thing as `{currency: 'HKD'}` and reads better in a one-line
    /// field.
    public static func normalizeOperand(_ input: String) -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "{}" }
        if text.hasPrefix("{") { return text }
        if text.contains(":") { return "{\(text)}" }
        // Anything else is handed over as typed, so it fails to parse rather
        // than being quietly reinterpreted.
        return text
    }

    public static func normalizeCriteria(_ input: String, emptyIsValid: Bool = true) -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return emptyIsValid ? "" : "{}"
        }

        if isHex24(text) {
            return "{_id: ObjectId(\"\(text)\")}"
        }
        if let unquoted = unquote(text), isHex24(unquoted) {
            return "{_id: ObjectId(\"\(unquoted)\")}"
        }
        if text.hasPrefix("{") {
            if innerStartsWithOidKey(text) {
                return "{_id: \(text)}"
            }
            return text
        }
        if text.hasPrefix("ObjectId") {
            return "{_id: \(text)}"
        }
        if text.hasPrefix("\"$oid\"") || text.hasPrefix("'$oid'") {
            return "{_id: {\(text)}}"
        }
        if text.contains(":") {
            return "{\(text)}"
        }
        if text.hasPrefix("\"") || text.hasPrefix("'") {
            return "{_id: \(text)}"
        }
        return "{_id: \"\(text)\"}"
    }

    /// True when the text is exactly 24 hex characters (an ObjectId).
    static func isHex24(_ text: String) -> Bool {
        text.utf8.count == 24
            && text.utf8.allSatisfy {
                (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
                    || (0x41...0x46).contains($0)
            }
    }

    private static func unquote(_ text: String) -> String? {
        guard text.count >= 2 else { return nil }
        let first = text.first!
        guard first == "\"" || first == "'", text.last == first else { return nil }
        return String(text.dropFirst().dropLast())
    }

    /// `{ "$oid": … }` typed directly — wrap it as the `_id` value.
    private static func innerStartsWithOidKey(_ text: String) -> Bool {
        var inner = Substring(text.dropFirst()).drop(while: { $0 == " " || $0 == "\t" })
        guard let quote = inner.first, quote == "\"" || quote == "'" else { return false }
        inner = inner.dropFirst()
        return inner.hasPrefix("$oid")
    }
}

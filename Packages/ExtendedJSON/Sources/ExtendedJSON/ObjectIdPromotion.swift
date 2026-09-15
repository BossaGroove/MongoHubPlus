import Foundation

/// The "type an id" shortcut (extended-json.md §3, feature-spec 3.3) only
/// ever reaches `_id`. This is its counterpart for every *other* id field:
/// a text-level pass that wraps 24-hex string values in `ObjectId(…)`.
///
/// It is deliberately surgical rather than a parse/re-serialize round trip —
/// the result is written back into the user's own criteria field, so
/// everything it does not promote must survive character for character:
/// their quote style, their spacing, their unquoted keys, their dates.
extension QueryNormalizer {
    /// Keys whose direct string value is not data — promoting one would
    /// either change what the query means (`$regex`) or produce invalid
    /// Extended JSON (`$oid`).
    private static let stringValueKeys: Set<String> = [
        "$regex", "$options", "$where", "$comment", "$language", "$search", "$meta", "$type",
        "$oid", "$date", "$uuid", "$symbol", "$ref", "$db",
        "$numberInt", "$numberLong", "$numberDouble", "$numberDecimal",
    ]

    /// Keys whose whole subtree is opaque — nothing inside is a query value
    /// we may rewrite (a regex's `pattern`, a binary's `base64`, JS source).
    private static let opaqueKeys: Set<String> = [
        "$regularExpression", "$binary", "$timestamp", "$code", "$scope", "$expr", "$jsonSchema",
        "$text", "$geometry",
    ]

    /// Wraps every 24-hex string *value* in `ObjectId(…)`, in place, leaving
    /// the rest of the text exactly as it was typed. Keys are never touched,
    /// nor are constructor arguments (so re-applying this is a no-op), nor
    /// anything under a key from `stringValueKeys`/`opaqueKeys`.
    ///
    /// Nesting comes for free: `{a: {b: "<hex>"}}` and `{$in: ["<hex>"]}`
    /// both promote, because an array inherits the key it hangs off.
    public static func promotingObjectIds(_ input: String) -> String {
        /// One open bracket, and the key whose value it holds.
        struct Frame {
            var bracket: Character
            var key: String
        }

        let chars = Array(input)
        var output = ""
        output.reserveCapacity(chars.count + 16)
        var frames: [Frame] = []
        var index = 0

        func setCurrentKey(_ key: String) {
            guard !frames.isEmpty else { return }
            frames[frames.count - 1].key = key
        }

        /// True when the next non-space character is `:` — i.e. the token
        /// just read was a key, not a value.
        func nextIsColon(from start: Int) -> Bool {
            var probe = start
            while probe < chars.count, chars[probe].isWhitespace { probe += 1 }
            return probe < chars.count && chars[probe] == ":"
        }

        func mayPromote() -> Bool {
            // Inside a constructor call the string is an argument, not a
            // query value: ObjectId('…'), ISODate('…'), BinData(0, '…').
            if frames.last?.bracket == "(" { return false }
            if let key = frames.last?.key, stringValueKeys.contains(key) { return false }
            return !frames.contains { opaqueKeys.contains($0.key) }
        }

        while index < chars.count {
            let char = chars[index]

            if char == "{" || char == "[" || char == "(" {
                // An array belongs to the key it hangs off, so the values in
                // `$in: [ … ]` are still `$in`'s.
                let inherited = char == "[" ? (frames.last?.key ?? "") : ""
                frames.append(Frame(bracket: char, key: inherited))
                output.append(char)
                index += 1
                continue
            }

            if char == "}" || char == "]" || char == ")" {
                if !frames.isEmpty { frames.removeLast() }
                output.append(char)
                index += 1
                continue
            }

            if char == "\"" || char == "'" {
                var cursor = index + 1
                var content = ""
                var terminated = false
                while cursor < chars.count {
                    let current = chars[cursor]
                    if current == "\\", cursor + 1 < chars.count {
                        content.append(current)
                        content.append(chars[cursor + 1])
                        cursor += 2
                        continue
                    }
                    if current == char {
                        terminated = true
                        break
                    }
                    content.append(current)
                    cursor += 1
                }
                guard terminated else {
                    // Unterminated literal — a half-typed query. Emit the
                    // rest untouched and let the parser report it.
                    output += String(chars[index...])
                    return output
                }
                let literal = String(chars[index...cursor])
                index = cursor + 1

                if nextIsColon(from: index) {
                    setCurrentKey(content)
                    output += literal
                } else if isHex24(content), mayPromote() {
                    output += "ObjectId(\(literal))"
                } else {
                    output += literal
                }
                continue
            }

            if char.isLetter || char == "_" || char == "$" {
                var cursor = index
                var token = ""
                while cursor < chars.count {
                    let current = chars[cursor]
                    guard
                        current.isLetter || current.isNumber || current == "_" || current == "$"
                            || current == "."
                    else { break }
                    token.append(current)
                    cursor += 1
                }
                index = cursor
                if nextIsColon(from: index) { setCurrentKey(token) }
                output += token
                continue
            }

            output.append(char)
            index += 1
        }
        return output
    }
}

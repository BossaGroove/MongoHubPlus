import BSON
import Foundation
import NIOCore

/// Recursive-descent parser for MongoDB Extended JSON v2 (canonical + relaxed)
/// plus the mongosh shell conveniences accepted by Compass's query bar.
///
/// Spec: docs/extended-json.md §1. Deviations forced by the BSON library
/// (no symbol / undefined / dbPointer) surface as clear errors.
struct EJSONParser {
    private let bytes: [UInt8]
    private var pos = 0

    init(_ input: String) {
        self.bytes = Array(input.utf8)
    }

    // MARK: - Entry points

    /// Parses a top-level object or array into a `Document`.
    mutating func parseDocument() throws -> Document {
        skipWhitespace()
        guard let c = peek() else { throw err("Empty input") }
        let value: Primitive
        switch c {
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            value = try parseValue()
        default:
            throw err("Expected an object or an array at the top level")
        }
        skipWhitespace()
        guard pos == bytes.count else { throw err("Unexpected trailing characters") }
        guard let document = value as? Document else {
            throw err("Expected an object or an array at the top level")
        }
        return document
    }

    /// Parses any single value (used by tests and by field-level inputs).
    mutating func parseSingleValue() throws -> Primitive {
        skipWhitespace()
        let value = try parseValue()
        skipWhitespace()
        guard pos == bytes.count else { throw err("Unexpected trailing characters") }
        return value
    }

    // MARK: - Scanner primitives

    private func peek(_ ahead: Int = 0) -> UInt8? {
        let i = pos + ahead
        return i < bytes.count ? bytes[i] : nil
    }

    private mutating func advance() -> UInt8? {
        guard pos < bytes.count else { return nil }
        defer { pos += 1 }
        return bytes[pos]
    }

    private mutating func skipWhitespace() {
        while let c = peek(),
            c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
        {
            pos += 1
        }
    }

    private mutating func expect(_ ascii: Character) throws {
        skipWhitespace()
        guard let c = advance(), c == ascii.asciiValue else {
            throw err("Expected '\(ascii)'")
        }
    }

    private func err(_ message: String) -> EJSONError {
        EJSONError(message, offset: pos)
    }

    // MARK: - Values

    private mutating func parseValue() throws -> Primitive {
        skipWhitespace()
        guard let c = peek() else { throw err("Unexpected end of input") }
        switch c {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""), UInt8(ascii: "'"): return try parseString()
        case UInt8(ascii: "/"): return try parseRegexLiteral()
        case UInt8(ascii: "-"), UInt8(ascii: "+"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            return try parseNumber()
        default:
            return try parseIdentifierValue()
        }
    }

    // MARK: - Objects (with Extended JSON wrapper detection)

    private mutating func parseObject() throws -> Primitive {
        try expect("{")
        var pairs: [(String, Primitive)] = []
        skipWhitespace()
        if peek() == UInt8(ascii: "}") {
            pos += 1
            return Document()
        }
        while true {
            skipWhitespace()
            let key = try parseKey()
            try expect(":")
            let value = try parseValue()
            pairs.append((key, value))
            skipWhitespace()
            switch advance() {
            case UInt8(ascii: ","):
                // Tolerate a trailing comma before '}' (shell leniency).
                skipWhitespace()
                if peek() == UInt8(ascii: "}") {
                    pos += 1
                    return try finishObject(pairs)
                }
            case UInt8(ascii: "}"):
                return try finishObject(pairs)
            default:
                throw err("Expected ',' or '}' in object")
            }
        }
    }

    private mutating func finishObject(_ pairs: [(String, Primitive)]) throws -> Primitive {
        if let wrapped = try convertTypeWrapper(pairs) {
            return wrapped
        }
        var document = Document()
        for (key, value) in pairs {
            document[key] = value
        }
        return document
    }

    private mutating func parseKey() throws -> String {
        skipWhitespace()
        guard let c = peek() else { throw err("Unexpected end of input in object") }
        if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") {
            let key = try parseStringLiteral()
            guard !key.utf8.contains(0) else {
                throw err("Object keys must not contain NUL characters")
            }
            return key
        }
        // Unquoted key: [A-Za-z0-9$_#]+ ; a key starting with a digit must be all digits.
        var key = ""
        while let k = peek(), isIdentifierByte(k) {
            key.unicodeScalars.append(Unicode.Scalar(k))
            pos += 1
        }
        guard !key.isEmpty else { throw err("Expected an object key") }
        if let first = key.utf8.first, (0x30...0x39).contains(first),
            !key.utf8.allSatisfy({ (0x30...0x39).contains($0) })
        {
            throw err("Unquoted keys starting with a digit must be all digits: '\(key)'")
        }
        return key
    }

    private func isIdentifierByte(_ b: UInt8) -> Bool {
        (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b) || (0x30...0x39).contains(b)
            || b == UInt8(ascii: "$") || b == UInt8(ascii: "_") || b == UInt8(ascii: "#")
    }

    // MARK: - Arrays

    private mutating func parseArray() throws -> Primitive {
        try expect("[")
        var document = Document(isArray: true)
        skipWhitespace()
        if peek() == UInt8(ascii: "]") {
            pos += 1
            return document
        }
        var index = 0
        while true {
            let value = try parseValue()
            document[String(index)] = value
            index += 1
            skipWhitespace()
            switch advance() {
            case UInt8(ascii: ","):
                skipWhitespace()
                if peek() == UInt8(ascii: "]") {  // trailing comma
                    pos += 1
                    return document
                }
            case UInt8(ascii: "]"):
                return document
            default:
                throw err("Expected ',' or ']' in array")
            }
        }
    }

    // MARK: - Strings

    private mutating func parseString() throws -> Primitive {
        try parseStringLiteral()
    }

    private mutating func parseStringLiteral() throws -> String {
        skipWhitespace()
        guard let quote = advance(),
            quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'")
        else {
            throw err("Expected a string")
        }
        var out: [UInt8] = []
        while true {
            guard let c = advance() else { throw err("Unterminated string") }
            if c == quote {
                guard let s = String(bytes: out, encoding: .utf8) else {
                    throw err("Invalid UTF-8 in string")
                }
                return s
            }
            if c == UInt8(ascii: "\\") {
                guard let e = advance() else { throw err("Unterminated escape sequence") }
                switch e {
                case UInt8(ascii: "\""), UInt8(ascii: "'"), UInt8(ascii: "\\"), UInt8(ascii: "/"):
                    out.append(e)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    let scalar = try parseUnicodeEscape()
                    out.append(contentsOf: Array(String(scalar).utf8))
                default:
                    throw err("Invalid escape sequence '\\\(Character(Unicode.Scalar(e)))'")
                }
            } else {
                out.append(c)
            }
        }
    }

    private mutating func parseUnicodeEscape() throws -> Unicode.Scalar {
        let first = try parseHex4()
        // Surrogate pair handling.
        if (0xD800...0xDBFF).contains(first) {
            guard peek() == UInt8(ascii: "\\"), peek(1) == UInt8(ascii: "u") else {
                throw err("Unpaired high surrogate in \\u escape")
            }
            pos += 2
            let second = try parseHex4()
            guard (0xDC00...0xDFFF).contains(second) else {
                throw err("Invalid low surrogate in \\u escape")
            }
            let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
            guard let scalar = Unicode.Scalar(combined) else {
                throw err("Invalid unicode scalar in \\u escape")
            }
            return scalar
        }
        if (0xDC00...0xDFFF).contains(first) {
            throw err("Unpaired low surrogate in \\u escape")
        }
        guard let scalar = Unicode.Scalar(first) else {
            throw err("Invalid unicode scalar in \\u escape")
        }
        return scalar
    }

    private mutating func parseHex4() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let c = advance(), let digit = hexDigit(c) else {
                throw err("Invalid \\u escape: expected 4 hex digits")
            }
            value = value << 4 | UInt32(digit)
        }
        return value
    }

    private func hexDigit(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    // MARK: - Numbers

    /// Integer that fits int32 → Int32; fits int64 → Int; otherwise, or with
    /// a fraction/exponent → Double (mongosh promotes oversized ints too).
    private mutating func parseNumber() throws -> Primitive {
        let start = pos
        if peek() == UInt8(ascii: "-") || peek() == UInt8(ascii: "+") { pos += 1 }
        // "-Infinity" / "+Infinity" / bare identifiers after sign.
        if let c = peek(), !(UInt8(ascii: "0")...UInt8(ascii: "9")).contains(c) {
            let negative = bytes[start] == UInt8(ascii: "-")
            let word = scanIdentifier()
            switch word {
            case "Infinity": return negative ? -Double.infinity : Double.infinity
            case "NaN": return Double.nan
            default: throw err("Invalid number")
            }
        }
        var isDouble = false
        while let c = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(c) { pos += 1 }
        if peek() == UInt8(ascii: ".") {
            isDouble = true
            pos += 1
            while let c = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(c) { pos += 1 }
        }
        if peek() == UInt8(ascii: "e") || peek() == UInt8(ascii: "E") {
            isDouble = true
            pos += 1
            if peek() == UInt8(ascii: "-") || peek() == UInt8(ascii: "+") { pos += 1 }
            while let c = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(c) { pos += 1 }
        }
        guard let text = String(bytes: bytes[start..<pos], encoding: .utf8), !text.isEmpty else {
            throw err("Invalid number")
        }
        if !isDouble {
            if let i32 = Int32(text) { return i32 }
            if let i64 = Int(text) { return i64 }
        }
        guard let d = Double(text) else { throw err("Invalid number '\(text)'") }
        return d
    }

    // MARK: - Identifiers, keywords, and shell constructors

    private mutating func scanIdentifier() -> String {
        var out = ""
        while let c = peek(),
            (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c)
                || (0x30...0x39).contains(c) || c == UInt8(ascii: "_") || c == UInt8(ascii: "$")
                || c == UInt8(ascii: ".")
        {
            out.unicodeScalars.append(Unicode.Scalar(c))
            pos += 1
        }
        return out
    }

    private mutating func parseIdentifierValue() throws -> Primitive {
        let start = pos
        let word = scanIdentifier()
        guard !word.isEmpty else { throw err("Unexpected character") }
        switch word {
        case "true": return true
        case "false": return false
        case "null": return Null()
        case "NaN": return Double.nan
        case "Infinity": return Double.infinity
        case "MinKey": try skipEmptyParens(); return MinKey()
        case "MaxKey": try skipEmptyParens(); return MaxKey()
        case "undefined":
            throw EJSONError(
                "'undefined' is a deprecated BSON type not supported by MongoHub Plus", offset: start)
        case "new":
            skipWhitespace()
            let ctor = scanIdentifier()
            guard ctor == "Date" else { throw err("Expected 'new Date(...)'") }
            return try parseDateConstructor()
        case "Date", "ISODate":
            return try parseDateConstructor()
        case "ObjectId":
            let args = try parseArguments(min: 1, max: 1, name: word)
            guard let hex = args[0] as? String, let oid = ObjectId(hex) else {
                throw err("ObjectId(...) requires a 24-character hex string")
            }
            return oid
        case "NumberInt":
            let args = try parseArguments(min: 1, max: 1, name: word)
            guard let i32 = coerceInt32(args[0]) else {
                throw err("NumberInt(...) requires a 32-bit integer")
            }
            return i32
        case "NumberLong":
            let args = try parseArguments(min: 1, max: 1, name: word)
            guard let i64 = coerceInt64(args[0]) else {
                throw err("NumberLong(...) requires a 64-bit integer")
            }
            return i64
        case "NumberDecimal":
            let args = try parseArguments(min: 1, max: 1, name: word)
            let text: String
            switch args[0] {
            case let s as String: text = s
            case let i as Int32: text = String(i)
            case let i as Int: text = String(i)
            case let d as Double: text = String(d)
            default: throw err("NumberDecimal(...) requires a string or number")
            }
            return try Decimal128Codec.decimal128(parsing: text)
        case "Timestamp":
            let args = try parseArguments(min: 2, max: 2, name: word)
            guard let t = coerceUInt32(args[0]), let i = coerceUInt32(args[1]) else {
                throw err("Timestamp(t, i) requires two unsigned 32-bit integers")
            }
            return Timestamp(increment: Int32(bitPattern: i), timestamp: Int32(bitPattern: t))
        case "BinData":
            let args = try parseArguments(min: 2, max: 2, name: word)
            guard let subtype = coerceUInt32(args[0]), subtype <= 0xFF,
                let base64 = args[1] as? String,
                let data = Data(base64Encoded: base64)
            else {
                throw err("BinData(subtype, \"base64\") requires a subtype byte and base64 data")
            }
            return makeBinary(subType: UInt8(subtype), data: data)
        case "UUID":
            let args = try parseArguments(min: 1, max: 1, name: word)
            guard let text = args[0] as? String, let uuid = UUID(uuidString: text) else {
                throw err("UUID(...) requires a UUID string")
            }
            return makeBinary(subType: 0x04, data: withUnsafeBytes(of: uuid.uuid) { Data($0) })
        case "Code":
            let args = try parseArguments(min: 1, max: 2, name: word)
            guard let code = args[0] as? String else {
                throw err("Code(...) requires a string")
            }
            if args.count == 2 {
                guard let scope = args[1] as? Document, !scope.isArray else {
                    throw err("Code(code, scope) requires an object scope")
                }
                return JavaScriptCodeWithScope(code, scope: scope)
            }
            return JavaScriptCode(code)
        case "RegExp":
            let args = try parseArguments(min: 1, max: 2, name: word)
            guard let pattern = args[0] as? String else {
                throw err("RegExp(...) requires a pattern string")
            }
            let options = args.count == 2 ? (args[1] as? String ?? "") : ""
            return try makeRegularExpression(pattern: pattern, options: options, at: start)
        case "Symbol", "DBPointer", "DBRef", "Function", "ScopeFunction":
            throw EJSONError(
                "'\(word)' is not supported (deprecated BSON type or legacy MongoHub construct)",
                offset: start)
        default:
            throw EJSONError("Unknown identifier '\(word)'", offset: start)
        }
    }

    /// `MinKey` / `MaxKey` may be written bare or with `()` (mongosh style).
    private mutating func skipEmptyParens() throws {
        skipWhitespace()
        guard peek() == UInt8(ascii: "(") else { return }
        pos += 1
        skipWhitespace()
        guard advance() == UInt8(ascii: ")") else { throw err("Expected ')'") }
    }

    private mutating func parseDateConstructor() throws -> Primitive {
        let args = try parseArguments(min: 0, max: 1, name: "Date")
        if args.isEmpty { return Self.exactDate(Date()) }
        switch args[0] {
        case let millis as Int32: return Self.exactDate(millis: Int(millis))
        case let millis as Int: return Self.exactDate(millis: millis)
        case let millis as Double: return Self.exactDate(millis: Int(millis))
        case let text as String:
            guard let date = ISO8601.parseShellDate(text) else {
                throw err(Self.dateErrorMessage(for: text))
            }
            return Self.exactDate(date)
        default:
            throw err("Date(...) requires milliseconds or an ISO-8601 string")
        }
    }

    /// A timestamp with no time zone is refused rather than guessed: the
    /// ECMAScript spec reads it as local time and mongosh reads it as UTC, so
    /// picking either would shift the value by hours without saying so.
    private static func dateErrorMessage(for text: String) -> String {
        if let marker = text.firstIndex(of: "T") {
            let time = text[text.index(after: marker)...]
            if !time.hasSuffix("Z"), !time.contains("+"), !time.contains("-") {
                return """
                    Date '\(text)' has no time zone — add 'Z' for UTC, or an offset like +08:00
                    """
            }
        }
        return "Invalid ISO-8601 date string '\(text)'"
    }

    /// Parses `( value, value, ... )` argument lists for shell constructors.
    private mutating func parseArguments(min: Int, max: Int, name: String) throws -> [Primitive] {
        skipWhitespace()
        guard peek() == UInt8(ascii: "(") else {
            throw err("Expected '(' after \(name)")
        }
        pos += 1
        var args: [Primitive] = []
        skipWhitespace()
        if peek() == UInt8(ascii: ")") {
            pos += 1
        } else {
            while true {
                args.append(try parseValue())
                skipWhitespace()
                switch advance() {
                case UInt8(ascii: ","): continue
                case UInt8(ascii: ")"): break
                default: throw err("Expected ',' or ')' in \(name)(...)")
                }
                break
            }
        }
        guard args.count >= min, args.count <= max else {
            throw err("\(name)(...) takes \(min == max ? "\(min)" : "\(min)–\(max)") argument(s)")
        }
        return args
    }

    // MARK: - Regex literals

    private mutating func parseRegexLiteral() throws -> Primitive {
        let start = pos
        try expect("/")
        var pattern: [UInt8] = []
        while true {
            guard let c = advance() else { throw err("Unterminated regular expression literal") }
            if c == UInt8(ascii: "\\") {
                guard let e = advance() else { throw err("Unterminated escape in regex literal") }
                if e == UInt8(ascii: "/") {
                    // `\/` escapes the delimiter only; everything else stays verbatim.
                    pattern.append(e)
                } else {
                    pattern.append(c)
                    pattern.append(e)
                }
                continue
            }
            if c == UInt8(ascii: "/") { break }
            pattern.append(c)
        }
        var options = ""
        while let c = peek(), (0x61...0x7A).contains(c) {
            options.unicodeScalars.append(Unicode.Scalar(c))
            pos += 1
        }
        guard let patternString = String(bytes: pattern, encoding: .utf8) else {
            throw err("Invalid UTF-8 in regex literal")
        }
        return try makeRegularExpression(pattern: patternString, options: options, at: start)
    }

    private func makeRegularExpression(
        pattern: String, options: String, at offset: Int
    ) throws -> RegularExpression {
        let allowed = Set("ilmsux")
        guard options.allSatisfy({ allowed.contains($0) }) else {
            throw EJSONError("Invalid regex options '\(options)' (allowed: i l m s u x)", offset: offset)
        }
        guard !pattern.utf8.contains(0) else {
            throw EJSONError("Regex patterns must not contain NUL characters", offset: offset)
        }
        // BSON stores options alphabetized.
        return RegularExpression(pattern: pattern, options: String(options.sorted()))
    }

    // MARK: - Extended JSON type wrappers

    /// Keys reserved by Extended JSON v2 type wrappers. An object containing
    /// any of these must match a wrapper shape *exactly* or it is a parse
    /// error (per the spec and the official corpus). `$regex`/`$options` are
    /// deliberately absent — they double as query operators, which is why
    /// EJSON v2 renamed that wrapper to `$regularExpression`.
    private static let reservedWrapperKeys: Set<String> = [
        "$oid", "$date", "$numberInt", "$numberLong", "$numberDouble", "$numberDecimal",
        "$binary", "$uuid", "$code", "$scope", "$timestamp", "$regularExpression",
        "$minKey", "$maxKey", "$dbPointer", "$symbol", "$undefined",
    ]

    /// Returns a typed primitive when `pairs` form an Extended JSON type wrapper,
    /// nil when they are a plain document (e.g. query operators like `{$gt: 5}`).
    /// Malformed or extended wrappers throw.
    private mutating func convertTypeWrapper(_ pairs: [(String, Primitive)]) throws -> Primitive? {
        let keys = pairs.map(\.0)
        guard keys.contains(where: { Self.reservedWrapperKeys.contains($0) }) else {
            return nil
        }

        if pairs.count == 1 {
            let (key, value) = pairs[0]
            switch key {
            case "$oid":
                guard let hex = value as? String, let oid = ObjectId(hex) else {
                    throw err("$oid requires a 24-character hex string")
                }
                return oid
            case "$date":
                switch value {
                case let iso as String:
                    guard let date = ISO8601.parse(iso) else {
                        throw err("$date requires a valid ISO-8601 string")
                    }
                    return Self.exactDate(date)
                case let millis as Int:
                    // Produced by an inner {"$numberLong": "…"} wrapper.
                    return Self.exactDate(millis: millis)
                default:
                    throw err("$date requires an ISO-8601 string or {\"$numberLong\": …} millis")
                }
            case "$numberInt":
                guard let text = value as? String, let i32 = Int32(text) else {
                    throw err("$numberInt requires a 32-bit integer string")
                }
                return i32
            case "$numberLong":
                guard let text = value as? String, let i64 = Int(text) else {
                    throw err("$numberLong requires a 64-bit integer string")
                }
                return i64
            case "$numberDouble":
                guard let text = value as? String else {
                    throw err("$numberDouble requires a numeric string")
                }
                switch text {
                case "Infinity": return Double.infinity
                case "-Infinity": return -Double.infinity
                case "NaN": return Double.nan
                default:
                    guard !text.isEmpty, let d = Double(text) else {
                        throw err("$numberDouble requires a numeric string")
                    }
                    return d
                }
            case "$numberDecimal":
                guard let text = value as? String else {
                    throw err("$numberDecimal requires a numeric string")
                }
                return try Decimal128Codec.decimal128(parsing: text)
            case "$timestamp":
                guard let doc = value as? Document, !doc.isArray,
                    doc.keys.sorted() == ["i", "t"],
                    let t = timestampComponent(doc["t"]),
                    let i = timestampComponent(doc["i"])
                else {
                    throw err("$timestamp requires {\"t\": uint32, \"i\": uint32}")
                }
                return Timestamp(increment: Int32(bitPattern: i), timestamp: Int32(bitPattern: t))
            case "$regularExpression":
                guard let doc = value as? Document, !doc.isArray,
                    doc.keys.sorted() == ["options", "pattern"],
                    let pattern = doc["pattern"] as? String,
                    let options = doc["options"] as? String
                else {
                    throw err("$regularExpression requires {\"pattern\": string, \"options\": string}")
                }
                return try makeRegularExpression(pattern: pattern, options: options, at: pos)
            case "$code":
                guard let code = value as? String else { throw err("$code requires a string") }
                return JavaScriptCode(code)
            case "$minKey":
                guard isOne(value) else { throw err("$minKey requires the value 1") }
                return MinKey()
            case "$maxKey":
                guard isOne(value) else { throw err("$maxKey requires the value 1") }
                return MaxKey()
            case "$uuid":
                guard let text = value as? String, let uuid = UUID(uuidString: text) else {
                    throw err("$uuid requires a UUID string")
                }
                return makeBinary(subType: 0x04, data: withUnsafeBytes(of: uuid.uuid) { Data($0) })
            case "$binary":
                // v2 form: {"$binary": {"base64": "...", "subType": "hex"}}
                guard let doc = value as? Document, !doc.isArray,
                    doc.keys.sorted() == ["base64", "subType"],
                    let base64 = doc["base64"] as? String,
                    let subTypeHex = doc["subType"] as? String,
                    (1...2).contains(subTypeHex.count),
                    let subtype = UInt8(subTypeHex, radix: 16),
                    let data = Data(base64Encoded: base64)
                else {
                    throw err("$binary requires {\"base64\": string, \"subType\": hex string}")
                }
                return makeBinary(subType: subtype, data: data)
            case "$symbol", "$undefined", "$dbPointer":
                throw err("\(key) is a deprecated BSON type not supported by MongoHub Plus")
            default:
                break
            }
        }

        if pairs.count == 2 {
            // {"$code": "...", "$scope": {...}}
            if keys.sorted() == ["$code", "$scope"] {
                guard let code = pairs.first(where: { $0.0 == "$code" })?.1 as? String,
                    let scope = pairs.first(where: { $0.0 == "$scope" })?.1 as? Document,
                    !scope.isArray
                else {
                    throw err("$code with $scope requires a string and an object")
                }
                return JavaScriptCodeWithScope(code, scope: scope)
            }
            // Legacy v1 binary: {"$binary": "base64", "$type": "hex"}
            if keys.sorted() == ["$binary", "$type"] {
                guard let base64 = pairs.first(where: { $0.0 == "$binary" })?.1 as? String,
                    let subTypeHex = pairs.first(where: { $0.0 == "$type" })?.1 as? String,
                    (1...2).contains(subTypeHex.count),
                    let subtype = UInt8(subTypeHex, radix: 16),
                    let data = Data(base64Encoded: base64)
                else {
                    throw err("Legacy $binary requires base64 and a hex $type")
                }
                return makeBinary(subType: subtype, data: data)
            }
        }

        throw err("Invalid Extended JSON type wrapper: {\(keys.joined(separator: ", "))}")
    }

    /// $timestamp components must be plain (unsigned 32-bit) numbers.
    private func timestampComponent(_ value: Primitive?) -> UInt32? {
        switch value {
        case let i as Int32: return UInt32(exactly: i)
        case let i as Int: return UInt32(exactly: i)
        default: return nil
        }
    }

    // MARK: - Coercions

    private func isOne(_ value: Primitive) -> Bool {
        switch value {
        case let i as Int32: return i == 1
        case let i as Int: return i == 1
        case let d as Double: return d == 1
        default: return false
        }
    }

    private func coerceInt32(_ value: Primitive?) -> Int32? {
        switch value {
        case let i as Int32: return i
        case let i as Int: return Int32(exactly: i)
        case let d as Double: return Int32(exactly: d)
        case let s as String: return Int32(s)
        default: return nil
        }
    }

    private func coerceInt64(_ value: Primitive?) -> Int? {
        switch value {
        case let i as Int32: return Int(i)
        case let i as Int: return i
        case let d as Double: return Int(exactly: d)
        case let s as String: return Int(s)
        default: return nil
        }
    }

    private func coerceUInt32(_ value: Primitive?) -> UInt32? {
        switch value {
        case let i as Int32: return UInt32(exactly: i)
        case let i as Int: return UInt32(exactly: i)
        case let d as Double: return UInt32(exactly: d)
        case let s as String: return UInt32(s)
        default: return nil
        }
    }

    private func makeBinary(subType: UInt8, data: Data) -> Binary {
        var payload = data
        if subType == 0x02 {
            // Subtype 0x02 ("binary old") embeds an int32 length prefix in the
            // payload; Extended JSON base64 carries only the bare data.
            var prefixed = Data(capacity: data.count + 4)
            let count = UInt32(data.count)
            for i in 0..<4 { prefixed.append(UInt8(truncatingIfNeeded: count >> (8 * i))) }
            prefixed.append(data)
            payload = prefixed
        }
        return Binary(subType: Binary.SubType(rawSubType: subType), buffer: ByteBuffer(bytes: payload))
    }

    /// Builds a `Date` that survives the BSON library's truncating
    /// `Int(interval * 1000)` encoding *and* our own rounding read-back with
    /// the exact requested milliseconds: bias by a quarter millisecond toward
    /// the value so both truncation and rounding land on `millis`.
    static func exactDate(millis: Int) -> Date {
        let bias = millis < 0 ? -0.25 : 0.25
        return Date(timeIntervalSince1970: (Double(millis) + bias) / 1000)
    }

    static func exactDate(_ date: Date) -> Date {
        exactDate(millis: Int((date.timeIntervalSince1970 * 1000).rounded()))
    }
}

extension Binary.SubType {
    init(rawSubType byte: UInt8) {
        switch byte {
        case 0x00: self = .generic
        case 0x01: self = .function
        case 0x04: self = .uuid
        case 0x05: self = .md5
        default: self = .userDefined(byte)
        }
    }

    var rawSubType: UInt8 {
        switch self {
        case .generic: return 0x00
        case .function: return 0x01
        case .uuid: return 0x04
        case .md5: return 0x05
        case .userDefined(let byte): return byte
        }
    }
}

/// ISO-8601 parsing/formatting helpers shared by parser and serializer.
enum ISO8601 {
    // ISO8601DateFormatter is documented thread-safe, hence nonisolated(unsafe).
    nonisolated(unsafe) private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let dateOnly: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    nonisolated(unsafe) private static let withoutFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Full ISO-8601 timestamps only — what relaxed Extended JSON's `$date`
    /// requires, and what the official corpus tests. Never accepts a bare date.
    static func parse(_ text: String) -> Date? {
        withFraction.date(from: text) ?? withoutFraction.date(from: text)
    }

    /// The shell constructors additionally accept a bare `YYYY-MM-DD`, which
    /// both mongosh and the ECMAScript spec read as UTC midnight.
    ///
    /// The shape is checked before parsing on purpose: `.withFullDate` happily
    /// accepts `2026-01-01T10:00:00` and silently throws the time away, which
    /// would turn a precise query into a wrong one.
    static func parseShellDate(_ text: String) -> Date? {
        if let date = parse(text) { return date }
        guard isBareDate(text) else { return nil }
        return dateOnly.date(from: text)
    }

    /// Exactly `YYYY-MM-DD`.
    private static func isBareDate(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard bytes.count == 10 else { return false }
        for (offset, byte) in bytes.enumerated() {
            if offset == 4 || offset == 7 {
                guard byte == UInt8(ascii: "-") else { return false }
            } else {
                guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return false }
            }
        }
        return true
    }

    /// Formats with millisecond precision, UTC, trailing 'Z' — or without the
    /// fractional part when the date is on a whole second (relaxed-EJSON style).
    static func format(_ date: Date) -> String {
        let millis = (date.timeIntervalSince1970 * 1000).rounded()
        if millis.truncatingRemainder(dividingBy: 1000) == 0 {
            return withoutFraction.string(from: date)
        }
        return withFraction.string(from: date)
    }
}

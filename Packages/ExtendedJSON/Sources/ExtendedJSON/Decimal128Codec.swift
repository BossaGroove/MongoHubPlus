import BSON
import Foundation

/// String ↔ `Decimal128` conversion.
///
/// The BSON library's `Decimal128` is a storage-only stub (it round-trips the
/// 16 raw bytes but exposes no API), so this codec implements IEEE 754-2008
/// decimal128 (BID encoding) itself and smuggles values in/out of the library
/// type through raw BSON document bytes.
///
/// Parsing is **exact-only**: values that cannot be represented without
/// rounding are rejected with an error rather than silently rounded
/// (correctness over convenience — see docs/extended-json.md).
enum Decimal128Codec {
    private static let exponentBias = 6176
    private static let maxExponent = 6111  // unbiased, for a 34-digit coefficient
    private static let minExponent = -6176
    private static let maxCoefficient = UInt128Compat(decimal: "9999999999999999999999999999999999")!  // 10^34-1

    // MARK: - Bit access via raw BSON bytes

    /// Extracts (low, high) little-endian words from a `Decimal128` by writing
    /// it into a single-element BSON document.
    static func bits(of value: Decimal128) -> (low: UInt64, high: UInt64) {
        var doc = Document()
        doc["v"] = value
        let data = doc.makeData()
        // Layout: int32 length | 0x13 | "v\0" | 16 value bytes | 0x00
        precondition(data.count == 24, "unexpected decimal128 document layout")
        func word(_ offset: Int) -> UInt64 {
            var w: UInt64 = 0
            for i in (0..<8).reversed() {
                w = w << 8 | UInt64(data[offset + i])
            }
            return w
        }
        return (low: word(7), high: word(15))
    }

    /// Builds a `Decimal128` from (low, high) words by parsing a hand-built
    /// single-element BSON document.
    static func decimal128(low: UInt64, high: UInt64) -> Decimal128 {
        var bytes: [UInt8] = [24, 0, 0, 0, 0x13, UInt8(ascii: "v"), 0]
        for i in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: low >> (8 * i))) }
        for i in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: high >> (8 * i))) }
        bytes.append(0)
        let doc = Document(bytes: bytes)
        guard let value = doc["v"] as? Decimal128 else {
            preconditionFailure("failed to round-trip decimal128 bits through BSON")
        }
        return value
    }

    // MARK: - Decimal128 → String (canonical Extended JSON form)

    static func string(from value: Decimal128) -> String {
        let (low, high) = bits(of: value)
        let sign = high >> 63 == 1 ? "-" : ""

        let combinationTop2 = (high >> 61) & 0b11
        if combinationTop2 == 0b11 {
            let top5 = (high >> 58) & 0b11111
            if top5 == 0b11110 { return sign + "Infinity" }
            if top5 == 0b11111 { return "NaN" }
            // Coefficient starts with implicit 100_b + 1 bit → always exceeds
            // 10^34-1 → non-canonical, treated as zero coefficient.
            let biasedExponent = Int((high >> 47) & 0x3FFF)
            return format(sign: sign, coefficient: .zero, exponent: biasedExponent - exponentBias)
        }

        let biasedExponent = Int((high >> 49) & 0x3FFF)
        let coefficient = UInt128Compat(high: high & 0x1_FFFF_FFFF_FFFF, low: low)
        let canonical = coefficient > maxCoefficient ? .zero : coefficient
        return format(sign: sign, coefficient: canonical, exponent: biasedExponent - exponentBias)
    }

    /// IEEE 754-2008 "to scientific string" as used by canonical Extended JSON.
    private static func format(sign: String, coefficient: UInt128Compat, exponent: Int) -> String {
        let digits = coefficient.decimalString
        let adjusted = exponent + digits.count - 1
        if exponent <= 0 && adjusted >= -6 {
            // Plain notation.
            if exponent == 0 { return sign + digits }
            let pointPosition = digits.count + exponent
            if pointPosition > 0 {
                let idx = digits.index(digits.startIndex, offsetBy: pointPosition)
                return sign + digits[..<idx] + "." + digits[idx...]
            }
            return sign + "0." + String(repeating: "0", count: -pointPosition) + digits
        }
        // Exponential notation: d.ddd…E±X
        var mantissa = String(digits.first!)
        if digits.count > 1 {
            mantissa += "." + digits.dropFirst()
        }
        let expSign = adjusted < 0 ? "-" : "+"
        return sign + mantissa + "E" + expSign + String(abs(adjusted))
    }

    // MARK: - String → Decimal128 (exact-only)

    static func decimal128(parsing input: String) throws -> Decimal128 {
        var text = Substring(input)
        guard !text.isEmpty else { throw EJSONError("Empty decimal string") }

        var negative = false
        if text.first == "-" || text.first == "+" {
            negative = text.first == "-"
            text = text.dropFirst()
        }

        let lowered = text.lowercased()
        if lowered == "infinity" || lowered == "inf" {
            let signBit: UInt64 = negative ? 1 << 63 : 0
            return decimal128(low: 0, high: signBit | 0b11110 << 58)
        }
        if lowered == "nan" {
            return decimal128(low: 0, high: 0b11111 << 58)
        }

        // Split mantissa / exponent.
        var exponentPart = 0
        if let eIndex = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            let expText = text[text.index(after: eIndex)...]
            guard let exp = Int(expText) else {
                throw EJSONError("Invalid decimal exponent '\(expText)'")
            }
            exponentPart = exp
            text = text[..<eIndex]
        }

        var integerDigits = ""
        var fractionDigits = ""
        if let dot = text.firstIndex(of: ".") {
            integerDigits = String(text[..<dot])
            fractionDigits = String(text[text.index(after: dot)...])
        } else {
            integerDigits = String(text)
        }
        let allDigits = integerDigits + fractionDigits
        guard !allDigits.isEmpty, allDigits.allSatisfy(\.isNumber) else {
            throw EJSONError("Invalid decimal string '\(input)'")
        }

        var exponent = exponentPart - fractionDigits.count
        var digits = Substring(allDigits.drop(while: { $0 == "0" }))
        if digits.isEmpty { digits = "0" }

        // Too many significant digits: only exact zero-dropping is allowed.
        while digits.count > 34, digits.last == "0" {
            digits = digits.dropLast()
            exponent += 1
        }
        guard digits.count <= 34 else {
            throw EJSONError(
                "Decimal '\(input)' has more than 34 significant digits and would require rounding"
            )
        }

        guard var coefficient = UInt128Compat(decimal: digits) else {
            throw EJSONError("Invalid decimal string '\(input)'")
        }

        if coefficient.isZero {
            // A zero clamps freely to the representable exponent range.
            exponent = min(max(exponent, minExponent), maxExponent)
        } else {
            // Exponent too large: pad with zeros (clamping) while precision allows.
            while exponent > maxExponent, coefficient.decimalDigitCount < 34,
                let padded = coefficient.multipliedByTen()
            {
                coefficient = padded
                exponent -= 1
            }
            guard exponent <= maxExponent else {
                throw EJSONError("Decimal '\(input)' overflows the decimal128 range")
            }
            // Exponent too small: drop trailing zeros exactly, else it needs rounding.
            while exponent < minExponent, coefficient.dividedByTen().remainder == 0 {
                coefficient = coefficient.dividedByTen().quotient
                exponent += 1
            }
            guard exponent >= minExponent else {
                throw EJSONError(
                    "Decimal '\(input)' underflows decimal128 and would require rounding")
            }
        }

        let biased = UInt64(exponent + exponentBias)
        var high = biased << 49 | coefficient.high
        if negative { high |= 1 << 63 }
        return decimal128(low: coefficient.low, high: high)
    }
}

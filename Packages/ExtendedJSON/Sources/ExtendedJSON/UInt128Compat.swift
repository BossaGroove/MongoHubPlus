/// Minimal 128-bit unsigned integer for Decimal128 coefficients.
///
/// The stdlib `UInt128` requires a macOS 15 runtime; MongoHub Plus targets
/// macOS 14, so this provides exactly the operations Decimal128Codec needs:
/// decimal-string conversion both ways, ×10, ÷10 with remainder, comparison.
struct UInt128Compat: Comparable, Equatable {
    var high: UInt64
    var low: UInt64

    static let zero = UInt128Compat(high: 0, low: 0)

    init(high: UInt64, low: UInt64) {
        self.high = high
        self.low = low
    }

    var isZero: Bool { high == 0 && low == 0 }

    static func < (lhs: UInt128Compat, rhs: UInt128Compat) -> Bool {
        (lhs.high, lhs.low) < (rhs.high, rhs.low)
    }

    /// Parses a decimal digit string. Returns nil on overflow or non-digits.
    init?(decimal: some StringProtocol) {
        var value = UInt128Compat.zero
        var sawDigit = false
        for c in decimal.utf8 {
            guard (0x30...0x39).contains(c) else { return nil }
            sawDigit = true
            guard let times10 = value.multipliedByTen() else { return nil }
            value = times10
            let (sum, overflow) = value.low.addingReportingOverflow(UInt64(c - 0x30))
            value.low = sum
            if overflow {
                let (h, hOverflow) = value.high.addingReportingOverflow(1)
                guard !hOverflow else { return nil }
                value.high = h
            }
        }
        guard sawDigit else { return nil }
        self = value
    }

    /// Returns self × 10, or nil on 128-bit overflow.
    func multipliedByTen() -> UInt128Compat? {
        let (lowHigh, lowLow) = low.multipliedFullWidth(by: 10)
        let (highHigh, highLow) = high.multipliedFullWidth(by: 10)
        guard highHigh == 0 else { return nil }
        let (newHigh, overflow) = highLow.addingReportingOverflow(lowHigh)
        guard !overflow else { return nil }
        return UInt128Compat(high: newHigh, low: lowLow)
    }

    /// Returns (self / 10, self % 10).
    func dividedByTen() -> (quotient: UInt128Compat, remainder: UInt64) {
        let qHigh = high / 10
        let rHigh = high % 10
        // dividend = rHigh·2^64 + low, guaranteed < 10·2^64 so quotient fits.
        let (qLow, remainder) = UInt64(10).dividingFullWidth((high: rHigh, low: low))
        return (UInt128Compat(high: qHigh, low: qLow), remainder)
    }

    var decimalString: String {
        if isZero { return "0" }
        var digits: [UInt8] = []
        var value = self
        while !value.isZero {
            let (q, r) = value.dividedByTen()
            digits.append(UInt8(r) + 0x30)
            value = q
        }
        return String(bytes: digits.reversed(), encoding: .utf8)!
    }

    var decimalDigitCount: Int {
        if isZero { return 1 }
        var count = 0
        var value = self
        while !value.isZero {
            value = value.dividedByTen().quotient
            count += 1
        }
        return count
    }
}

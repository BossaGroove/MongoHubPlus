import BSON
import Foundation
import Testing
@testable import ExtendedJSON

/// The results outline's compact Value column (docs/extended-json.md §5).
struct BSONDisplayDateTests {
    // 2026-11-08T17:30:00Z
    let instant = Date(timeIntervalSince1970: 1_794_159_000)

    @Test func dateShowsLocalTimeWithItsOffset() throws {
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        #expect(BSONDisplay.dateString(instant, timeZone: tokyo) == "2026-11-09 02:30:00 +09:00")
    }

    @Test func utcSpellsItsOffsetOut() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        #expect(BSONDisplay.dateString(instant, timeZone: utc) == "2026-11-08 17:30:00 +00:00")
    }

    @Test func negativeAndHalfHourOffsets() throws {
        let stJohns = try #require(TimeZone(identifier: "America/St_Johns"))
        #expect(BSONDisplay.dateString(instant, timeZone: stJohns) == "2026-11-08 14:00:00 -03:30")
    }

    @Test func valueStringUsesTheCurrentZone() {
        #expect(BSONDisplay.valueString(instant) == BSONDisplay.dateString(instant, timeZone: .current))
    }
}

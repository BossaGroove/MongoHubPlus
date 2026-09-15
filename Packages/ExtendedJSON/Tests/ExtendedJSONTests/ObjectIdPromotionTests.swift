import BSON
import Testing

@testable import ExtendedJSON

/// Promoting 24-hex string values to `ObjectId(…)` in criteria text
/// (docs/extended-json.md §3.1, feature-spec 3.3).
struct ObjectIdPromotionTests {
    private let hex = "5f50a10dff1ce7314da050ca"
    private let otherHex = "607aa247a8cadb7445b97fa4"

    private func promote(_ input: String) -> String {
        QueryNormalizer.promotingObjectIds(input)
    }

    @Test func promotesAValue() {
        #expect(promote("{user_id: '\(hex)'}") == "{user_id: ObjectId('\(hex)')}")
        #expect(promote("{\"user_id\": \"\(hex)\"}") == "{\"user_id\": ObjectId(\"\(hex)\")}")
    }

    /// The rewritten text goes back into the user's own field, so anything
    /// not promoted has to come out character for character.
    @Test func leavesEverythingElseAlone() {
        let input = "{ user_id : '\(hex)' ,  n: 1, when: ISODate('2024-01-01'), ok: true }"
        let expected =
            "{ user_id : ObjectId('\(hex)') ,  n: 1, when: ISODate('2024-01-01'), ok: true }"
        #expect(promote(input) == expected)
    }

    @Test func keysAreNeverPromoted() {
        #expect(promote("{\"\(hex)\": 1}") == "{\"\(hex)\": 1}")
        #expect(promote("{ '\(hex)' : 1 }") == "{ '\(hex)' : 1 }")
    }

    @Test func promotesNestedObjectsAndArrays() {
        #expect(
            promote("{outer: {inner: '\(hex)'}}") == "{outer: {inner: ObjectId('\(hex)')}}")
        #expect(
            promote("{site_ids: ['\(hex)', '\(otherHex)']}")
                == "{site_ids: [ObjectId('\(hex)'), ObjectId('\(otherHex)')]}")
        #expect(
            promote("{user_id: {$in: ['\(hex)']}}") == "{user_id: {$in: [ObjectId('\(hex)')]}}")
    }

    /// Comparison operators are how id pagination is written; they promote.
    @Test func promotesUnderComparisonOperators() {
        #expect(promote("{_id: {$gt: '\(hex)'}}") == "{_id: {$gt: ObjectId('\(hex)')}}")
        #expect(promote("{user_id: {$ne: '\(hex)'}}") == "{user_id: {$ne: ObjectId('\(hex)')}}")
    }

    @Test func alreadyWrappedIsUntouched() {
        let wrapped = "{user_id: ObjectId('\(hex)')}"
        #expect(promote(wrapped) == wrapped)
    }

    @Test func isIdempotent() {
        let once = promote("{user_id: '\(hex)', ids: ['\(otherHex)']}")
        #expect(promote(once) == once)
    }

    @Test func constructorArgumentsAreUntouched() {
        for input in [
            "{when: ISODate('\(hex)')}",
            "{u: UUID('\(hex)')}",
            "{n: NumberLong('\(hex)')}",
            "{b: BinData(0, '\(hex)')}",
        ] {
            #expect(promote(input) == input)
        }
    }

    /// Wrapping these would change what the query means, or produce
    /// Extended JSON that no longer parses.
    @Test func stringValuedOperatorsAreUntouched() {
        for key in ["$regex", "$options", "$where", "$oid", "$date", "$uuid", "$numberLong"] {
            let input = "{f: {\(key): '\(hex)'}}"
            #expect(promote(input) == input)
        }
        let regularExpression =
            "{f: {\"$regularExpression\": {\"pattern\": \"\(hex)\", \"options\": \"i\"}}}"
        #expect(promote(regularExpression) == regularExpression)
        let binary = "{f: {\"$binary\": {\"base64\": \"\(hex)\", \"subType\": \"00\"}}}"
        #expect(promote(binary) == binary)
    }

    @Test func nonObjectIdStringsAreUntouched() {
        for value in [
            "5f50a10dff1ce7314da050c",  // 23
            "5f50a10dff1ce7314da050caa",  // 25
            "5f50a10dff1ce7314da050cz",  // not hex
            "ecn hotel only, all permission",
            "",
        ] {
            let input = "{f: '\(value)'}"
            #expect(promote(input) == input)
        }
    }

    @Test func uppercaseHexPromotes() throws {
        let upper = hex.uppercased()
        let promoted = promote("{user_id: \"\(upper)\"}")
        #expect(promoted == "{user_id: ObjectId(\"\(upper)\")}")
        let document = try ExtendedJSON.parseDocument(promoted)
        #expect(document["user_id"] is ObjectId)
    }

    @Test func escapedQuotesDoNotDerailTheScan() {
        let input = "{note: \"he said \\\"hi\\\"\", user_id: '\(hex)'}"
        let expected = "{note: \"he said \\\"hi\\\"\", user_id: ObjectId('\(hex)')}"
        #expect(promote(input) == expected)
    }

    /// Half-typed input is left for the parser to complain about.
    @Test func unterminatedStringIsLeftAlone() {
        let input = "{user_id: '\(hex)"
        #expect(promote(input) == input)
    }

    @Test func emptyAndBraceless() {
        #expect(promote("") == "")
        #expect(promote("user_id: '\(hex)'") == "user_id: ObjectId('\(hex)')")
    }

    /// What the criteria field actually does: normalize, then promote.
    @Test func normalizeThenPromoteParsesToObjectIds() throws {
        let normalized = QueryNormalizer.normalizeCriteria("user_id: '\(hex)'", emptyIsValid: false)
        let promoted = promote(normalized)
        #expect(promoted == "{user_id: ObjectId('\(hex)')}")

        let document = try ExtendedJSON.parseDocument(promoted)
        #expect((document["user_id"] as? ObjectId)?.hexString == hex)
    }

    /// The bare-id shortcut already emits ObjectId(…); promotion must not
    /// double-wrap it.
    @Test func bareIdShortcutSurvives() throws {
        let normalized = QueryNormalizer.normalizeCriteria(hex, emptyIsValid: false)
        let promoted = promote(normalized)
        #expect(promoted == "{_id: ObjectId(\"\(hex)\")}")
        let document = try ExtendedJSON.parseDocument(promoted)
        #expect((document["_id"] as? ObjectId)?.hexString == hex)
    }

    @Test func promotedTextParsesForEveryShape() throws {
        for input in [
            "{user_id: '\(hex)'}",
            "{site_ids: ['\(hex)', '\(otherHex)']}",
            "{user_id: {$in: ['\(hex)']}}",
            "{a: {b: {c: \"\(hex)\"}}}",
            "{_id: {$gt: '\(hex)'}}",
        ] {
            _ = try ExtendedJSON.parseDocument(promote(input))
        }
    }
}

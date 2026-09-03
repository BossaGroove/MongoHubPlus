import Testing

@testable import ExtendedJSON

/// Every shorthand shown in the public README must actually parse.
@Test func readmeShorthandExamplesParse() throws {
    let examples = [
        "{ _id: ObjectId('6a96d7fee80fb3561ff545e9'), price: NumberDecimal('42.95') }",
        "{ a: ObjectId('6a96d7fee80fb3561ff545e9') }",
        "{ a: ISODate('2026-01-01T00:00:00Z') }",
        "{ a: new Date(1767225600000) }",
        "{ a: NumberInt(7) }",
        "{ a: NumberLong('9007199254740993') }",
        "{ a: NumberDecimal('42.95') }",
        "{ a: /^mongo/i }",
        "{ a: RegExp('^mongo', 'i') }",
        "{ a: BinData(0, 'SGVsbG8=') }",
        "{ a: UUID('123e4567-e89b-12d3-a456-426614174000') }",
        "{ a: Timestamp(1699999999, 1) }",
        "{ a: Code('function () { return 1 }') }",
        "{ a: MinKey(), b: MaxKey(), c: NaN, d: Infinity }",
        "{ price: { $gt: NumberDecimal('20') }, published: { $lt: ISODate('2000-01-01T00:00:00Z') } }",
        #"{"_id": {"$oid": "6a96d7fee80fb3561ff545e9"}, "price": {"$numberDecimal": "42.95"}}"#,
    ]
    for example in examples {
        #expect(throws: Never.self, "README example failed: \(example)") {
            _ = try ExtendedJSON.parseDocument(example)
        }
    }
}

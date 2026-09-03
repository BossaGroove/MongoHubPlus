import Testing

@testable import ExtendedJSON

/// The public README's "Writing queries" table documents each shorthand
/// alongside the Extended JSON it corresponds to. These are those exact
/// pairs: if the parser or serializer changes, the README is now wrong and
/// this test says so.
@Test func readmeShorthandTableMatchesSerializer() throws {
    let pairs: [(shorthand: String, extendedJSON: String)] = [
        ("ObjectId('6a96d7fee80fb3561ff545e9')", #"{"$oid":"6a96d7fee80fb3561ff545e9"}"#),
        ("ISODate('2026-01-01T00:00:00Z')", #"{"$date":"2026-01-01T00:00:00Z"}"#),
        ("new Date(1767225600000)", #"{"$date":"2026-01-01T00:00:00Z"}"#),
        ("NumberInt(7)", "7"),
        ("NumberLong('9007199254740993')", #"{"$numberLong":"9007199254740993"}"#),
        ("NumberDecimal('42.95')", #"{"$numberDecimal":"42.95"}"#),
        ("/^mongo/i", #"{"$regularExpression":{"pattern":"^mongo","options":"i"}}"#),
        ("RegExp('^mongo', 'i')", #"{"$regularExpression":{"pattern":"^mongo","options":"i"}}"#),
        ("BinData(0, 'SGVsbG8=')", #"{"$binary":{"base64":"SGVsbG8=","subType":"00"}}"#),
        (
            "UUID('123e4567-e89b-12d3-a456-426614174000')",
            #"{"$binary":{"base64":"Ej5FZ+ibEtOkVkJmFBdAAA==","subType":"04"}}"#
        ),
        ("Timestamp(1699999999, 1)", #"{"$timestamp":{"t":1699999999,"i":1}}"#),
        ("Code('function () { return 1 }')", #"{"$code":"function () { return 1 }"}"#),
        ("MinKey()", #"{"$minKey":1}"#),
        ("MaxKey()", #"{"$maxKey":1}"#),
        ("NaN", #"{"$numberDouble":"NaN"}"#),
        ("Infinity", #"{"$numberDouble":"Infinity"}"#),
    ]
    let format = EJSONFormat(mode: .editor, pretty: false)
    for pair in pairs {
        let document = try ExtendedJSON.parseDocument("{ a: \(pair.shorthand) }")
        let value = try #require(document["a"], "\(pair.shorthand) parsed to nothing")
        #expect(
            try ExtendedJSON.stringifyValue(value, format: format) == pair.extendedJSON,
            "README row is wrong for \(pair.shorthand)")
    }
}

/// The longer examples in the same section must parse too.
@Test func readmeCompoundExamplesParse() throws {
    let examples = [
        "{ _id: ObjectId('6a96d7fee80fb3561ff545e9'), price: NumberDecimal('42.95') }",
        "{ price: { $gt: NumberDecimal('20') }, published: { $lt: ISODate('2000-01-01T00:00:00Z') } }",
        #"{"_id": {"$oid": "6a96d7fee80fb3561ff545e9"}, "price": {"$numberDecimal": "42.95"}}"#,
    ]
    for example in examples {
        #expect(throws: Never.self, "README example failed: \(example)") {
            _ = try ExtendedJSON.parseDocument(example)
        }
    }
}

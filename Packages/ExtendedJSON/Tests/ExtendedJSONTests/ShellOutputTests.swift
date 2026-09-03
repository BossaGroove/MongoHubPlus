import BSON
import Foundation
import NIOCore
import Testing

@testable import ExtendedJSON

/// Shell mode is a display format, so its one hard requirement is that it
/// round-trips: whatever it prints must parse back to the identical BSON, or
/// the document editor's round-trip check would block every save.
@Suite struct ShellOutputTests {
    private func shell(_ document: Document) throws -> String {
        try ExtendedJSON.stringify(document, format: EJSONFormat(mode: .shell, pretty: false))
    }

    private func roundTrips(_ document: Document, _ comment: Comment? = nil) throws {
        let text = try shell(document)
        let parsed = try ExtendedJSON.parseDocument(text)
        #expect(parsed.makeData() == document.makeData(), comment ?? "\(text)")
    }

    @Test func everyBSONTypeRoundTrips() throws {
        var document = Document()
        document["objectId"] = ObjectId("6a96d7fee80fb3561ff545e9")
        document["string"] = "The Pragmatic Programmer"
        document["int32"] = Int32(7)
        document["int64"] = Int(9_007_199_254_740_993)
        document["double"] = 42.5
        document["nan"] = Double.nan
        document["infinity"] = Double.infinity
        document["negativeInfinity"] = -Double.infinity
        document["decimal"] = try Decimal128Codec.decimal128(parsing: "42.95")
        document["bool"] = true
        document["null"] = Null()
        document["date"] = Date(timeIntervalSince1970: 941_673_600)
        document["timestamp"] = Timestamp(increment: 1, timestamp: 1_699_999_999)
        document["minKey"] = MinKey()
        document["maxKey"] = MaxKey()
        document["code"] = JavaScriptCode("function () { return 1 }")
        document["array"] = ["a", "b"] as Document
        document["nested"] = ["deep": ["deeper": Int32(1)] as Document] as Document
        try roundTrips(document)
    }

    @Test func nanRendersAsAJavaScriptLiteral() throws {
        var document = Document()
        document["a"] = Double.nan
        #expect(try shell(document) == "{a:NaN}")
    }

    @Test func typedValuesUseConstructors() throws {
        var document = Document()
        document["_id"] = ObjectId("6a96d7fee80fb3561ff545e9")
        document["price"] = try Decimal128Codec.decimal128(parsing: "42.95")
        #expect(
            try shell(document)
                == "{_id:ObjectId('6a96d7fee80fb3561ff545e9'),price:NumberDecimal('42.95')}")
    }

    @Test func int64IsQuotedUnlikeLegacyMongoHub() throws {
        var document = Document()
        document["a"] = Int(9_007_199_254_740_993)
        #expect(try shell(document) == "{a:NumberLong('9007199254740993')}")
        try roundTrips(document)
    }

    @Test func keysAreBareOnlyWhenPlainIdentifiers() throws {
        var document = Document()
        document["plain"] = Int32(1)
        document["with space"] = Int32(2)
        document["with-dash"] = Int32(3)
        document["1leading"] = Int32(4)
        document["$gt"] = Int32(5)
        let text = try shell(document)
        #expect(text.contains("plain:"))
        #expect(text.contains("'with space':"))
        #expect(text.contains("'with-dash':"))
        #expect(text.contains("'1leading':"))
        #expect(text.contains("'$gt':"), "a bare $key could re-parse as a wrapper")
        try roundTrips(document)
    }

    @Test func stringsUseSingleQuotesAndEscapeThem() throws {
        var document = Document()
        document["a"] = "it's"
        document["b"] = "say \"hi\""
        document["c"] = "back\\slash"
        #expect(try shell(document).contains(#"'it\'s'"#))
        try roundTrips(document)
    }

    @Test func regexUsesALiteralWhenItIsSafe() throws {
        var document = Document()
        document["a"] = RegularExpression(pattern: "^mongo", options: "i")
        #expect(try shell(document) == "{a:/^mongo/i}")
        try roundTrips(document)
    }

    @Test func regexFallsBackToTheConstructor() throws {
        var withSlash = Document()
        withSlash["a"] = RegularExpression(pattern: "a/b", options: "")
        #expect(try shell(withSlash) == "{a:RegExp('a/b')}")
        try roundTrips(withSlash)

        var empty = Document()
        empty["a"] = RegularExpression(pattern: "", options: "")
        #expect(try shell(empty).contains("RegExp("))
        try roundTrips(empty)
    }

    @Test func uuidPrintsAsUUIDAndOtherBinaryAsBinData() throws {
        var document = Document()
        let uuid = UUID(uuidString: "123e4567-e89b-12d3-a456-426614174000")!
        let bytes = withUnsafeBytes(of: uuid.uuid) { Data($0) }
        document["uuid"] = Binary(subType: .uuid, buffer: ByteBuffer(bytes: bytes))
        document["blob"] = Binary(subType: .generic, buffer: ByteBuffer(bytes: Data("Hello".utf8)))
        let text = try shell(document)
        #expect(text.contains("UUID('123e4567-e89b-12d3-a456-426614174000')"))
        #expect(text.contains("BinData(0, 'SGVsbG8=')"))
        try roundTrips(document)
    }

    @Test func datesOutsideTheISORangeUseMillis() throws {
        var document = Document()
        document["a"] = Date(timeIntervalSince1970: -86_400)  // 1969
        let text = try shell(document)
        #expect(text.contains("new Date("))
        try roundTrips(document)
    }

    @Test func codeWithScopeRoundTrips() throws {
        var scope = Document()
        scope["x"] = Int32(1)
        var document = Document()
        document["a"] = JavaScriptCodeWithScope("function () { return x }", scope: scope)
        #expect(try shell(document).contains("Code('function () { return x }', {x:1})"))
        try roundTrips(document)
    }

    @Test func prettyOutputRoundTripsToo() throws {
        var document = Document()
        document["_id"] = ObjectId("6a96d7fee80fb3561ff545e9")
        document["tags"] = ["a", "b"] as Document
        let text = try ExtendedJSON.stringify(document, format: .shell)
        let parsed = try ExtendedJSON.parseDocument(text)
        #expect(parsed.makeData() == document.makeData())
    }
}

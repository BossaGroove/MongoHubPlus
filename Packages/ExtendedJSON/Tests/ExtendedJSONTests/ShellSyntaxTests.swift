import BSON
import Foundation
import Testing

@testable import ExtendedJSON

/// mongosh / Compass-style input conveniences (docs/extended-json.md §1.3).
struct ShellSyntaxTests {
    func parse(_ json: String) throws -> Document {
        try ExtendedJSON.parseDocument(json)
    }

    @Test func unquotedAndSingleQuotedKeys() throws {
        let doc = try parse("{name: 1, 'single': 2, \"double\": 3, $op: 4, _u: 5, 42: 6}")
        #expect(doc.keys == ["name", "single", "double", "$op", "_u", "42"])
    }

    @Test func digitLeadingKeyMustBeAllDigits() {
        #expect(throws: (any Error).self) { try self.parse("{123abc: 1}") }
    }

    @Test func objectId() throws {
        let doc = try parse(#"{_id: ObjectId("57e193d7a9cc81b4027498b5")}"#)
        #expect((doc["_id"] as? ObjectId)?.hexString == "57e193d7a9cc81b4027498b5")
        #expect(throws: (any Error).self) { try self.parse(#"{_id: ObjectId("zzz")}"#) }
    }

    @Test func dates() throws {
        let millis = 1_356_351_330_501
        for input in [
            "{d: new Date(\(millis))}",
            "{d: Date(\(millis))}",
            #"{d: ISODate("2012-12-24T12:15:30.501Z")}"#,
            #"{d: new Date("2012-12-24T12:15:30.501Z")}"#,
            #"{d: ISODate("2012-12-24T13:15:30.501+01:00")}"#,
        ] {
            let doc = try parse(input)
            var check = Document()
            check["d"] = doc["d"]
            let reparsed = try ExtendedJSON.parseDocument(
                try ExtendedJSON.stringify(check, format: .canonical))
            let text = try ExtendedJSON.stringify(reparsed, format: .canonical)
            #expect(text.contains("\"\(millis)\""), "input: \(input) → \(text)")
        }
    }

    @Test func numberConstructors() throws {
        let doc = try parse(#"{a: NumberInt(7), b: NumberLong(7), c: NumberLong("7"), d: NumberDecimal("1.5")}"#)
        #expect(doc["a"] as? Int32 == 7)
        #expect(doc["b"] as? Int == 7)
        #expect(doc["c"] as? Int == 7)
        #expect(doc["d"] is Decimal128)
    }

    @Test func numberTyping() throws {
        let doc = try parse("{i: 5, big: 5000000000, f: 5.0, e: 1e3, huge: 99999999999999999999}")
        #expect(doc["i"] as? Int32 == 5)
        #expect(doc["big"] as? Int == 5_000_000_000)
        #expect(doc["f"] as? Double == 5.0)
        #expect(doc["e"] as? Double == 1000.0)
        #expect(doc["huge"] as? Double == 1e20)
    }

    @Test func binDataAndUUID() throws {
        let doc = try parse(#"{b: BinData(0, "//8="), u: UUID("73ffd264-44b3-4c69-90e8-e7d1dfc035d4")}"#)
        #expect((doc["b"] as? Binary)?.data == Data([0xFF, 0xFF]))
        #expect((doc["u"] as? Binary)?.subType.rawSubType == 0x04)
    }

    @Test func timestampAndKeys() throws {
        let doc = try parse("{t: Timestamp(123456789, 42), min: MinKey, max: MaxKey(), n: null}")
        let t = try #require(doc["t"] as? Timestamp)
        #expect(UInt32(bitPattern: t.timestamp) == 123_456_789)
        #expect(UInt32(bitPattern: t.increment) == 42)
        #expect(doc["min"] is MinKey)
        #expect(doc["max"] is MaxKey)
        #expect(doc["n"] is Null)
    }

    @Test func regexLiterals() throws {
        let doc = try parse(#"{r: /a\d+\/b/im}"#)
        let r = try #require(doc["r"] as? RegularExpression)
        #expect(r.pattern == #"a\d+/b"#)
        #expect(r.options == "im")
        #expect(throws: (any Error).self) { try self.parse("{r: /abc/z}") }
    }

    @Test func specialDoubles() throws {
        let doc = try parse("{a: Infinity, b: -Infinity, c: NaN}")
        #expect(doc["a"] as? Double == .infinity)
        #expect(doc["b"] as? Double == -.infinity)
        #expect((doc["c"] as? Double)?.isNaN == true)
    }

    @Test func codeConstructor() throws {
        let doc = try parse(#"{f: Code("function() {}"), g: Code("x", {a: 1})}"#)
        #expect((doc["f"] as? JavaScriptCode)?.code == "function() {}")
        #expect((doc["g"] as? JavaScriptCodeWithScope)?.code == "x")
    }

    @Test func trailingCommasTolerated() throws {
        let doc = try parse("{a: 1, b: [1, 2,], }")
        #expect(doc["a"] as? Int32 == 1)
        #expect((doc["b"] as? Document)?.count == 2)
    }

    @Test func unsupportedDeprecatedTypes() {
        for input in [
            "{s: Symbol(\"x\")}", "{u: undefined}", "{p: DBPointer(\"c\", \"57e193d7a9cc81b4027498b5\")}",
            "{s: {\"$symbol\": \"x\"}}", "{u: {\"$undefined\": true}}",
            "{f: Function(\"x\")}", "{f: ScopeFunction(\"x\", {})}",
        ] {
            #expect(throws: (any Error).self, "should reject: \(input)") {
                try self.parse(input)
            }
        }
    }

    @Test func queryOperatorsPassThrough() throws {
        let doc = try parse(#"{age: {$gt: 21, $lt: 65}, name: {$regex: "^a", $options: "i"}}"#)
        let age = try #require(doc["age"] as? Document)
        #expect(age["$gt"] as? Int32 == 21)
        let name = try #require(doc["name"] as? Document)
        #expect(name["$regex"] as? String == "^a")  // NOT converted to a regex value
    }

    @Test func editorModeTypeFidelity() throws {
        var doc = Document()
        doc["i32"] = Int32(5)
        doc["i64"] = 5
        doc["dbl"] = 5.0
        doc["nan"] = Double.nan
        let text = try ExtendedJSON.stringify(doc, format: .editor)
        #expect(text.contains("\"i32\": 5"))
        #expect(text.contains("$numberLong"))
        #expect(text.contains("5.0"))
        #expect(text.contains("$numberDouble"))
        #expect(ExtendedJSON.verifyRoundTrip(doc) == .lossless)
    }

    @Test func keyOrderModes() throws {
        let doc = try parse("{b: 1, a: 2, c: 3}")
        let document = try ExtendedJSON.stringify(doc, format: .init(mode: .editor))
        let ascending = try ExtendedJSON.stringify(doc, format: .init(mode: .editor, keyOrder: .ascending))
        #expect(document == #"{"b":1,"a":2,"c":3}"#)
        #expect(ascending == #"{"a":2,"b":1,"c":3}"#)
    }

    @Test func topLevelArray() throws {
        let doc = try parse("[{a: 1}, {a: 2}]")
        #expect(doc.isArray)
        #expect(doc.count == 2)
    }
}

/// The "type an id, get a query" shortcut (docs/extended-json.md §3).
struct QueryNormalizerTests {
    @Test func bareObjectId() {
        #expect(
            QueryNormalizer.normalizeCriteria("57e193d7a9cc81b4027498b5")
                == "{_id: ObjectId(\"57e193d7a9cc81b4027498b5\")}")
        #expect(
            QueryNormalizer.normalizeCriteria("\"57e193d7a9cc81b4027498b5\"")
                == "{_id: ObjectId(\"57e193d7a9cc81b4027498b5\")}")
    }

    @Test func normalizedFormsParse() throws {
        for input in [
            "57e193d7a9cc81b4027498b5",
            "ObjectId(\"57e193d7a9cc81b4027498b5\")",
            "{status: \"active\"}",
            "status: \"active\"",
            "\"some-id\"",
            "plain-text-id",
            "{\"$oid\": \"57e193d7a9cc81b4027498b5\"}",
        ] {
            let normalized = QueryNormalizer.normalizeCriteria(input)
            _ = try ExtendedJSON.parseDocument(normalized)  // must be valid
        }
    }

    @Test func emptyInput() {
        #expect(QueryNormalizer.normalizeCriteria("") == "")
        #expect(QueryNormalizer.normalizeCriteria("  ", emptyIsValid: false) == "{}")
    }

    @Test func braceInputPassesThrough() {
        #expect(QueryNormalizer.normalizeCriteria("{a: 1}") == "{a: 1}")
        #expect(
            QueryNormalizer.normalizeCriteria("{\"$oid\": \"57e193d7a9cc81b4027498b5\"}")
                == "{_id: {\"$oid\": \"57e193d7a9cc81b4027498b5\"}}")
    }
}

/// Value-level serialize/parse round trips (in-place value editor).
struct StringifyValueTests {
    @Test func scalarRoundTrips() throws {
        let cases: [Primitive] = [
            "hello", Int32(7), 5_000_000_000, 2.5, true,
            ObjectId(), Date(timeIntervalSince1970: 1_600_000_000),
        ]
        for value in cases {
            let text = try ExtendedJSON.stringifyValue(value, format: .editor)
            let reparsed = try ExtendedJSON.parseValue(text)
            var a = Document(); a["v"] = value
            var b = Document(); b["v"] = reparsed
            #expect(a.makeData() == b.makeData(), "lossy: \(text)")
        }
    }

    @Test func inlineEditorFormatIsSingleLineParseable() throws {
        var doc = Document()
        doc["n"] = Int32(1)
        let text = try ExtendedJSON.stringifyValue(
            doc, format: EJSONFormat(mode: .editor, pretty: false))
        #expect(!text.contains("\n"))
        _ = try ExtendedJSON.parseValue(text)
    }
}

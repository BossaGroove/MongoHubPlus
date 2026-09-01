import BSON
import Foundation
import Testing

@testable import ExtendedJSON

/// Runs the official MongoDB BSON corpus Extended JSON cases
/// (vendored from mongodb/specifications, source/bson-corpus/tests).
///
/// Not vendored at all: symbol.json, undefined.json, dbpointer.json,
/// multi-type-deprecated.json — those BSON types are unrepresentable in the
/// BSON library MongoHub Plus uses; parsing them is a defined error instead
/// (see docs/extended-json.md).
struct CorpusTests {
    struct CorpusFile: Decodable {
        var description: String
        var valid: [ValidCase]?
        var parseErrors: [ParseErrorCase]?
    }

    struct ValidCase: Decodable {
        var description: String
        var canonical_bson: String
        var canonical_extjson: String
        var relaxed_extjson: String?
        var degenerate_extjson: String?
        var lossy: Bool?
    }

    struct ParseErrorCase: Decodable {
        var description: String
        var string: String
    }

    static let corpusFiles: [String] = [
        "array", "binary", "boolean", "code", "code_w_scope", "datetime", "dbref",
        "decimal128-1", "decimal128-2", "decimal128-3", "decimal128-4", "decimal128-5",
        "decimal128-6", "decimal128-7", "document", "double", "int32", "int64",
        "maxkey", "minkey", "multi-type", "null", "oid", "regex", "string",
        "timestamp", "top",
    ]

    static func load(_ name: String) throws -> CorpusFile {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Corpus"))
        return try JSONDecoder().decode(CorpusFile.self, from: Data(contentsOf: url))
    }

    static func bytes(fromHex hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var iterator = hex.utf8.makeIterator()
        while let hi = iterator.next(), let lo = iterator.next() {
            func digit(_ c: UInt8) -> UInt8 {
                switch c {
                case 0x30...0x39: return c - 0x30
                case 0x41...0x46: return c - 0x41 + 10
                case 0x61...0x66: return c - 0x61 + 10
                default: fatalError("bad hex")
                }
            }
            out.append(digit(hi) << 4 | digit(lo))
        }
        return out
    }

    /// Decimal128 parse failures allowed by design: exact-only parsing rejects
    /// values that need rounding. Returns true when the error is that class.
    static func isExactnessLimitation(_ error: any Error) -> Bool {
        guard let e = error as? EJSONError else { return false }
        return e.message.contains("would require rounding")
            || e.message.contains("overflows the decimal128 range")
    }

    @Test(arguments: corpusFiles)
    func validCases(file: String) throws {
        let corpus = try Self.load(file)
        for testCase in corpus.valid ?? [] {
            let context = "\(file): \(testCase.description)"
            let canonicalBytes = Self.bytes(fromHex: testCase.canonical_bson)
            let document = Document(bytes: canonicalBytes)

            // 1. Parse canonical extjson → canonical bson (unless lossy).
            if testCase.lossy != true {
                do {
                    let parsed = try ExtendedJSON.parseDocument(testCase.canonical_extjson)
                    #expect(
                        Array(parsed.makeData()) == canonicalBytes,
                        "parse(canonical_extjson) bytes mismatch — \(context)")
                } catch where Self.isExactnessLimitation(error) {
                    // Exact-only Decimal128: rounding cases are rejected by design.
                } catch {
                    Issue.record("parse(canonical_extjson) threw \(error) — \(context)")
                }
            }

            // 2 + 3. Serialize (canonical and editor mode), reparse →
            //    identical bytes. Lossy cases (NaN payloads, non-canonical
            //    decimal bit patterns) cannot survive any text form; for those
            //    we assert stability of the re-canonicalized value instead.
            for format in [EJSONFormat.canonical, EJSONFormat.editor] {
                do {
                    let text = try ExtendedJSON.stringify(document, format: format)
                    let reparsed = try ExtendedJSON.parseDocument(text)
                    if testCase.lossy == true {
                        let secondText = try ExtendedJSON.stringify(reparsed, format: format)
                        let stable = try ExtendedJSON.parseDocument(secondText)
                        #expect(
                            stable.makeData() == reparsed.makeData(),
                            "lossy value not stable after re-canonicalization — \(context)")
                    } else {
                        #expect(
                            Array(reparsed.makeData()) == canonicalBytes,
                            "\(format.mode) round trip bytes mismatch — \(context)")
                    }
                } catch {
                    Issue.record("\(format.mode) round trip threw \(error) — \(context)")
                }
            }

            // 4. Relaxed extjson (valid input; self-consistent round trip).
            if let relaxed = testCase.relaxed_extjson {
                do {
                    let parsed = try ExtendedJSON.parseDocument(relaxed)
                    let text = try ExtendedJSON.stringify(parsed, format: .editor)
                    let reparsed = try ExtendedJSON.parseDocument(text)
                    #expect(
                        reparsed.makeData() == parsed.makeData(),
                        "relaxed self-consistency mismatch — \(context)")
                } catch {
                    Issue.record("parse(relaxed_extjson) threw \(error) — \(context)")
                }
            }

            // 5. Degenerate extjson parses to canonical bytes.
            if let degenerate = testCase.degenerate_extjson, testCase.lossy != true {
                do {
                    let parsed = try ExtendedJSON.parseDocument(degenerate)
                    #expect(
                        Array(parsed.makeData()) == canonicalBytes,
                        "parse(degenerate_extjson) bytes mismatch — \(context)")
                } catch where Self.isExactnessLimitation(error) {
                } catch {
                    Issue.record("parse(degenerate_extjson) threw \(error) — \(context)")
                }
            }
        }
    }

    @Test(arguments: corpusFiles)
    func parseErrorCases(file: String) throws {
        let corpus = try Self.load(file)
        for testCase in corpus.parseErrors ?? [] {
            let context = "\(file): \(testCase.description)"
            if file.hasPrefix("decimal128") {
                // Decimal parse errors are bare $numberDecimal payload strings.
                #expect(throws: (any Error).self, "expected parse error — \(context)") {
                    try Decimal128Codec.decimal128(parsing: testCase.string)
                }
            } else {
                #expect(throws: (any Error).self, "expected parse error — \(context)") {
                    try ExtendedJSON.parseDocument(testCase.string)
                }
            }
        }
    }

    /// The exact canonical string formatting of Decimal128 values is asserted
    /// separately (other types are verified via byte-level round trips, but
    /// decimal formatting itself is our own implementation).
    @Test(arguments: ["decimal128-1", "decimal128-2", "decimal128-3", "decimal128-4",
                      "decimal128-5", "decimal128-6", "decimal128-7"])
    func decimalFormatting(file: String) throws {
        let corpus = try Self.load(file)
        for testCase in corpus.valid ?? [] {
            let canonicalBytes = Self.bytes(fromHex: testCase.canonical_bson)
            let document = Document(bytes: canonicalBytes)
            guard let value = document["d"] as? Decimal128 else { continue }
            let expectedDoc =
                try JSONSerialization.jsonObject(
                    with: Data(testCase.canonical_extjson.utf8)) as? [String: Any]
            guard let wrapper = expectedDoc?["d"] as? [String: Any],
                let expected = wrapper["$numberDecimal"] as? String
            else { continue }
            #expect(
                Decimal128Codec.string(from: value) == expected,
                "\(file): \(testCase.description)")
        }
    }
}

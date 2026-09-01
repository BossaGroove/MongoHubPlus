import BSON
import Foundation
import Testing

@testable import ExtendedJSON

struct CSVTests {
    @Test func flattensNestedDocumentsAndArrays() throws {
        let doc = try ExtendedJSON.parseDocument(
            #"{a: 1, b: {c: "x", d: [10, 20]}, e: [], f: {}}"#)
        let flat = CSV.flatten(doc)
        #expect(flat.map(\.path) == ["a", "b.c", "b.d.0", "b.d.1", "e", "f"])
        #expect(CSV.cellText(flat[0].value) == "1")
        #expect(CSV.cellText(flat[1].value) == "x")
        #expect(CSV.cellText(flat[4].value) == "[]")
        #expect(CSV.cellText(flat[5].value) == "{}")
    }

    @Test func cellTextIsSpreadsheetFriendly() {
        let id = ObjectId()
        #expect(CSV.cellText(id) == id.hexString)
        #expect(CSV.cellText("plain") == "plain")
        #expect(CSV.cellText(Int32(7)) == "7")
        #expect(CSV.cellText(5_000_000_000) == "5000000000")
        #expect(CSV.cellText(2.5) == "2.5")
        #expect(CSV.cellText(true) == "true")
        #expect(CSV.cellText(Null()) == "")
        #expect(
            CSV.cellText(Date(timeIntervalSince1970: 1_600_000_000))
                == "2020-09-13T12:26:40.000Z")
        #expect(CSV.cellText(RegularExpression(pattern: "a.b", options: "i")) == "/a.b/i")
    }

    @Test func encodesRFC4180() {
        #expect(CSV.encodeRow(["a", "b"]) == "a,b")
        #expect(CSV.encodeRow(["a,b", "c\"d", "e\nf"]) == "\"a,b\",\"c\"\"d\",\"e\nf\"")
    }

    @Test func parsesRFC4180() {
        let rows = CSV.parse("a,b\n\"x,y\",\"he said \"\"hi\"\"\"\r\n\"multi\nline\",z\n")
        #expect(rows == [["a", "b"], ["x,y", "he said \"hi\""], ["multi\nline", "z"]])
        // BOM stripped, trailing content without newline kept
        #expect(CSV.parse("\u{FEFF}a,b\nc,d") == [["a", "b"], ["c", "d"]])
    }

    @Test func exportImportRoundTripKeepsShape() throws {
        let doc = try ExtendedJSON.parseDocument(
            #"{name: "Ada", age: 39, nested: {city: "London"}, tags: ["math", "pioneer"]}"#)
        let flat = CSV.flatten(doc)
        let headers = flat.map(\.path)
        let row = flat.map { CSV.cellText($0.value) }
        let rebuilt = CSV.document(headers: headers, row: row)
        #expect(rebuilt["name"] as? String == "Ada")
        #expect(rebuilt["age"] as? Int32 == 39)
        #expect((rebuilt["nested"] as? Document)?["city"] as? String == "London")
        let tags = rebuilt["tags"] as? Document
        #expect(tags?.isArray == true)
        #expect(tags?.values.compactMap { $0 as? String } == ["math", "pioneer"])
    }

    @Test func importCellTyping() {
        #expect(CSV.cellValue("42") as? Int32 == 42)
        #expect(CSV.cellValue("5000000000") as? Int == 5_000_000_000)
        #expect(CSV.cellValue("2.5") as? Double == 2.5)
        #expect(CSV.cellValue("true") as? Bool == true)
        #expect(CSV.cellValue("hello world") as? String == "hello world")
        // strict ISO 8601 → Date (with or without fractional seconds)
        #expect(CSV.cellValue("2020-09-13T12:26:40.000Z") is Date)
        #expect(CSV.cellValue("2020-09-13T12:26:40Z") is Date)
        // date-ish but not strict ISO stays a string
        #expect(CSV.cellValue("2020-09-13") as? String == "2020-09-13")
        // plain hex stays a string; explicit wrapper makes an ObjectId
        #expect(CSV.cellValue("6a953c237be6f4522e741a18") is String)
        #expect(CSV.cellValue("ObjectId(\"6a953c237be6f4522e741a18\")") is ObjectId)
        // quoting forces a string even for numbers
        #expect(CSV.cellValue("\"42\"") as? String == "42")
    }

    @Test func importSkipsEmptyCellsAndCompactsArrays() {
        // sparse array columns (0 and 2, 1 empty) compact in index order
        let doc = CSV.document(
            headers: ["a.2", "a.0", "b", ""], row: ["third", "first", "", "ignored"])
        let a = doc["a"] as? Document
        #expect(a?.isArray == true)
        #expect(a?.values.compactMap { $0 as? String } == ["first", "third"])
        #expect(doc["b"] == nil)
    }
}

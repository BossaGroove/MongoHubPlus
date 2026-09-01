import Testing
import BSON
@testable import ExtendedJSON

@Test func parseSimpleDocument() throws {
    let doc = try ExtendedJSON.parseDocument(#"{name: 'test', n: 1, big: NumberLong(5)}"#)
    #expect(doc["name"] as? String == "test")
    #expect(doc["n"] as? Int32 == 1)
    #expect(doc["big"] as? Int == 5)
}

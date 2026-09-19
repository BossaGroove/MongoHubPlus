import BSON
import Testing

@testable import ExtendedJSON

/// The Update pane's preview annotates a sampled document with what each
/// operator would do (feature-spec 3.21). These pin the cases where guessing
/// would produce a confident lie.
struct UpdatePreviewTests {
    private func sample() -> Document {
        var document = Document()
        document["currency"] = "JPY"
        document["price"] = Int32(100)
        document["stock"] = Int32(5)
        var tags = Document(isArray: true)
        tags["0"] = "a"
        tags["1"] = "b"
        document["tags"] = tags
        var nested = Document()
        nested["code"] = "JP"
        document["region"] = nested
        return document
    }

    private func effects(_ update: Document) throws -> [UpdateEffect] {
        let document = sample()
        return try UpdatePreview.effects(of: update, on: document)
            + UpdatePreview.renameAdditions(of: update, on: document)
    }

    @Test func setReplacesAndAdds() throws {
        let results = try effects(["$set": ["currency": "HKD", "colour": "red"] as Document])
        #expect(results.count == 2)
        guard case .changed(let old, let new) = results[0].kind else {
            Issue.record("expected a change"); return
        }
        #expect(old as? String == "JPY")
        #expect(new as? String == "HKD")
        guard case .added(let added) = results[1].kind else {
            Issue.record("expected an addition"); return
        }
        #expect(added as? String == "red")
    }

    /// `$unset` removes the field whatever value is typed beside it — the
    /// value in the spec is not a new value and must not be shown as one.
    @Test func unsetIgnoresItsArgument() throws {
        let results = try effects(["$unset": ["currency": "HKD"] as Document])
        #expect(results.count == 1)
        guard case .removed(let old) = results[0].kind else {
            Issue.record("expected a removal"); return
        }
        #expect(old as? String == "JPY")
    }

    @Test func unsetOfAMissingFieldChangesNothing() throws {
        #expect(try effects(["$unset": ["nope": ""] as Document]).isEmpty)
    }

    /// `$setOnInsert` only fires when an upsert inserts, so a matched document
    /// is untouched and the preview must stay silent.
    @Test func setOnInsertIsNotAChangeForMatchedDocuments() throws {
        #expect(try effects(["$setOnInsert": ["currency": "HKD"] as Document]).isEmpty)
    }

    @Test func incKeepsTheFieldsNumericType() throws {
        let results = try effects(["$inc": ["price": Int32(10)] as Document])
        guard case .changed(let old, let new) = results[0].kind else {
            Issue.record("expected a change"); return
        }
        #expect(old as? Int32 == 100)
        #expect(new as? Int32 == 110, "an Int32 field must not be previewed as a Double")
    }

    /// int + double becomes a double on the server; previewing it as an int
    /// would be the silent type change the project forbids.
    @Test func incPromotesToDoubleWhenEitherSideIsOne() throws {
        let results = try effects(["$inc": ["price": 1.5] as Document])
        guard case .changed(_, let new) = results[0].kind else {
            Issue.record("expected a change"); return
        }
        #expect(new as? Double == 101.5)
        #expect(new as? Int32 == nil)
    }

    /// $min/$max swap in the winning value, keeping that value's own type.
    @Test func maxCarriesTheOperandsType() throws {
        let results = try effects(["$max": ["price": 500.5] as Document])
        guard case .changed(_, let new) = results[0].kind else {
            Issue.record("expected a change"); return
        }
        #expect(new as? Double == 500.5)
    }

    @Test func minAndMaxReportNothingWhenTheCurrentValueWins() throws {
        #expect(try effects(["$max": ["price": Int32(50)] as Document]).isEmpty)
        #expect(try effects(["$min": ["price": Int32(500)] as Document]).isEmpty)
        #expect(try effects(["$max": ["price": Int32(500)] as Document]).count == 1)
    }

    @Test func renameRemovesTheSourceAndAddsTheDestination() throws {
        let results = try effects(["$rename": ["currency": "iso_currency"] as Document])
        #expect(results.count == 2)
        #expect(results[0].path == ["currency"])
        guard case .removed = results[0].kind else {
            Issue.record("source should be removed"); return
        }
        #expect(results[1].path == ["iso_currency"])
        guard case .added(let moved) = results[1].kind else {
            Issue.record("destination should be added"); return
        }
        #expect(moved as? String == "JPY")
    }

    @Test func pushAppendsToTheArray() throws {
        let results = try effects(["$push": ["tags": "c"] as Document])
        guard case .changed(_, let new) = results[0].kind,
            let array = new as? Document
        else {
            Issue.record("expected an array"); return
        }
        #expect(array.values.count == 3)
        #expect(array.values.last as? String == "c")
    }

    /// `$each`, `$sort`, `$slice` and `$position` reorder and trim by the
    /// server's rules; the field is marked as changing without a value.
    @Test func pushWithModifiersIsOpaque() throws {
        var each = Document(isArray: true)
        each["0"] = "c"
        let results = try effects(["$push": ["tags": ["$each": each] as Document] as Document])
        guard case .opaque = results[0].kind else {
            Issue.record("modifiers must not be rendered as a concrete value"); return
        }
    }

    @Test func addToSetSkipsAValueAlreadyPresent() throws {
        #expect(try effects(["$addToSet": ["tags": "a"] as Document]).isEmpty)
        #expect(try effects(["$addToSet": ["tags": "z"] as Document]).count == 1)
    }

    @Test func popRemovesFromEitherEnd() throws {
        guard
            case .changed(_, let last) = try effects(["$pop": ["tags": Int32(1)] as Document])[0]
                .kind,
            let lastArray = last as? Document
        else { Issue.record("expected array"); return }
        #expect(lastArray.values.count == 1)
        #expect(lastArray.values.first as? String == "a")

        guard
            case .changed(_, let first) = try effects(["$pop": ["tags": Int32(-1)] as Document])[0]
                .kind,
            let firstArray = first as? Document
        else { Issue.record("expected array"); return }
        #expect(firstArray.values.first as? String == "b")
    }

    /// `$pull` takes a query predicate and `$currentDate` a server clock
    /// reading — neither is knowable from the sampled document.
    @Test func predicateAndClockOperatorsAreOpaque() throws {
        for update in [
            ["$pull": ["tags": "a"] as Document] as Document,
            ["$currentDate": ["touched": true] as Document] as Document,
        ] {
            let results = try effects(update)
            #expect(results.count == 1)
            guard case .opaque = results[0].kind else {
                Issue.record("expected an opaque effect for \(update)"); return
            }
        }
    }

    @Test func dottedPathsReachIntoSubdocuments() throws {
        let results = try effects(["$set": ["region.code": "HK"] as Document])
        #expect(results[0].path == ["region", "code"])
        guard case .changed(let old, _) = results[0].kind else {
            Issue.record("expected a change"); return
        }
        #expect(old as? String == "JP")
    }

    // MARK: - Operand normalization

    /// An update operand is not a query. The "type an id" shortcut turning a
    /// bare word into `{_id: "word"}` is right for a criteria box and very
    /// wrong here: it made `$set: name` mean "rewrite every matched
    /// document's _id", which is what the Update pane used to build.
    @Test func aBareWordIsNotAnIdShortcutInAnOperand() throws {
        #expect(QueryNormalizer.normalizeOperand("name") == "name")
        #expect(throws: (any Error).self) {
            _ = try ExtendedJSON.parseDocument(QueryNormalizer.normalizeOperand("name"))
        }
        // …while the criteria box keeps the shortcut it is meant to have.
        #expect(QueryNormalizer.normalizeCriteria("name") == "{_id: \"name\"}")
    }

    @Test func anOperandKeepsTheOuterBraceConvenience() throws {
        #expect(QueryNormalizer.normalizeOperand("currency: 'HKD'") == "{currency: 'HKD'}")
        #expect(QueryNormalizer.normalizeOperand("{currency: 'HKD'}") == "{currency: 'HKD'}")
        #expect(QueryNormalizer.normalizeOperand("   ") == "{}")
        let parsed = try ExtendedJSON.parseDocument(
            QueryNormalizer.normalizeOperand("currency: 'HKD'"))
        #expect(parsed["currency"] as? String == "HKD")
    }

    /// A 24-hex string is an id in a query box; in an operand it is just a
    /// string value, and must not be wrapped as `{_id: ObjectId(…)}`.
    @Test func anOperandDoesNotPromoteAHexStringToAnIdQuery() {
        let hex = "5f50a10dff1ce7314da050ca"
        #expect(QueryNormalizer.normalizeOperand(hex) == hex)
        #expect(QueryNormalizer.normalizeCriteria(hex).contains("_id"))
    }

    // MARK: - The unhappy paths that clear the preview

    @Test func aFieldWithoutAnOperatorIsRejected() {
        #expect(throws: (any Error).self) {
            _ = try UpdatePreview.effects(of: ["currency": "HKD"], on: sample())
        }
    }

    @Test func anUnknownOperatorIsRejected() {
        #expect(throws: (any Error).self) {
            _ = try UpdatePreview.effects(
                of: ["$abc": ["currency": "HKD"] as Document], on: sample())
        }
    }

    @Test func aPipelineUpdateIsRejected() {
        var pipeline = Document(isArray: true)
        pipeline["0"] = ["$set": ["currency": "HKD"] as Document] as Document
        #expect(throws: (any Error).self) {
            _ = try UpdatePreview.effects(of: pipeline, on: sample())
        }
    }
}

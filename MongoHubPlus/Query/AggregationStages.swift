import BSON
import ExtendedJSON
import Foundation

/// One pipeline stage in the builder (feature 3.17): a single operator, its
/// body as Extended JSON text, and an enabled flag (disabled stages are
/// skipped when running — the flag is lost when converting to text mode,
/// owner-accepted trade-off).
struct AggregationStage {
    var operatorName: String
    var bodyText: String
    var enabled: Bool = true
}

enum AggregationStages {
    static let operators = [
        "$match", "$project", "$group", "$sort", "$limit", "$skip", "$unwind",
        "$lookup", "$addFields", "$set", "$unset", "$count", "$sample",
        "$facet", "$bucket", "$sortByCount", "$out", "$merge",
    ]

    /// Starter bodies for freshly added stages.
    static func template(for operatorName: String) -> String {
        switch operatorName {
        case "$match", "$project", "$addFields", "$set", "$facet": return "{\n  \n}"
        case "$group": return "{\n  _id: null\n}"
        case "$sort": return "{\n  _id: 1\n}"
        case "$limit": return "10"
        case "$skip": return "0"
        case "$unwind": return "\"$field\""
        case "$count": return "\"count\""
        case "$sample": return "{ size: 10 }"
        case "$unset": return "\"field\""
        case "$sortByCount": return "\"$field\""
        case "$out": return "\"collection\""
        case "$merge": return "{ into: \"collection\" }"
        case "$lookup":
            return "{\n  from: \"\",\n  localField: \"\",\n  foreignField: \"\",\n  as: \"\"\n}"
        case "$bucket":
            return "{\n  groupBy: \"$field\",\n  boundaries: [0, 10],\n  default: \"other\"\n}"
        default: return "{\n  \n}"
        }
    }

    struct ConversionError: Error, CustomStringConvertible {
        let description: String
    }

    /// Text mode → stage list. Every pipeline element must be a single-key
    /// `{$op: body}` document; a bare stage document is auto-wrapped (legacy
    /// nicety, same as Run).
    static func stages(fromText text: String) throws -> [AggregationStage] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let parsed = try ExtendedJSON.parseDocument(trimmed)
        var pipeline = parsed
        if !parsed.isArray {
            pipeline = Document(isArray: true)
            pipeline["0"] = parsed
        }
        var stages: [AggregationStage] = []
        for (position, value) in pipeline.values.enumerated() {
            guard let stage = value as? Document, !stage.isArray, stage.keys.count == 1,
                let operatorName = stage.keys.first, operatorName.hasPrefix("$"),
                let body = stage[operatorName]
            else {
                throw ConversionError(
                    description: String(
                        localized:
                            "Stage \(position + 1) is not a single-operator document like {$match: …}"
                    ))
            }
            let bodyText =
                (try? ExtendedJSON.stringifyValue(
                    body, format: EJSONFormat(mode: .editor, pretty: true))) ?? "{}"
            stages.append(AggregationStage(operatorName: operatorName, bodyText: bodyText))
        }
        return stages
    }

    /// Stage list → text mode (all stages; enabled flags are dropped).
    static func text(from stages: [AggregationStage]) throws -> String {
        try ExtendedJSON.stringify(
            pipelineDocument(from: stages, onlyEnabled: false),
            format: EJSONFormat(mode: .editor, pretty: true))
    }

    /// Parses one stage into its `{$op: body}` document.
    static func stageDocument(_ stage: AggregationStage) throws -> Document {
        let body = try ExtendedJSON.parseValue(stage.bodyText)
        var document = Document()
        document[stage.operatorName] = body
        return document
    }

    /// The runnable pipeline array.
    static func pipelineDocument(
        from stages: [AggregationStage], onlyEnabled: Bool
    ) throws -> Document {
        var pipeline = Document(isArray: true)
        var position = 0
        for stage in stages where !onlyEnabled || stage.enabled {
            pipeline[String(position)] = try stageDocument(stage)
            position += 1
        }
        return pipeline
    }

    /// The preview pipeline: enabled stages up to and including `stageIndex`
    /// (an index into the full list), with `$out`/`$merge` stripped — a
    /// preview must never write — and a trailing `$limit`.
    static func previewDocument(
        from stages: [AggregationStage], upTo stageIndex: Int, limit: Int
    ) throws -> Document {
        var pipeline = Document(isArray: true)
        var position = 0
        for (index, stage) in stages.enumerated() where index <= stageIndex {
            guard stage.enabled, stage.operatorName != "$out", stage.operatorName != "$merge"
            else { continue }
            pipeline[String(position)] = try stageDocument(stage)
            position += 1
        }
        var limitStage = Document()
        limitStage["$limit"] = Int32(limit)
        pipeline[String(position)] = limitStage
        return pipeline
    }
}

import BSON
import Foundation

/// What an update operator would do to one field of one sampled document, so
/// the Update pane can show it before anything is written (feature-spec 3.21).
///
/// This is a *rendering* aid, not a simulation of MongoDB: it annotates the
/// document that was sampled rather than producing the document the server
/// would produce. Where an operator's result cannot be known from the sampled
/// document alone the effect is `.opaque` — the field is marked as changing
/// without inventing a value, because a confident wrong preview is worse than
/// an honest gap.
public struct UpdateEffect: Sendable {
    /// Dotted path from the document root, split into components.
    public let path: [String]
    public let kind: Kind

    public enum Kind: Sendable {
        /// The field exists and takes a new value.
        case changed(old: Primitive, new: Primitive)
        /// The field does not exist yet and will be created.
        case added(new: Primitive)
        /// The field is removed.
        case removed(old: Primitive)
        /// It changes, but not in a way this can render faithfully.
        case opaque(old: Primitive?)
    }

    init(path: [String], kind: Kind) {
        self.path = path
        self.kind = kind
    }
}

public enum UpdatePreview {
    /// Every update operator the Update pane offers.
    public static let supportedOperators: Set<String> = [
        "$set", "$unset", "$inc", "$mul", "$min", "$max", "$rename", "$setOnInsert",
        "$currentDate", "$bit", "$push", "$addToSet", "$pop", "$pull", "$pullAll",
    ]

    /// Computes what `update` would do to `document`.
    ///
    /// Throws `EJSONError` when the update document is not shaped like an
    /// update at all — the caller clears the preview and says why.
    public static func effects(of update: Document, on document: Document) throws -> [UpdateEffect]
    {
        guard !update.isArray else {
            throw EJSONError("Aggregation-pipeline updates cannot be previewed")
        }
        var effects: [UpdateEffect] = []
        for pair in update.pairs {
            let op = pair.key
            guard op.hasPrefix("$") else {
                throw EJSONError("Update document requires atomic operators")
            }
            guard supportedOperators.contains(op) else {
                throw EJSONError("Unknown modifier: \(op)")
            }
            guard let arguments = pair.value as? Document, !arguments.isArray else {
                throw EJSONError("\(op) expects a document of field/value pairs")
            }
            for argument in arguments.pairs {
                let path = splitPath(argument.key)
                guard !path.isEmpty else { continue }
                let old = value(at: path, in: document)
                if let effect = effect(
                    op: op, path: path, old: old, argument: argument.value, document: document)
                {
                    effects.append(effect)
                }
            }
        }
        return effects
    }

    private static func effect(
        op: String, path: [String], old: Primitive?, argument: Primitive, document: Document
    ) -> UpdateEffect? {
        switch op {
        case "$set":
            if let old {
                return UpdateEffect(path: path, kind: .changed(old: old, new: argument))
            }
            return UpdateEffect(path: path, kind: .added(new: argument))

        case "$unset":
            // The argument is ignored by MongoDB — the field goes either way.
            guard let old else { return nil }
            return UpdateEffect(path: path, kind: .removed(old: old))

        case "$setOnInsert":
            // Applies only when an upsert inserts, so a matched document is
            // untouched. Showing it as a change would be a lie.
            return nil

        case "$inc", "$mul", "$min", "$max":
            return arithmetic(op: op, path: path, old: old, argument: argument)

        case "$rename":
            // The source field goes; the destination arrives via
            // `renameAdditions`, because one operator yields two effects.
            guard let old, argument is String else { return nil }
            return UpdateEffect(path: path, kind: .removed(old: old))

        case "$currentDate":
            // The value is a server clock reading at write time, which is not
            // the value any preview could show truthfully.
            return UpdateEffect(path: path, kind: .opaque(old: old))

        case "$bit":
            return UpdateEffect(path: path, kind: .opaque(old: old))

        case "$push", "$addToSet":
            return append(op: op, path: path, old: old, argument: argument)

        case "$pop":
            return pop(path: path, old: old, argument: argument)

        case "$pull", "$pullAll":
            // $pull takes a query predicate and $pullAll a value list; both
            // need query evaluation to know which elements survive.
            return UpdateEffect(path: path, kind: .opaque(old: old))

        default:
            return nil
        }
    }

    /// `$rename` moves a value, so it produces a removal *and* an addition.
    public static func renameAdditions(of update: Document, on document: Document) -> [UpdateEffect]
    {
        guard let renames = update["$rename"] as? Document else { return [] }
        var effects: [UpdateEffect] = []
        for pair in renames.pairs {
            guard let target = pair.value as? String else { continue }
            let from = splitPath(pair.key)
            let to = splitPath(target)
            guard !to.isEmpty, let moved = value(at: from, in: document) else { continue }
            if let existing = value(at: to, in: document) {
                effects.append(UpdateEffect(path: to, kind: .changed(old: existing, new: moved)))
            } else {
                effects.append(UpdateEffect(path: to, kind: .added(new: moved)))
            }
        }
        return effects
    }

    // MARK: - Operator helpers

    private static func arithmetic(
        op: String, path: [String], old: Primitive?, argument: Primitive
    ) -> UpdateEffect? {
        guard let operand = double(argument) else {
            return UpdateEffect(path: path, kind: .opaque(old: old))
        }
        guard let old else {
            // On a missing field MongoDB seeds: $inc/$max/$min use the operand,
            // $mul produces zero of the operand's type.
            switch op {
            case "$mul": return UpdateEffect(path: path, kind: .added(new: Int32(0)))
            default: return UpdateEffect(path: path, kind: .added(new: argument))
            }
        }
        guard let current = double(old) else {
            return UpdateEffect(path: path, kind: .opaque(old: old))
        }
        // $min/$max replace the field with whichever value wins, carrying
        // that value's own type, so hand back the operand rather than a
        // recomputed number.
        if op == "$min" || op == "$max" {
            let operandWins = op == "$min" ? operand < current : operand > current
            guard operandWins else { return nil }
            return UpdateEffect(path: path, kind: .changed(old: old, new: argument))
        }
        let result = op == "$inc" ? current + operand : current * operand
        // MongoDB promotes to double when either side is a double and
        // otherwise keeps the field's integral width (verified against 8.3:
        // int + int32 stays `int`, int + double becomes `double`). Rendering
        // 111.5 as an int would be exactly the silent type change this
        // project forbids.
        let promotesToDouble = old is Double || argument is Double
        let new: Primitive = promotesToDouble ? result : number(result, like: old)
        return UpdateEffect(path: path, kind: .changed(old: old, new: new))
    }

    private static func append(
        op: String, path: [String], old: Primitive?, argument: Primitive
    ) -> UpdateEffect? {
        // $each/$slice/$sort/$position change the result in ways that need the
        // server's ordering rules.
        if let modifiers = argument as? Document, !modifiers.isArray,
            modifiers.keys.contains(where: { $0.hasPrefix("$") })
        {
            return UpdateEffect(path: path, kind: .opaque(old: old))
        }
        guard let old else {
            var array = Document(isArray: true)
            array["0"] = argument
            return UpdateEffect(path: path, kind: .added(new: array))
        }
        guard let existing = old as? Document, existing.isArray else {
            return UpdateEffect(path: path, kind: .opaque(old: old))
        }
        if op == "$addToSet", existing.values.contains(where: { equal($0, argument) }) {
            return nil  // already present, $addToSet does nothing
        }
        var appended = existing
        appended.append(argument)
        return UpdateEffect(path: path, kind: .changed(old: old, new: appended))
    }

    private static func pop(path: [String], old: Primitive?, argument: Primitive) -> UpdateEffect? {
        guard let existing = old as? Document, existing.isArray, !existing.values.isEmpty else {
            return old.map { UpdateEffect(path: path, kind: .opaque(old: $0)) }
        }
        guard let direction = double(argument) else {
            return UpdateEffect(path: path, kind: .opaque(old: old))
        }
        var values = existing.values
        if direction < 0 { values.removeFirst() } else { values.removeLast() }
        var result = Document(isArray: true)
        for value in values { result.append(value) }
        return UpdateEffect(path: path, kind: .changed(old: existing, new: result))
    }

    // MARK: - Document navigation

    /// Splits a dotted update key into path components.
    public static func splitPath(_ key: String) -> [String] {
        key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    }

    /// Reads the value at a dotted path, walking embedded documents and
    /// arrays (numeric components index into arrays).
    public static func value(at path: [String], in document: Document) -> Primitive? {
        var current: Primitive? = document
        for component in path {
            guard let container = current as? Document else { return nil }
            current = container[component]
            if current == nil { return nil }
        }
        return current
    }

    private static func double(_ value: Primitive?) -> Double? {
        switch value {
        case let value as Int32: return Double(value)
        case let value as Int: return Double(value)
        case let value as Double: return value
        default: return nil
        }
    }

    /// Rebuilds `result` in the same numeric type as `original` where it fits.
    private static func number(_ result: Double, like original: Primitive) -> Primitive {
        switch original {
        case is Int32:
            if result.rounded() == result, result >= Double(Int32.min), result <= Double(Int32.max)
            {
                return Int32(result)
            }
            return result
        case is Int:
            if result.rounded() == result, result.magnitude < 9.007_199_254_740_992e15 {
                return Int(result)
            }
            return result
        default:
            return result
        }
    }

    private static func equal(_ lhs: Primitive, _ rhs: Primitive) -> Bool {
        // Cheap structural comparison, enough for "is this already in the set".
        String(describing: lhs) == String(describing: rhs)
    }
}

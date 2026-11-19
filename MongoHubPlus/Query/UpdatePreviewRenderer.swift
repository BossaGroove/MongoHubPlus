import AppKit
import BSON
import ExtendedJSON

/// Draws a sampled document with the pending update marked on it
/// (feature-spec 3.21): the old value struck through in red, the new value
/// beside it in green, in the document's own key order.
///
/// It annotates the document that was sampled rather than building the one the
/// server would write — nothing here is sent anywhere. An effect the update
/// cannot be rendered faithfully from (`.opaque`) says *will change* instead of
/// inventing a value.
@MainActor
enum UpdatePreviewRenderer {
    /// One document's worth of diff. Each is drawn into its own card, so a
    /// blank line never has to stand in for a boundary between documents.
    static func render(
        document: Document, effects: [UpdateEffect], theme: JSONTheme
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        append(document: document, effects: effects, to: output, theme: theme)
        // The card supplies the padding; a trailing newline would leave a gap.
        while output.string.hasSuffix("\n") {
            output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
        }
        return output
    }

    /// One bordered card per document, the way Compass separates them — a
    /// blank line between two JSON blobs reads as part of the document.
    /// Shared by the Update pane and the MCP pending-update window.
    static func card(for document: NSAttributedString, theme: JSONTheme) -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.backgroundColor = theme.background.cgColor
        card.layer?.cornerRadius = 6
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        let label = NSTextField(labelWithAttributedString: document)
        label.isSelectable = true
        label.allowsEditingTextAttributes = true
        // Selecting hands the text to the window's shared field editor,
        // which redraws it with the field's own font and colour — the
        // system defaults — unless the field is marked as carrying
        // attributed text. Without this, clicking a card turned the whole
        // document white in the system font.
        label.font = theme.font
        label.textColor = theme.text
        label.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            label.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
        ])
        return card
    }

    // MARK: - Document body

    private static func append(
        document: Document, effects: [UpdateEffect], to output: NSMutableAttributedString,
        theme: JSONTheme
    ) {
        output.append(punctuation("{\n", theme: theme))
        appendFields(
            of: document, at: [], effects: effects, indent: 1, to: output, theme: theme)
        output.append(punctuation("}\n", theme: theme))
    }

    private static func appendFields(
        of container: Document, at path: [String], effects: [UpdateEffect], indent: Int,
        to output: NSMutableAttributedString, theme: JSONTheme
    ) {
        let pad = String(repeating: "  ", count: indent)
        for pair in container.pairs {
            let fieldPath = path + [pair.key]
            let effect = effects.first { $0.path == fieldPath }
            output.append(plain(pad, theme: theme))
            output.append(attributed(pair.key + ": ", color: theme.key, theme: theme))

            // A container with changes *inside* it is expanded so the changed
            // leaf is visible; one with nothing to show stays on a single line.
            if let nested = pair.value as? Document, effect == nil,
                effects.contains(where: { $0.path.starts(with: fieldPath) })
            {
                output.append(punctuation(nested.isArray ? "[\n" : "{\n", theme: theme))
                appendFields(
                    of: nested, at: fieldPath, effects: effects, indent: indent + 1, to: output,
                    theme: theme)
                output.append(plain(pad, theme: theme))
                output.append(punctuation(nested.isArray ? "]\n" : "}\n", theme: theme))
                continue
            }

            switch effect?.kind {
            case .changed(let previous, let next):
                output.append(struck(previous, theme: theme))
                output.append(plain(" ", theme: theme))
                output.append(inserted(next, theme: theme))
            case .removed(let previous):
                output.append(struck(previous, theme: theme))
            case .opaque:
                output.append(struck(pair.value, theme: theme))
                output.append(plain(" ", theme: theme))
                output.append(willChange(theme: theme))
            case .added, .none:
                output.append(unchanged(pair.value, theme: theme))
            }
            output.append(plain("\n", theme: theme))
        }

        // Fields the update creates do not exist in the sampled document, so
        // they are appended to the container they belong to.
        for effect in effects
        where effect.path.count == path.count + 1
            && Array(effect.path.dropLast()) == path
        {
            let name = effect.path[effect.path.count - 1]
            guard container[name] == nil else { continue }
            switch effect.kind {
            case .added(let added):
                output.append(plain(pad, theme: theme))
                output.append(attributed(name + ": ", color: theme.key, theme: theme))
                output.append(inserted(added, theme: theme))
                output.append(plain("\n", theme: theme))
            case .opaque(old: nil):
                // A field the update creates with a value only the server
                // knows ($currentDate, $bit): still shown, so the preview
                // never leaves out a field that will appear.
                output.append(plain(pad, theme: theme))
                output.append(attributed(name + ": ", color: theme.key, theme: theme))
                output.append(willChange(theme: theme))
                output.append(plain("\n", theme: theme))
            default:
                continue
            }
        }
    }

    // MARK: - Value rendering

    /// Leaf values render exactly as the Find results render them, so a value
    /// looks the same wherever you meet it.
    ///
    /// Containers do not: the results outline leaves their Value column empty
    /// and shows the subtree as child rows instead, which in a JSON view would
    /// print `tags:` followed by nothing. Here they are serialized in full and
    /// cut, so an array still looks like an array.
    private static func text(for value: Primitive) -> String {
        guard let container = value as? Document else {
            return Preferences.resultsValueText(for: value)
        }
        let rendered =
            (try? ExtendedJSON.stringifyValue(
                container, format: Preferences.format(.extendedJSON, pretty: false)))
            ?? (container.isArray ? "[…]" : "{…}")
        let limit = 300
        return rendered.count > limit ? rendered.prefix(limit) + "…" : rendered
    }

    private static func unchanged(_ value: Primitive, theme: JSONTheme) -> NSAttributedString {
        attributed(text(for: value), color: colour(for: value, theme: theme), theme: theme)
    }

    /// The value as it is now — struck through on a red wash.
    private static func struck(_ value: Primitive, theme: JSONTheme) -> NSAttributedString {
        let string = NSMutableAttributedString(
            attributedString: attributed(
                text(for: value), color: theme.text, theme: theme))
        let range = NSRange(location: 0, length: string.length)
        string.addAttribute(
            .backgroundColor, value: NSColor.systemRed.withAlphaComponent(0.35), range: range)
        string.addAttribute(
            .strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        return string
    }

    /// The value the update would write — on a green wash.
    private static func inserted(_ value: Primitive, theme: JSONTheme) -> NSAttributedString {
        let string = NSMutableAttributedString(
            attributedString: attributed(
                text(for: value), color: theme.text, theme: theme))
        string.addAttribute(
            .backgroundColor, value: NSColor.systemGreen.withAlphaComponent(0.35),
            range: NSRange(location: 0, length: string.length))
        return string
    }

    private static func willChange(theme: JSONTheme) -> NSAttributedString {
        attributed(String(localized: "will change"), color: .systemOrange, theme: theme)
    }

    private static func colour(for value: Primitive, theme: JSONTheme) -> NSColor {
        switch value {
        case is String: return theme.string
        case is Bool: return theme.boolean
        case is Int32, is Int, is Double: return theme.number
        default: return theme.number
        }
    }

    // MARK: - Attribute helpers

    private static func attributed(
        _ string: String, color: NSColor, theme: JSONTheme
    ) -> NSAttributedString {
        NSAttributedString(
            string: string, attributes: [.foregroundColor: color, .font: theme.font])
    }

    private static func plain(_ string: String, theme: JSONTheme) -> NSAttributedString {
        attributed(string, color: theme.text, theme: theme)
    }

    private static func punctuation(_ string: String, theme: JSONTheme) -> NSAttributedString {
        attributed(string, color: theme.punctuation, theme: theme)
    }
}

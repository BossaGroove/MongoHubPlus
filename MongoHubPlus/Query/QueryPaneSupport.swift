import AppKit
import ExtendedJSON
import MongoService

/// Everything a query sub-pane needs to know about its collection.
struct QueryPaneContext {
    let connectionID: UUID
    let database: String
    let collection: String
    let session: () -> ConnectionSession?

    var namespace: String { "\(database).\(collection)" }
}

/// The query preview label: truncates instead of widening the window, and
/// keeps the full composed query reachable as a tooltip.
private final class PreviewField: NSTextField {
    override var stringValue: String {
        didSet { toolTip = stringValue.isEmpty ? nil : stringValue }
    }
}

/// Shared factories/behaviors for the query sub-panes (legacy MHQueryView).
@MainActor
enum QueryPaneUI {
    /// The grey read-only `db.coll.…` preview field ("Query Viewer").
    static func previewField() -> NSTextField {
        let field = PreviewField(labelWithString: "")
        field.textColor = NSColor(white: 0.5, alpha: 1)
        field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.isSelectable = true
        field.translatesAutoresizingMaskIntoConstraints = false
        // The composed query is unbounded: without this the label's intrinsic
        // width wins over the window, so typing a long query silently widened
        // the window (and left the criteria field editor sized for the old
        // width — dead space at the end, the tail of the text clipped).
        field.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return field
    }

    static func spinner() -> NSProgressIndicator {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        return spinner
    }

    /// Centered 18pt result label that flashes green/red (legacy behavior).
    static func resultLabel(placeholder: String) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.placeholderString = placeholder
        label.alignment = .center
        label.font = .systemFont(ofSize: 18)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    static func flash(_ label: NSTextField, text: String, success: Bool) {
        label.stringValue = text
        label.textColor = success ? .systemGreen : .systemRed
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.5
                label.animator().textColor = .labelColor
            }
        }
    }

    /// Syntax-colored JSON editor area (legacy black theme).
    static func jsonTextView(highlighter: JSONHighlighter) -> (NSScrollView, NSTextView) {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let textView = NSTextView()
        textView.autoresizingMask = [.width]
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 4, height: 4)
        scrollView.documentView = textView
        highlighter.apply(to: textView)
        return (scrollView, textView)
    }

    static func runButton(title: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        return button
    }

    /// ⌘Return has no AppKit binding, so the field editor reports it as
    /// `noop:` — which is also what makes it beep. Every other unbound ⌘
    /// combination arrives on that same selector, so the event itself has to
    /// be matched: exactly ⌘, and Return or the keypad's Enter.
    static let noopSelector = Selector(("noop:"))

    static var isCommandReturn: Bool {
        guard let event = NSApp.currentEvent,
            event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
        else { return false }
        return event.keyCode == 36 || event.keyCode == 76
    }

    /// ⌘Return in a criteria field: rewrite the shortcut forms into the
    /// field itself — braces around a bare `key: value`, the bare-id form,
    /// and 24-hex string values wrapped as `ObjectId(…)` (feature-spec 3.3,
    /// extended-json.md §3/§3.1). Everything it does not promote survives
    /// character for character. Returns true when the text changed.
    ///
    /// Input that does not parse is left alone: the run that follows reports
    /// it the way it always has, rather than the field rewriting itself into
    /// something the user did not type.
    @discardableResult
    static func expandIDShortcuts(in field: NSControl) -> Bool {
        let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return false }
        let expanded = QueryNormalizer.promotingObjectIds(
            QueryNormalizer.normalizeCriteria(raw, emptyIsValid: false))
        guard expanded != raw, (try? ExtendedJSON.parseDocument(expanded)) != nil else {
            return false
        }
        field.stringValue = expanded
        return true
    }

    static func alertSheet(in view: NSView?, title: String, message: String) {
        guard let window = view?.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }
}

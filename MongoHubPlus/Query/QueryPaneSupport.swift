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
        let scrollView = FindBarScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let textView = NSTextView()
        textView.autoresizingMask = [.width]
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 4, height: 4)
        // ⌘F here too — the legacy query boxes all carried the find panel,
        // and a half-live Edit ▸ Find menu would be worse than none.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        scrollView.documentView = textView
        highlighter.apply(to: textView)
        return (scrollView, textView)
    }

    /// Stop button for a query that is already running (feature-spec 3.20).
    /// Lives beside the spinner — the spinner is what tells you something is
    /// still going, so that is where you look for the way out — and stays
    /// hidden until there is something to stop. ⌘. is the system-wide cancel,
    /// which keeps ⌘R meaning Run at every moment.
    static func stopButton(target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: String(localized: "Stop"), target: target, action: action)
        button.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        // In the Find row this sits between the query preview and the spinner
        // with both sides pinned, so without hugging it swallows every spare
        // point and becomes a button the width of the window.
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.keyEquivalent = "."
        button.keyEquivalentModifierMask = .command
        button.toolTip = String(localized: "Stop the running query (⌘.)")
        button.isHidden = true
        // Both panes position this with constraints, so the synthesized
        // frame constraints have to go — leaving them on collapsed the
        // query tab's whole height chain (measured: the window opened
        // 1202x165 instead of 1400x451, and could not be resized).
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
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

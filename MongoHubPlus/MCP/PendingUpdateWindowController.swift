import AppKit
import BSON
import ExtendedJSON

/// The window that shows an update an assistant asked for (internal
/// mcp-tools.md §0, §7 step 8): exactly what will run, how many documents it
/// touches, and a before/after preview. Nothing runs until the user clicks
/// Apply Update with the pointer:
/// - Apply is never the default button, has no key equivalent, and refuses
///   keyboard focus, so neither Return nor Space (with keyboard navigation
///   on) can press it.
/// - Esc, Reject and the close button all reject.
/// - A filter that matches every document keeps Apply disabled until the
///   user types the collection's name.
@MainActor
final class PendingUpdateWindowController: NSWindowController, NSWindowDelegate,
    NSTextFieldDelegate
{
    private let action: PendingActions.Action
    private let rejectButton = NSButton(
        title: String(localized: "Reject"), target: nil, action: nil)
    private let applyButton = NSButton(
        title: String(localized: "Apply Update"), target: nil, action: nil)
    private let closeButton = NSButton(title: String(localized: "Close"), target: nil, action: nil)
    private let confirmField = NSTextField(string: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var needsTypedConfirmation: Bool { action.request.filter.isEmpty }

    init(action: PendingActions.Action) {
        self.action = action
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = String(localized: "Update Requested by an AI Assistant")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    private func buildContent() {
        guard let window else { return }
        let request = action.request

        let headline = NSTextField(
            labelWithString: String(localized: "An AI assistant wants to update documents"))
        headline.font = .boldSystemFont(ofSize: 15)

        let expires = action.expiresAt.formatted(date: .omitted, time: .shortened)
        let subline = NSTextField(
            wrappingLabelWithString: String(
                localized:
                    "Nothing changes unless you click Apply Update. If you don't answer, the request is rejected at \(expires)."
            ))
        subline.textColor = .secondaryLabelColor

        func label(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.alignment = .right
            label.textColor = .secondaryLabelColor
            return label
        }
        func value(_ text: String, monospaced: Bool = false) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: text)
            field.isSelectable = true
            if monospaced {
                field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            }
            return field
        }

        let affects: String
        switch (request.multi, request.matchCount) {
        case (true, let count?):
            affects = String(localized: "Every matching document: \(count) match now")
        case (false, let count?):
            affects = String(localized: "Only the first matching document: \(count) match now")
        case (true, nil):
            affects = String(localized: "Every matching document")
        case (false, nil):
            affects = String(localized: "Only the first matching document")
        }
        let affectsField = value(affects)
        affectsField.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        let grid = NSGridView(views: [
            [label(String(localized: "Connection:")), value(request.connectionName)],
            [
                label(String(localized: "Collection:")),
                value("\(request.database).\(request.collection)", monospaced: true),
            ],
            [label(String(localized: "Filter:")), value(request.filterText, monospaced: true)],
            [label(String(localized: "Update:")), value(request.updateText, monospaced: true)],
            [label(String(localized: "Affects:")), affectsField],
        ])
        grid.rowSpacing = 6
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 90
        grid.column(at: 1).xPlacement = .fill

        var rows: [NSView] = [headline, subline, grid]
        rows.append(contentsOf: previewViews())

        if needsTypedConfirmation {
            let warning = NSTextField(
                wrappingLabelWithString: String(
                    localized:
                        "This filter matches every document in the collection. Type the collection's name, \(request.collection), to enable Apply Update:"
                ))
            warning.textColor = .systemRed
            // Not the name itself: a greyed-out "orders" reads as already typed.
            confirmField.placeholderString = String(localized: "Collection name")
            confirmField.delegate = self
            rows.append(warning)
            rows.append(confirmField)
        }

        statusLabel.isHidden = true
        statusLabel.isSelectable = true
        rows.append(statusLabel)

        rejectButton.target = self
        rejectButton.action = #selector(rejectAction(_:))
        rejectButton.keyEquivalent = "\u{1b}"

        applyButton.target = self
        applyButton.action = #selector(applyAction(_:))
        applyButton.hasDestructiveAction = true
        applyButton.keyEquivalent = ""
        // Pointer only: keyboard navigation can't focus it, so Space can't
        // press it either.
        applyButton.refusesFirstResponder = true
        applyButton.isEnabled = !needsTypedConfirmation

        closeButton.target = self
        closeButton.action = #selector(closeAction(_:))
        closeButton.isHidden = true

        let buttons = NSStackView(views: [NSView(), closeButton, rejectButton, applyButton])
        buttons.orientation = .horizontal
        rows.append(buttons)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        for row in rows {
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 640),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        window.contentView = content
        // No default button: Return must never apply.
        window.defaultButtonCell = nil
        window.initialFirstResponder = needsTypedConfirmation ? confirmField : rejectButton
        window.setContentSize(content.fittingSize)
    }

    /// The Update pane's preview: each sampled document with the change
    /// marked on it, old value struck through in red, new value in green.
    private func previewViews() -> [NSView] {
        let request = action.request
        guard !request.samples.isEmpty else {
            let none = NSTextField(
                wrappingLabelWithString: String(
                    localized:
                        "No documents match this filter right now, so there is nothing to preview."
                ))
            none.textColor = .secondaryLabelColor
            return [none]
        }

        let theme = JSONTheme.current
        var cards: [NSView] = []
        for sample in request.samples {
            do {
                var effects = try UpdatePreview.effects(of: request.update, on: sample)
                effects += UpdatePreview.renameAdditions(of: request.update, on: sample)
                cards.append(
                    UpdatePreviewRenderer.card(
                        for: UpdatePreviewRenderer.render(
                            document: sample, effects: effects, theme: theme),
                        theme: theme))
            } catch {
                let problem = NSTextField(
                    wrappingLabelWithString: String(
                        localized: "The preview can't be drawn: \(String(describing: error))"))
                problem.textColor = .systemRed
                return [problem]
            }
        }

        let header = NSTextField(
            labelWithString: String(
                localized:
                    "Before and after, for the first \(request.samples.count) matching documents:"))
        header.textColor = .secondaryLabelColor

        let cardStack = NSStackView(views: cards)
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 8
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(cardStack)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document
        NSLayoutConstraint.activate([
            cardStack.topAnchor.constraint(equalTo: document.topAnchor),
            cardStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            cardStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            cardStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 260),
        ])
        for card in cards {
            card.widthAnchor.constraint(equalTo: cardStack.widthAnchor, constant: -16).isActive =
                true
        }
        return [header, scroll]
    }

    // MARK: - Actions

    @objc private func applyAction(_ sender: Any?) {
        guard !needsTypedConfirmation || confirmField.stringValue == action.request.collection
        else { return }
        rejectButton.isEnabled = false
        applyButton.isEnabled = false
        confirmField.isEnabled = false
        statusLabel.stringValue = String(localized: "Applying…")
        statusLabel.textColor = .labelColor
        statusLabel.isHidden = false
        PendingActions.shared.apply(action)
    }

    @objc private func rejectAction(_ sender: Any?) {
        PendingActions.shared.reject(action)
    }

    @objc private func closeAction(_ sender: Any?) {
        close()
    }

    func controlTextDidChange(_ notification: Notification) {
        applyButton.isEnabled = confirmField.stringValue == action.request.collection
    }

    func windowWillClose(_ notification: Notification) {
        // Closing without a decision is a rejection.
        PendingActions.shared.reject(action)
    }

    /// Called once the action is decided.
    func show(_ outcome: PendingActions.Outcome) {
        switch outcome {
        case .rejected, .expired, .withdrawn:
            close()
        case .applied(let matched, let modified, let errors):
            showResult(
                errors.isEmpty
                    ? String(localized: "Applied: \(matched) matched, \(modified) modified.")
                    : String(
                        localized:
                            "Applied with errors: \(matched) matched, \(modified) modified. \(errors.joined(separator: " "))"
                    ),
                failed: !errors.isEmpty)
        case .failed(let message):
            showResult(String(localized: "Not applied: \(message)"), failed: true)
        }
    }

    private func showResult(_ text: String, failed: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = failed ? .systemRed : .labelColor
        statusLabel.isHidden = false
        rejectButton.isHidden = true
        applyButton.isHidden = true
        closeButton.isHidden = false
        closeButton.keyEquivalent = "\r"
        if let content = window?.contentView {
            window?.setContentSize(content.fittingSize)
        }
    }
}

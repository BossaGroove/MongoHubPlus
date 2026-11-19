import AppKit
import BSON
import ExtendedJSON

/// The window that shows a change an assistant asked for (internal
/// mcp-tools.md §0, §7 steps 8 and 9): exactly what will run, how many
/// documents it touches, and a preview, before and after for an update, the
/// documents themselves for a deletion. Nothing runs until the user clicks
/// Apply Update or Delete with the pointer:
/// - That button is never the default button, has no key equivalent, and
///   refuses keyboard focus, so neither Return nor Space (with keyboard
///   navigation on) can press it.
/// - Esc, Reject and the close button all reject.
/// - A filter that matches every document keeps it disabled until the user
///   types the collection's name.
@MainActor
final class PendingActionWindowController: NSWindowController, NSWindowDelegate,
    NSTextFieldDelegate
{
    private let action: PendingActions.Action
    private let rejectButton = NSButton(
        title: String(localized: "Reject"), target: nil, action: nil)
    private let applyButton = NSButton(title: "", target: nil, action: nil)
    private let closeButton = NSButton(title: String(localized: "Close"), target: nil, action: nil)
    private let confirmField = NSTextField(string: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var needsTypedConfirmation: Bool { action.request.filter.isEmpty }

    private var isDelete: Bool {
        if case .delete = action.request.kind { return true }
        return false
    }
    private var applyTitle: String {
        isDelete ? String(localized: "Delete") : String(localized: "Apply Update")
    }

    init(action: PendingActions.Action) {
        self.action = action
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title =
            isDelete
            ? String(localized: "Deletion Requested by an AI Assistant")
            : String(localized: "Update Requested by an AI Assistant")
        window.isReleasedWhenClosed = false
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
            labelWithString: isDelete
                ? String(localized: "An AI assistant wants to delete documents")
                : String(localized: "An AI assistant wants to update documents"))
        headline.font = .boldSystemFont(ofSize: 15)

        let expires = action.expiresAt.formatted(date: .omitted, time: .shortened)
        let subline = NSTextField(
            wrappingLabelWithString: isDelete
                ? String(
                    localized:
                        "Nothing is deleted unless you click Delete. Deleted documents can't be recovered. If you don't answer, the request is rejected at \(expires)."
                )
                : String(
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
        if isDelete { affectsField.textColor = .systemRed }

        var gridRows: [[NSView]] = [
            [label(String(localized: "Connection:")), value(request.connectionName)],
            [
                label(String(localized: "Collection:")),
                value("\(request.database).\(request.collection)", monospaced: true),
            ],
            [label(String(localized: "Filter:")), value(request.filterText, monospaced: true)],
        ]
        if case .update(let text, _) = request.kind {
            gridRows.append([label(String(localized: "Update:")), value(text, monospaced: true)])
        }
        gridRows.append(
            [
                label(isDelete ? String(localized: "Deletes:") : String(localized: "Affects:")),
                affectsField,
            ])
        let grid = NSGridView(views: gridRows)
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
                        "This filter matches every document in the collection. Type the collection's name, \(request.collection), to enable \(applyTitle):"
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

        applyButton.title = applyTitle
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

    /// The sampled documents: for an update, the Update pane's preview (the
    /// change marked on each, old value struck through in red, new value in
    /// green); for a deletion, the documents as they are, in red-edged cards.
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
        let header: NSTextField
        switch request.kind {
        case .update(_, let update):
            for sample in request.samples {
                do {
                    var effects = try UpdatePreview.effects(of: update, on: sample)
                    effects += UpdatePreview.renameAdditions(of: update, on: sample)
                    cards.append(
                        UpdatePreviewRenderer.card(
                            for: UpdatePreviewRenderer.render(
                                document: sample, effects: effects, theme: theme),
                            theme: theme))
                } catch {
                    let problem = NSTextField(
                        wrappingLabelWithString: String(
                            localized:
                                "The preview can't be drawn: \(String(describing: error))"))
                    problem.textColor = .systemRed
                    return [problem]
                }
            }
            header = NSTextField(
                labelWithString: String(
                    localized:
                        "Before and after, for the first \(request.samples.count) matching documents:"
                ))
            header.textColor = .secondaryLabelColor
        case .delete:
            for sample in request.samples {
                cards.append(
                    UpdatePreviewRenderer.card(
                        for: UpdatePreviewRenderer.render(
                            document: sample, effects: [], theme: theme),
                        theme: theme, border: .systemRed))
            }
            header = NSTextField(
                labelWithString: request.multi
                    ? String(
                        localized:
                            "Documents that will be deleted, the first \(request.samples.count) shown:"
                    )
                    : String(localized: "The first matching document right now:"))
            header.textColor = .systemRed
        }

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
        statusLabel.stringValue =
            isDelete ? String(localized: "Deleting…") : String(localized: "Applying…")
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
        PendingActions.shared.windowClosed(action)
    }

    /// Called once the action is decided.
    func show(_ outcome: PendingActions.Outcome) {
        switch outcome {
        case .rejected, .expired, .withdrawn:
            close()
        case .updated(let matched, let modified, let errors):
            showResult(
                errors.isEmpty
                    ? String(localized: "Applied: \(matched) matched, \(modified) modified.")
                    : String(
                        localized:
                            "Applied with errors: \(matched) matched, \(modified) modified. \(errors.joined(separator: " "))"
                    ),
                failed: !errors.isEmpty)
        case .deleted(let count, let errors):
            showResult(
                errors.isEmpty
                    ? String(localized: "Applied: \(count) deleted.")
                    : String(
                        localized:
                            "Applied with errors: \(count) deleted. \(errors.joined(separator: " "))"
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

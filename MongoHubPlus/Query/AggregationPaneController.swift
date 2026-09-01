import AppKit
import BSON
import ExtendedJSON

/// The Aggregation sub-tab (feature 3.17, owner request 2026-09-01): a
/// Compass-style stage builder (stage list + per-stage editor + live
/// preview after the selected stage) with a Text mode for the raw pipeline.
/// Run executes the full enabled pipeline; previews strip $out/$merge and
/// append $limit.
@MainActor
final class AggregationPaneController: NSViewController, NSTextViewDelegate {
    private static let previewLimit = 10
    private static let modeDefaultsKey = "aggregationEditorMode"

    private let context: QueryPaneContext
    private let pipelineHighlighter = JSONHighlighter()
    private let bodyHighlighter = JSONHighlighter()
    private let optionsHighlighter = JSONHighlighter()

    private var stages: [AggregationStage] = []
    private var previewTask: Task<Void, Never>?

    private let modeControl = NSSegmentedControl(
        labels: [String(localized: "Stages"), String(localized: "Text")],
        trackingMode: .selectOne, target: nil, action: nil)
    private var stagesContainer: NSView!
    private var textContainer: NSView!
    private let stageTable = NSTableView()
    private var addStageButton: NSButton!
    private var removeStageButton: NSButton!
    private let operatorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let customOperatorField = NSTextField(string: "")
    private var previewButton: NSButton!
    private var bodyTextView: NSTextView!
    private var pipelineTextView: NSTextView!
    private var optionsTextView: NSTextView!
    private let spinner = QueryPaneUI.spinner()
    private let outline = DocumentOutlineViewController(
        options: .init(
            showsFooter: true, showsRemoveButton: false, showsPagination: false,
            autosaveName: "aggregation-outline"))

    init(context: QueryPaneContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesChanged), name: .preferencesDidChange,
            object: nil)
    }

    @objc private func preferencesChanged() {
        guard isViewLoaded else { return }
        pipelineHighlighter.refresh(pipelineTextView)
        bodyHighlighter.refresh(bodyTextView)
        optionsHighlighter.refresh(optionsTextView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var initialFirstResponder: NSView {
        isTextMode ? pipelineTextView : bodyTextView
    }

    private var isTextMode: Bool { modeControl.selectedSegment == 1 }

    // MARK: - Layout

    override func loadView() {
        let container = NSView()

        // Top bar: mode toggle, explain, run
        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        modeControl.selectedSegment =
            UserDefaults.standard.string(forKey: Self.modeDefaultsKey) == "text" ? 1 : 0
        modeControl.translatesAutoresizingMaskIntoConstraints = false

        let explainButton = NSButton(
            title: String(localized: "Explain"), target: self, action: #selector(explainAction(_:)))
        explainButton.bezelStyle = .rounded
        explainButton.controlSize = .small
        explainButton.keyEquivalent = "r"
        explainButton.keyEquivalentModifierMask = [.command, .shift]
        explainButton.toolTip = String(localized: "Explain (⇧⌘R)")
        explainButton.translatesAutoresizingMaskIntoConstraints = false

        let runButton = QueryPaneUI.runButton(
            title: String(localized: "Run"), target: self, action: #selector(runAction(_:)))
        runButton.keyEquivalent = "r"
        runButton.keyEquivalentModifierMask = .command
        runButton.toolTip = String(localized: "Run (⌘R)")
        runButton.translatesAutoresizingMaskIntoConstraints = false

        // Stages mode: list column + editor column
        stageTable.headerView = nil
        stageTable.rowSizeStyle = .medium
        stageTable.style = .plain
        stageTable.allowsMultipleSelection = false
        let column = NSTableColumn(identifier: .init("stage"))
        stageTable.addTableColumn(column)
        stageTable.dataSource = self
        stageTable.delegate = self
        stageTable.registerForDraggedTypes([.string])
        let listScroll = NSScrollView()
        listScroll.documentView = stageTable
        listScroll.hasVerticalScroller = true
        listScroll.borderType = .bezelBorder
        listScroll.translatesAutoresizingMaskIntoConstraints = false

        addStageButton = NSButton(
            image: NSImage(named: NSImage.addTemplateName)!, target: self,
            action: #selector(addStageAction(_:)))
        addStageButton.toolTip = String(localized: "Add Stage")
        removeStageButton = NSButton(
            image: NSImage(named: NSImage.removeTemplateName)!, target: self,
            action: #selector(removeStageAction(_:)))
        removeStageButton.isEnabled = false
        let listButtons = NSStackView(views: [addStageButton, removeStageButton])
        listButtons.orientation = .horizontal
        listButtons.spacing = 4

        let listColumn = NSStackView(views: [listScroll, listButtons])
        listColumn.orientation = .vertical
        listColumn.alignment = .leading
        listColumn.spacing = 4
        listColumn.translatesAutoresizingMaskIntoConstraints = false
        listColumn.widthAnchor.constraint(equalToConstant: 170).isActive = true

        for name in AggregationStages.operators {
            operatorPopup.addItem(withTitle: name)
        }
        operatorPopup.addItem(withTitle: String(localized: "Custom…"))
        operatorPopup.target = self
        operatorPopup.action = #selector(operatorChanged(_:))
        customOperatorField.placeholderString = "$operator"
        customOperatorField.isHidden = true
        customOperatorField.delegate = self
        customOperatorField.widthAnchor.constraint(equalToConstant: 110).isActive = true
        previewButton = NSButton(
            title: String(localized: "Preview"), target: self, action: #selector(previewAction(_:)))
        previewButton.bezelStyle = .rounded
        previewButton.controlSize = .small
        let editorHeader = NSStackView(views: [
            operatorPopup, customOperatorField, NSView(), previewButton,
        ])
        editorHeader.orientation = .horizontal
        editorHeader.spacing = 6

        let (bodyScroll, body) = QueryPaneUI.jsonTextView(highlighter: bodyHighlighter)
        bodyTextView = body
        bodyTextView.delegate = self

        let editorColumn = NSStackView(views: [editorHeader, bodyScroll])
        editorColumn.orientation = .vertical
        editorColumn.alignment = .leading
        editorColumn.spacing = 4
        editorHeader.widthAnchor.constraint(equalTo: editorColumn.widthAnchor).isActive = true
        bodyScroll.widthAnchor.constraint(equalTo: editorColumn.widthAnchor).isActive = true

        let stagesStack = NSStackView(views: [listColumn, editorColumn])
        stagesStack.orientation = .horizontal
        stagesStack.spacing = 8
        stagesStack.translatesAutoresizingMaskIntoConstraints = false
        stagesContainer = NSView()
        stagesContainer.addSubview(stagesStack)
        NSLayoutConstraint.activate([
            stagesStack.topAnchor.constraint(equalTo: stagesContainer.topAnchor),
            stagesStack.leadingAnchor.constraint(equalTo: stagesContainer.leadingAnchor),
            stagesStack.trailingAnchor.constraint(equalTo: stagesContainer.trailingAnchor),
            stagesStack.bottomAnchor.constraint(equalTo: stagesContainer.bottomAnchor),
            listScroll.heightAnchor.constraint(
                equalTo: stagesStack.heightAnchor, constant: -28),
        ])

        // Text mode
        let (pipelineScroll, pipeline) = QueryPaneUI.jsonTextView(highlighter: pipelineHighlighter)
        pipelineTextView = pipeline
        pipelineTextView.delegate = self
        pipelineTextView.string = "[\n  {$match: {}},\n  {$limit: 100}\n]"
        pipelineHighlighter.highlight(pipelineTextView)
        textContainer = NSView()
        pipelineScroll.translatesAutoresizingMaskIntoConstraints = false
        textContainer.addSubview(pipelineScroll)
        NSLayoutConstraint.activate([
            pipelineScroll.topAnchor.constraint(equalTo: textContainer.topAnchor),
            pipelineScroll.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            pipelineScroll.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),
            pipelineScroll.bottomAnchor.constraint(equalTo: textContainer.bottomAnchor),
        ])

        // Options (shared by both modes)
        let optionsLabel = NSTextField(labelWithString: String(localized: "Options:"))
        optionsLabel.translatesAutoresizingMaskIntoConstraints = false
        let (optionsScroll, options) = QueryPaneUI.jsonTextView(highlighter: optionsHighlighter)
        optionsTextView = options
        optionsTextView.delegate = self
        optionsScroll.translatesAutoresizingMaskIntoConstraints = false

        outline.delegate = nil
        let outlineView = outline.view
        outlineView.translatesAutoresizingMaskIntoConstraints = false
        addChild(outline)

        stagesContainer.translatesAutoresizingMaskIntoConstraints = false
        textContainer.translatesAutoresizingMaskIntoConstraints = false
        for subview in [
            modeControl, explainButton, runButton, spinner, stagesContainer!, textContainer!,
            optionsLabel, optionsScroll, outlineView,
        ] {
            container.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            modeControl.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            modeControl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),

            runButton.centerYAnchor.constraint(equalTo: modeControl.centerYAnchor),
            runButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            explainButton.centerYAnchor.constraint(equalTo: modeControl.centerYAnchor),
            explainButton.trailingAnchor.constraint(equalTo: runButton.leadingAnchor, constant: -8),
            spinner.centerYAnchor.constraint(equalTo: modeControl.centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: explainButton.leadingAnchor, constant: -10),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),

            stagesContainer.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 6),
            stagesContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            stagesContainer.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -8),
            stagesContainer.heightAnchor.constraint(equalToConstant: 190),

            textContainer.topAnchor.constraint(equalTo: stagesContainer.topAnchor),
            textContainer.leadingAnchor.constraint(equalTo: stagesContainer.leadingAnchor),
            textContainer.trailingAnchor.constraint(equalTo: stagesContainer.trailingAnchor),
            textContainer.bottomAnchor.constraint(equalTo: stagesContainer.bottomAnchor),

            optionsLabel.topAnchor.constraint(equalTo: stagesContainer.bottomAnchor, constant: 6),
            optionsLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            optionsScroll.centerYAnchor.constraint(equalTo: optionsLabel.centerYAnchor),
            optionsScroll.leadingAnchor.constraint(
                equalTo: optionsLabel.trailingAnchor, constant: 6),
            optionsScroll.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -8),
            optionsScroll.heightAnchor.constraint(equalToConstant: 40),

            outlineView.topAnchor.constraint(equalTo: optionsScroll.bottomAnchor, constant: 6),
            outlineView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            outlineView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            outlineView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container

        if stages.isEmpty {
            stages = [AggregationStage(
                operatorName: "$match", bodyText: AggregationStages.template(for: "$match"))]
        }
        applyMode()
        stageTable.reloadData()
        selectStage(0)
        processHooks()
    }

    // MARK: - Mode switching

    @objc private func modeChanged(_ sender: Any?) {
        if isTextMode {
            // Stages → Text: disabled flags are lost (owner-accepted).
            if stages.contains(where: { !$0.enabled }) {
                let alert = NSAlert()
                alert.messageText = String(localized: "Convert to text mode?")
                alert.informativeText = String(
                    localized: "Disabled stages lose their disabled state in text mode.")
                alert.addButton(withTitle: String(localized: "Convert"))
                alert.addButton(withTitle: String(localized: "Cancel"))
                guard alert.runModal() == .alertFirstButtonReturn else {
                    modeControl.selectedSegment = 0
                    return
                }
            }
            do {
                pipelineTextView.string = try AggregationStages.text(from: stages)
                pipelineHighlighter.highlight(pipelineTextView)
            } catch {
                QueryPaneUI.alertSheet(
                    in: view, title: String(localized: "Error in Pipeline"),
                    message: String(describing: error))
                modeControl.selectedSegment = 0
                return
            }
        } else {
            // Text → Stages
            do {
                stages = try AggregationStages.stages(fromText: pipelineTextView.string)
                if stages.isEmpty {
                    stages = [AggregationStage(
                        operatorName: "$match",
                        bodyText: AggregationStages.template(for: "$match"))]
                }
                stageTable.reloadData()
                selectStage(0)
            } catch {
                QueryPaneUI.alertSheet(
                    in: view, title: String(localized: "Error in Pipeline"),
                    message: String(describing: error))
                modeControl.selectedSegment = 1
                return
            }
        }
        applyMode()
    }

    private func applyMode() {
        stagesContainer.isHidden = isTextMode
        textContainer.isHidden = !isTextMode
        UserDefaults.standard.set(isTextMode ? "text" : "stages", forKey: Self.modeDefaultsKey)
    }

    // MARK: - Stage list

    private var selectedStageIndex: Int? {
        let row = stageTable.selectedRow
        return stages.indices.contains(row) ? row : nil
    }

    private func selectStage(_ index: Int) {
        guard stages.indices.contains(index) else { return }
        stageTable.selectRowIndexes([index], byExtendingSelection: false)
        loadStageEditor(index)
    }

    private func loadStageEditor(_ index: Int) {
        let stage = stages[index]
        if let item = operatorPopup.item(withTitle: stage.operatorName) {
            operatorPopup.select(item)
            customOperatorField.isHidden = true
        } else {
            operatorPopup.selectItem(at: operatorPopup.numberOfItems - 1)  // Custom…
            customOperatorField.isHidden = false
            customOperatorField.stringValue = stage.operatorName
        }
        bodyTextView.string = stage.bodyText
        bodyHighlighter.highlight(bodyTextView)
    }

    @objc private func addStageAction(_ sender: Any?) {
        let menu = NSMenu()
        for name in AggregationStages.operators {
            let item = menu.addItem(
                withTitle: name, action: #selector(addStageFromMenu(_:)), keyEquivalent: "")
            item.target = self
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: addStageButton)
    }

    @objc private func addStageFromMenu(_ sender: NSMenuItem) {
        let name = sender.title
        let insertAt = (selectedStageIndex.map { $0 + 1 }) ?? stages.count
        stages.insert(
            AggregationStage(operatorName: name, bodyText: AggregationStages.template(for: name)),
            at: insertAt)
        stageTable.reloadData()
        selectStage(insertAt)
    }

    @objc private func removeStageAction(_ sender: Any?) {
        guard let index = selectedStageIndex else { return }
        stages.remove(at: index)
        stageTable.reloadData()
        if stages.isEmpty {
            bodyTextView.string = ""
            removeStageButton.isEnabled = false
        } else {
            selectStage(min(index, stages.count - 1))
        }
    }

    @objc private func stageEnabledToggled(_ sender: NSButton) {
        guard stages.indices.contains(sender.tag) else { return }
        stages[sender.tag].enabled = sender.state == .on
        stageTable.reloadData(
            forRowIndexes: [sender.tag], columnIndexes: [0])
        if let selected = selectedStageIndex, sender.tag <= selected {
            schedulePreview()
        }
    }

    @objc private func operatorChanged(_ sender: Any?) {
        guard let index = selectedStageIndex else { return }
        let isCustom = operatorPopup.indexOfSelectedItem == operatorPopup.numberOfItems - 1
        customOperatorField.isHidden = !isCustom
        if isCustom {
            view.window?.makeFirstResponder(customOperatorField)
        } else if let title = operatorPopup.selectedItem?.title {
            let previous = stages[index]
            stages[index].operatorName = title
            // Fresh template when the body was still the old operator's template.
            if previous.bodyText == AggregationStages.template(for: previous.operatorName) {
                stages[index].bodyText = AggregationStages.template(for: title)
                bodyTextView.string = stages[index].bodyText
                bodyHighlighter.highlight(bodyTextView)
            }
            stageTable.reloadData(forRowIndexes: [index], columnIndexes: [0])
            schedulePreview()
        }
    }

    // MARK: - Preview / Run / Explain

    @objc private func previewAction(_ sender: Any?) {
        schedulePreview()
    }

    private func schedulePreview() {
        guard !isTextMode, let index = selectedStageIndex,
            let session = context.session()
        else { return }
        previewTask?.cancel()
        let stage = stages[index]
        let pipeline: Document
        do {
            pipeline = try AggregationStages.previewDocument(
                from: stages, upTo: index, limit: Self.previewLimit)
        } catch {
            outline.displayError(
                String(localized: "Stage \(index + 1) (\(stage.operatorName)): ")
                    + String(describing: error))
            return
        }
        spinner.startAnimation(nil)
        previewTask = Task {
            do {
                let documents = try await session.aggregate(
                    database: context.database, collection: context.collection,
                    pipeline: pipeline, options: nil)
                guard !Task.isCancelled else { return }
                self.spinner.stopAnimation(nil)
                self.outline.display(
                    documents: documents,
                    label: String(
                        localized:
                            "Preview after stage \(index + 1) (\(stage.operatorName)) — first \(Self.previewLimit)"
                    ))
            } catch {
                guard !Task.isCancelled else { return }
                self.spinner.stopAnimation(nil)
                self.outline.displayError(String(describing: error))
            }
        }
    }

    private func runnablePipeline() throws -> Document {
        if isTextMode {
            let text = pipelineTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return Document(isArray: true) }
            let parsed = try ExtendedJSON.parseDocument(text)
            if parsed.isArray { return parsed }
            var pipeline = Document(isArray: true)
            pipeline["0"] = parsed  // single stage without [ ] (legacy nicety)
            return pipeline
        }
        return try AggregationStages.pipelineDocument(from: stages, onlyEnabled: true)
    }

    private func parsedOptions() throws -> Document? {
        let text = optionsTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let parsed = try ExtendedJSON.parseDocument(text)
        guard !parsed.isArray else { throw EJSONError("Options must be a document") }
        return parsed
    }

    @objc func runAction(_ sender: Any?) {
        guard let session = context.session() else { return }
        let pipeline: Document
        do {
            pipeline = try runnablePipeline()
        } catch {
            QueryPaneUI.alertSheet(
                in: view, title: String(localized: "Error in Pipeline"),
                message: String(describing: error))
            return
        }
        let options: Document?
        do {
            options = try parsedOptions()
        } catch {
            QueryPaneUI.alertSheet(
                in: view, title: String(localized: "Error in Options"),
                message: String(describing: error))
            return
        }

        previewTask?.cancel()
        spinner.startAnimation(nil)
        Task {
            do {
                let documents = try await session.aggregate(
                    database: context.database, collection: context.collection,
                    pipeline: pipeline, options: options)
                self.spinner.stopAnimation(nil)
                self.outline.display(
                    documents: documents,
                    label: documents.count == 1
                        ? String(localized: "1 document")
                        : String(localized: "\(documents.count) documents"))
            } catch {
                self.spinner.stopAnimation(nil)
                self.outline.displayError(String(describing: error))
                QueryPaneUI.alertSheet(
                    in: self.view, title: String(localized: "Aggregation Failed"),
                    message: String(describing: error))
            }
        }
    }

    @objc func explainAction(_ sender: Any?) {
        guard let session = context.session(), let window = view.window else { return }
        do {
            var target = Document()
            target["aggregate"] = context.collection
            target["pipeline"] = try runnablePipeline()
            target["cursor"] = Document()
            let sheet = ExplainSheetController(
                database: context.database, explainTarget: target, session: session)
            explainSheet = sheet
            if let sheetWindow = sheet.window {
                window.beginSheet(sheetWindow) { [weak self] _ in
                    self?.explainSheet = nil
                }
            }
        } catch {
            QueryPaneUI.alertSheet(
                in: view, title: String(localized: "Error in Pipeline"),
                message: String(describing: error))
        }
    }

    private var explainSheet: ExplainSheetController?

    // MARK: - Text view sync

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        switch textView {
        case pipelineTextView: pipelineHighlighter.highlight(textView)
        case optionsTextView: optionsHighlighter.highlight(textView)
        case bodyTextView:
            bodyHighlighter.highlight(textView)
            if let index = selectedStageIndex {
                stages[index].bodyText = textView.string
            }
        default: break
        }
    }

    // MARK: - Verification hooks

    private func processHooks() {
        if let encoded = UserDefaults.standard.string(forKey: "MAAggStages64"),
            let data = Data(base64Encoded: encoded),
            let text = String(data: data, encoding: .utf8),
            let parsed = try? AggregationStages.stages(fromText: text)
        {
            modeControl.selectedSegment = 0
            applyMode()
            stages = parsed
            stageTable.reloadData()
            selectStage(0)
        }
        let selectKey = UserDefaults.standard.integer(forKey: "MAAggSelect")
        if selectKey > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.selectStage(selectKey - 1)
                self?.schedulePreview()
            }
        }
        if UserDefaults.standard.bool(forKey: "MAAggExplain") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.explainAction(nil)
            }
        }
    }
}

// MARK: - Stage table

extension AggregationPaneController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        stages.count
    }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        let stage = stages[row]
        let cell = NSTableCellView()
        let checkbox = NSButton(checkboxWithTitle: "", target: self,
                                action: #selector(stageEnabledToggled(_:)))
        checkbox.state = stage.enabled ? .on : .off
        checkbox.tag = row
        // Fixed-width number column so numbers and operators align.
        let numberLabel = NSTextField(labelWithString: "\(row + 1)")
        numberLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        numberLabel.textColor = .secondaryLabelColor
        numberLabel.alignment = .right
        numberLabel.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let label = NSTextField(labelWithString: stage.operatorName)
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = stage.enabled ? .labelColor : .tertiaryLabelColor
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        label.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [checkbox, numberLabel, label])
        stack.orientation = .horizontal
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeStageButton.isEnabled = selectedStageIndex != nil
        if let index = selectedStageIndex {
            loadStageEditor(index)
            schedulePreview()
        }
    }

    // Drag to reorder
    func tableView(
        _ tableView: NSTableView, pasteboardWriterForRow row: Int
    ) -> NSPasteboardWriting? {
        NSString(string: String(row))
    }

    func tableView(
        _ tableView: NSTableView, validateDrop info: NSDraggingInfo,
        proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        dropOperation == .above ? .move : []
    }

    func tableView(
        _ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let text = info.draggingPasteboard.string(forType: .string),
            let source = Int(text), stages.indices.contains(source)
        else { return false }
        var destination = row
        if destination > source { destination -= 1 }
        let stage = stages.remove(at: source)
        stages.insert(stage, at: destination)
        stageTable.reloadData()
        selectStage(destination)
        return true
    }
}

extension AggregationPaneController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === customOperatorField,
            let index = selectedStageIndex
        else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard name.hasPrefix("$"), name.count > 1 else { return }
        stages[index].operatorName = name
        stageTable.reloadData(forRowIndexes: [index], columnIndexes: [0])
        schedulePreview()
    }
}

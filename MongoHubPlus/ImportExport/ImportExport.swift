import AppKit
import BSON
import ExtendedJSON
import MongoService
import UniformTypeIdentifiers

/// The import/export progress sheet (legacy MHImportExportFeedback):
/// determinate bar + Cancel.
@MainActor
final class ProgressSheetController: NSWindowController {
    private let label = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private var task: Task<Void, Never>?

    convenience init(title: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 110),
            styleMask: [.titled], backing: .buffered, defer: false)
        self.init(window: window)

        label.stringValue = title
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        bar.isIndeterminate = true
        bar.minValue = 0
        bar.maxValue = 1
        bar.startAnimation(nil)
        bar.translatesAutoresizingMaskIntoConstraints = false
        let cancelButton = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancelAction(_:)))
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(label)
        content.addSubview(bar)
        content.addSubview(cancelButton)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            bar.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            cancelButton.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 10),
            cancelButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            cancelButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        window.contentView = content
    }

    func begin(on parent: NSWindow, task: Task<Void, Never>) {
        self.task = task
        guard let window else { return }
        parent.beginSheet(window)
    }

    func setProgress(_ fraction: Double, detail: String) {
        if bar.isIndeterminate {
            bar.isIndeterminate = false
            bar.stopAnimation(nil)
        }
        bar.doubleValue = fraction
        label.stringValue = detail
    }

    func finish() {
        guard let window else { return }
        window.sheetParent?.endSheet(window)
    }

    @objc private func cancelAction(_ sender: Any?) {
        task?.cancel()
    }
}

/// Save-panel accessory: Format popup that keeps the filename extension in
/// sync (JSON Lines = lossless canonical EJSON; CSV = flattened, lossy; BSON =
/// a mongodump-layout folder).
@MainActor
private final class ExportFormatAccessory: NSView {
    enum Format {
        case jsonLines, csv, bson
    }

    private weak var panel: NSSavePanel?
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)

    var selectedFormat: Format {
        switch popup.indexOfSelectedItem {
        case 1: return .csv
        case 2: return .bson
        default: return .jsonLines
        }
    }

    init(panel: NSSavePanel) {
        self.panel = panel
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 44))
        popup.addItems(withTitles: [
            String(localized: "JSON Lines (lossless)"), String(localized: "CSV (flattened, lossy)"),
            String(localized: "BSON folder (for mongorestore)"),
        ])
        popup.target = self
        popup.action = #selector(formatChanged(_:))
        let label = NSTextField(labelWithString: String(localized: "Format:"))
        let stack = NSStackView(views: [label, popup])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func formatChanged(_ sender: Any?) {
        guard let panel else { return }
        // The panel swaps the visible extension itself — assigning
        // nameFieldStringValue doesn't reach the out-of-process (sandboxed)
        // panel reliably. BSON writes a folder, so it wants no extension.
        switch selectedFormat {
        case .jsonLines: panel.allowedContentTypes = [Self.jsonLinesType]
        case .csv: panel.allowedContentTypes = [.commaSeparatedText]
        case .bson: panel.allowedContentTypes = []
        }
    }

    static let jsonLinesType = UTType(exportedAs: "com.bossagroove.mongohubplus.jsonl")
}

/// JSON-Lines export/import (feature-spec 5.1/5.2): canonical Extended JSON,
/// one document per line — lossless, mongoexport/mongoimport compatible.
@MainActor
enum ImportExport {
    /// What to export: the whole collection, or the current query's full
    /// matching set (criteria/sort/projection honored; skip/limit are not —
    /// results export means *all* matches, not the visible page).
    struct ExportQuery {
        var filter = Document()
        var sort: Document?
        var projection: Document?

        func findCommand(collection: String) -> Document {
            var command = Document()
            command["find"] = collection
            if !filter.isEmpty { command["filter"] = filter }
            if let sort, !sort.isEmpty { command["sort"] = sort }
            if let projection, !projection.isEmpty { command["projection"] = projection }
            command["batchSize"] = Int32(1000)
            return command
        }
    }

    static func exportCollection(
        database: String, collection: String, session: ConnectionSession, window: NSWindow
    ) {
        presentExportPanel(
            suggestedName: "\(database)-\(collection)", database: database,
            collection: collection, query: ExportQuery(), session: session, window: window)
    }

    /// Export the current query's full matching set (owner request 2026-09-01).
    static func exportResults(
        database: String, collection: String, query: ExportQuery,
        session: ConnectionSession, window: NSWindow
    ) {
        presentExportPanel(
            suggestedName: "\(database)-\(collection)-results", database: database,
            collection: collection, query: query, session: session, window: window)
    }

    private static func presentExportPanel(
        suggestedName: String, database: String, collection: String, query: ExportQuery,
        session: ConnectionSession, window: NSWindow
    ) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(suggestedName).jsonl"
        panel.allowedContentTypes = [ExportFormatAccessory.jsonLinesType]
        panel.canCreateDirectories = true
        let accessory = ExportFormatAccessory(panel: panel)
        panel.accessoryView = accessory
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            // Trust the Format popup rather than whatever extension ended up
            // in the name field.
            switch accessory.selectedFormat {
            case .csv:
                runExportCSV(
                    to: url, database: database, collection: collection, query: query,
                    session: session, window: window)
            case .bson:
                runExportBSON(
                    to: url, database: database, collection: collection, query: query,
                    session: session, window: window)
            case .jsonLines:
                runExport(
                    to: url, database: database, collection: collection, query: query,
                    session: session, window: window)
            }
        }
    }

    private static func runExport(
        to url: URL, database: String, collection: String, query: ExportQuery,
        session: ConnectionSession, window: NSWindow
    ) {
        let sheet = ProgressSheetController(title: String(localized: "Exporting \(database).\(collection)…"))
        let task = Task {
            var exported = 0
            do {
                let total = try await session.count(
                    database: database, collection: collection, filter: query.filter)
                FileManager.default.createFile(atPath: url.path, contents: nil)
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }

                let command = query.findCommand(collection: collection)
                for try await batch in session.cursorBatches(
                    command: command, onDatabase: database)
                {
                    var chunk = Data()
                    for document in batch {
                        let line = try ExtendedJSON.stringify(document, format: .canonical)
                        chunk.append(Data(line.utf8))
                        chunk.append(0x0A)
                    }
                    try handle.write(contentsOf: chunk)
                    exported += batch.count
                    sheet.setProgress(
                        total > 0 ? Double(exported) / Double(total) : 1,
                        detail: String(localized: "Exported \(exported) of \(total) documents…"))
                }
                sheet.finish()
                presentInfo(
                    window: window, title: String(localized: "Export Complete"),
                    message: String(localized: "\(exported) documents exported to \(url.lastPathComponent)."))
            } catch is CancellationError {
                sheet.finish()
            } catch {
                sheet.finish()
                presentInfo(
                    window: window, title: String(localized: "Export Failed"),
                    message: String(localized: "After \(exported) documents: \(String(describing: error))"))
            }
        }
        sheet.begin(on: window, task: task)
    }

    /// Writes what `mongodump` writes: raw BSON documents concatenated into
    /// `<folder>/<database>/<collection>.bson`, beside the
    /// `<collection>.metadata.json` that carries the indexes. The chosen
    /// folder can be handed straight to `mongorestore`.
    private static func runExportBSON(
        to url: URL, database: String, collection: String, query: ExportQuery,
        session: ConnectionSession, window: NSWindow
    ) {
        let sheet = ProgressSheetController(
            title: String(localized: "Exporting \(database).\(collection)…"))
        let task = Task {
            var exported = 0
            do {
                let total = try await session.count(
                    database: database, collection: collection, filter: query.filter)
                let databaseDirectory = url.appendingPathComponent(database)
                try FileManager.default.createDirectory(
                    at: databaseDirectory, withIntermediateDirectories: true)
                let bsonURL = databaseDirectory.appendingPathComponent("\(collection).bson")
                FileManager.default.createFile(atPath: bsonURL.path, contents: nil)
                let handle = try FileHandle(forWritingTo: bsonURL)
                defer { try? handle.close() }

                let command = query.findCommand(collection: collection)
                for try await batch in session.cursorBatches(
                    command: command, onDatabase: database)
                {
                    var chunk = Data()
                    // A .bson file is documents back to back — each one already
                    // carries its own length, so there is nothing between them.
                    for document in batch { chunk.append(document.makeData()) }
                    try handle.write(contentsOf: chunk)
                    exported += batch.count
                    sheet.setProgress(
                        total > 0 ? Double(exported) / Double(total) : 1,
                        detail: String(localized: "Exported \(exported) of \(total) documents…"))
                }

                let metadata = try await bsonMetadata(
                    database: database, collection: collection, session: session)
                try Data(metadata.utf8).write(
                    to: databaseDirectory.appendingPathComponent("\(collection).metadata.json"))

                sheet.finish()
                presentInfo(
                    window: window, title: String(localized: "Export Complete"),
                    message: String(
                        localized:
                            "\(exported) documents exported to \(url.lastPathComponent). Restore with: mongorestore \(url.lastPathComponent)"
                    ))
            } catch is CancellationError {
                sheet.finish()
            } catch {
                sheet.finish()
                presentInfo(
                    window: window, title: String(localized: "Export Failed"),
                    message: String(localized: "After \(exported) documents: \(String(describing: error))"))
            }
        }
        sheet.begin(on: window, task: task)
    }

    /// The sidecar `mongorestore` reads to recreate indexes and collection
    /// options. Canonical Extended JSON, matching mongodump byte for byte in
    /// shape; `uuid` is included when the server reports one (restores work
    /// without it, but `--preserveUUID` needs it).
    private static func bsonMetadata(
        database: String, collection: String, session: ConnectionSession
    ) async throws -> String {
        var command = Document()
        command["listIndexes"] = collection
        let specs = try await session.collectCursor(command: command, onDatabase: database)

        var indexes = Document(isArray: true)
        for (position, spec) in specs.enumerated() {
            var cleaned = Document()
            // `ns` is a legacy server field mongodump does not carry over.
            for pair in spec.pairs where pair.key != "ns" { cleaned[pair.key] = pair.value }
            indexes[String(position)] = cleaned
        }

        var metadata = Document()
        metadata["indexes"] = indexes
        let info = try? await session.collectionInfo(database: database, collection: collection)
        if let details = info?["info"] as? Document, let uuid = details["uuid"] as? Binary {
            metadata["uuid"] = uuid.data.map { String(format: "%02x", $0) }.joined()
        }
        if let options = info?["options"] as? Document, !options.isEmpty {
            metadata["options"] = options
        }
        metadata["collectionName"] = collection
        metadata["type"] = "collection"
        return try ExtendedJSON.stringify(metadata, format: .canonical)
    }

    static func importCollection(
        database: String, collection: String, session: ConnectionSession, window: NSWindow
    ) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a JSON-Lines (.jsonl) or CSV (.csv) file")
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            if url.pathExtension.lowercased() == "csv" {
                runImportCSV(
                    from: url, database: database, collection: collection, session: session,
                    window: window)
            } else {
                runImport(
                    from: url, database: database, collection: collection, session: session,
                    window: window)
            }
        }
    }

    private static func runImport(
        from url: URL, database: String, collection: String, session: ConnectionSession,
        window: NSWindow
    ) {
        let sheet = ProgressSheetController(title: String(localized: "Importing \(url.lastPathComponent)…"))
        let task = Task {
            var imported = 0
            var lineNumber = 0
            do {
                let totalBytes =
                    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
                    ?? nil
                var readBytes = 0
                var pending: [Document] = []

                func flush() async throws {
                    guard !pending.isEmpty else { return }
                    var documents = Document(isArray: true)
                    for (index, doc) in pending.enumerated() {
                        documents[String(index)] = doc
                    }
                    var command = Document()
                    command["insert"] = collection
                    command["documents"] = documents
                    _ = try await session.runCommand(command, onDatabase: database)
                    imported += pending.count
                    pending.removeAll()
                }

                for try await line in url.lines {
                    try Task.checkCancellation()
                    lineNumber += 1
                    readBytes += line.utf8.count + 1
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { continue }
                    let document = try ExtendedJSON.parseDocument(trimmed)
                    guard !document.isArray else {
                        throw EJSONError("Line \(lineNumber): expected one document per line")
                    }
                    pending.append(document)
                    if pending.count >= 100 {
                        try await flush()
                        if let totalBytes, totalBytes > 0 {
                            sheet.setProgress(
                                Double(readBytes) / Double(totalBytes),
                                detail: String(localized: "Imported \(imported) documents…"))
                        }
                    }
                }
                try await flush()
                sheet.finish()
                presentInfo(
                    window: window, title: String(localized: "Import Complete"),
                    message: String(localized: "\(imported) documents imported into \(database).\(collection)."))
            } catch is CancellationError {
                sheet.finish()
            } catch {
                sheet.finish()
                presentInfo(
                    window: window, title: String(localized: "Import Failed"),
                    message: String(
                        localized: "Line \(lineNumber) (after \(imported) imported documents): \(String(describing: error))"))
            }
        }
        sheet.begin(on: window, task: task)
    }

    // MARK: - CSV (feature-spec 5.3 — lossy interchange; JSON-Lines is the
    // lossless path. Owner decisions: auto-flattened dotted columns,
    // spreadsheet-friendly cells, per-cell EJSON typing on import.)

    private static func runExportCSV(
        to url: URL, database: String, collection: String, query: ExportQuery,
        session: ConnectionSession, window: NSWindow
    ) {
        let sheet = ProgressSheetController(
            title: String(localized: "Exporting \(database).\(collection) as CSV…"))
        let task = Task {
            var exported = 0
            do {
                let total = try await session.count(
                    database: database, collection: collection, filter: query.filter)
                let command = query.findCommand(collection: collection)

                // Pass 1: the column set is the union of all field paths,
                // ordered by first appearance — needs a scan of its own.
                var columns: [String] = []
                var columnIndex: [String: Int] = [:]
                var scanned = 0
                for try await batch in session.cursorBatches(
                    command: command, onDatabase: database)
                {
                    for document in batch {
                        for entry in CSV.flatten(document) where columnIndex[entry.path] == nil {
                            columnIndex[entry.path] = columns.count
                            columns.append(entry.path)
                        }
                    }
                    scanned += batch.count
                    sheet.setProgress(
                        total > 0 ? 0.5 * Double(scanned) / Double(total) : 0.5,
                        detail: String(localized: "Scanning fields… \(scanned) of \(total) documents"))
                }

                // Pass 2: stream rows.
                FileManager.default.createFile(atPath: url.path, contents: nil)
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.write(contentsOf: Data((CSV.encodeRow(columns) + "\r\n").utf8))
                for try await batch in session.cursorBatches(
                    command: command, onDatabase: database)
                {
                    var chunk = Data()
                    for document in batch {
                        var cells = [String](repeating: "", count: columns.count)
                        for entry in CSV.flatten(document) {
                            if let index = columnIndex[entry.path] {
                                cells[index] = CSV.cellText(entry.value)
                            }
                        }
                        chunk.append(Data((CSV.encodeRow(cells) + "\r\n").utf8))
                    }
                    try handle.write(contentsOf: chunk)
                    exported += batch.count
                    sheet.setProgress(
                        total > 0 ? 0.5 + 0.5 * Double(exported) / Double(total) : 1,
                        detail: String(localized: "Exported \(exported) of \(total) documents…"))
                }
                sheet.finish()
                presentInfo(
                    window: window, title: String(localized: "Export Complete"),
                    message:
                        "\(exported) documents (\(columns.count) columns) exported to \(url.lastPathComponent). CSV flattens types — use JSON Lines for lossless backups.")
            } catch is CancellationError {
                sheet.finish()
            } catch {
                sheet.finish()
                presentInfo(
                    window: window, title: String(localized: "Export Failed"),
                    message: String(localized: "After \(exported) documents: \(String(describing: error))"))
            }
        }
        sheet.begin(on: window, task: task)
    }

    private static func runImportCSV(
        from url: URL, database: String, collection: String, session: ConnectionSession,
        window: NSWindow
    ) {
        let sheet = ProgressSheetController(title: String(localized: "Importing \(url.lastPathComponent)…"))
        let task = Task {
            var imported = 0
            var rowNumber = 0
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let rows = CSV.parse(text)
                guard let headers = rows.first, !headers.allSatisfy(\.isEmpty) else {
                    throw EJSONError("The CSV file has no header row")
                }
                var pending: [Document] = []

                func flush() async throws {
                    guard !pending.isEmpty else { return }
                    var documents = Document(isArray: true)
                    for (index, doc) in pending.enumerated() {
                        documents[String(index)] = doc
                    }
                    var command = Document()
                    command["insert"] = collection
                    command["documents"] = documents
                    _ = try await session.runCommand(command, onDatabase: database)
                    imported += pending.count
                    pending.removeAll()
                }

                let dataRows = rows.dropFirst()
                for row in dataRows {
                    try Task.checkCancellation()
                    rowNumber += 1
                    guard !row.allSatisfy(\.isEmpty) else { continue }
                    let document = CSV.document(headers: headers, row: row)
                    guard !document.isEmpty else { continue }
                    pending.append(document)
                    if pending.count >= 100 {
                        try await flush()
                        sheet.setProgress(
                            Double(rowNumber) / Double(dataRows.count),
                            detail: String(localized: "Imported \(imported) documents…"))
                    }
                }
                try await flush()
                sheet.finish()
                presentInfo(
                    window: window, title: String(localized: "Import Complete"),
                    message: String(localized: "\(imported) documents imported into \(database).\(collection)."))
            } catch is CancellationError {
                sheet.finish()
            } catch {
                sheet.finish()
                presentInfo(
                    window: window, title: String(localized: "Import Failed"),
                    message: "Row \(rowNumber) (after \(imported) imported documents): \(error)")
            }
        }
        sheet.begin(on: window, task: task)
    }

    /// UI-verification hooks (bypass the panels).
    static func debugExportBSON(
        to url: URL, database: String, collection: String, session: ConnectionSession,
        window: NSWindow
    ) {
        runExportBSON(
            to: url, database: database, collection: collection, query: ExportQuery(),
            session: session, window: window)
    }

    static func debugExportCSV(
        to url: URL, database: String, collection: String, session: ConnectionSession,
        window: NSWindow
    ) {
        runExportCSV(
            to: url, database: database, collection: collection, query: ExportQuery(),
            session: session, window: window)
    }

    static func debugExportResults(
        to url: URL, database: String, collection: String, query: ExportQuery,
        session: ConnectionSession, window: NSWindow
    ) {
        if url.pathExtension.lowercased() == "csv" {
            runExportCSV(
                to: url, database: database, collection: collection, query: query,
                session: session, window: window)
        } else {
            runExport(
                to: url, database: database, collection: collection, query: query,
                session: session, window: window)
        }
    }

    static func debugImportCSV(
        from url: URL, database: String, collection: String, session: ConnectionSession,
        window: NSWindow
    ) {
        runImportCSV(
            from: url, database: database, collection: collection, session: session, window: window)
    }

    /// Export specific documents already in memory (the selection).
    static func exportDocuments(
        _ documents: [Document], suggestedName: String, window: NSWindow
    ) {
        guard !documents.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(suggestedName).jsonl"
        panel.allowedContentTypes = [ExportFormatAccessory.jsonLinesType]
        panel.canCreateDirectories = true
        let accessory = ExportFormatAccessory(panel: panel)
        panel.accessoryView = accessory
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try writeDocuments(documents, to: url)
                presentInfo(
                    window: window, title: String(localized: "Export Complete"),
                    message: String(localized: "\(documents.count) documents exported to \(url.lastPathComponent)."))
            } catch {
                presentInfo(
                    window: window, title: String(localized: "Export Failed"),
                    message: String(describing: error))
            }
        }
    }

    static func writeDocuments(_ documents: [Document], to url: URL) throws {
        var data = Data()
        if url.pathExtension.lowercased() == "csv" {
            var columns: [String] = []
            var columnIndex: [String: Int] = [:]
            for document in documents {
                for entry in CSV.flatten(document) where columnIndex[entry.path] == nil {
                    columnIndex[entry.path] = columns.count
                    columns.append(entry.path)
                }
            }
            data.append(Data((CSV.encodeRow(columns) + "\r\n").utf8))
            for document in documents {
                var cells = [String](repeating: "", count: columns.count)
                for entry in CSV.flatten(document) {
                    if let index = columnIndex[entry.path] {
                        cells[index] = CSV.cellText(entry.value)
                    }
                }
                data.append(Data((CSV.encodeRow(cells) + "\r\n").utf8))
            }
        } else {
            for document in documents {
                let line = try ExtendedJSON.stringify(document, format: .canonical)
                data.append(Data(line.utf8))
                data.append(0x0A)
            }
        }
        try data.write(to: url)
    }

    private static func presentInfo(window: NSWindow, title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }
}

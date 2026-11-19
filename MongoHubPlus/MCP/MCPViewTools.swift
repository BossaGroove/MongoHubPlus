import AppKit
import BSON
import ExtendedJSON
import MCPServer

/// What the user is looking at (internal mcp-tools.md §7 step 10): read from
/// the app's windows, never from a database, so it needs no connection.
extension MCPTools {
    /// Selected documents shared at most, across all windows.
    static let maxSelectedDocuments = 5

    static let getCurrentView = MCPTool(
        name: "get_current_view",
        title: "See what the user is looking at",
        description: """
            Shows what the user is looking at in MongoHub Plus, so you can talk about the same \
            thing: every open connection window, front first, with its connection, its tabs \
            and the current tab. When the current tab is a collection's query tab: the pane \
            (Find, Insert, Update, Remove, Index, Aggregation, Tail), and on Find the query \
            fields as the user typed them, the query they make, how many results are shown, \
            and the documents and fields the user selected (up to \(maxSelectedDocuments) \
            documents, as shown, with the pane's projection, in Extended JSON). It reads the \
            screen, not the database: use find for current data. Windows whose connection has \
            access off show only the connection's name. Takes no arguments.
            """,
        inputSchema: [
            "type": "object",
            "properties": [:],
            "additionalProperties": false,
        ],
        readOnly: true,
        run: { _ in
            await MainActor.run { currentView() }
        })

    @MainActor
    private static func currentView() -> MCPToolResult {
        guard let app = NSApp.delegate as? AppDelegate else {
            return .failure("MongoHub Plus isn't ready yet.")
        }
        let format = EJSONFormat(mode: .editor, pretty: false, keyOrder: .document)
        var documentsLeft = maxSelectedDocuments
        var bytesLeft = FindLimits.maxOutputBytes

        var windows: [OrderedJSON] = []
        for (index, controller) in app.connectionWindowsFrontToBack.enumerated() {
            // The store has the current access; the window keeps the
            // connection as it was when it opened.
            let connection =
                ConnectionStore.shared.connection(id: controller.connection.id)
                ?? controller.connection
            let access = connection.effectiveAssistantAccess
            var window: [(String, OrderedJSON)] = [
                ("connection", .string(connection.alias)),
                ("id", .string(connection.id.uuidString)),
                ("access", .string(access.rawValue)),
                ("front", .bool(index == 0)),
            ]
            if controller.window?.isMiniaturized == true {
                window.append(("minimized", .bool(true)))
            }
            guard access != .off else {
                window.append(
                    (
                        "note",
                        .string(
                            "AI Access is No Access, so nothing else about this window is shared."
                        )
                    ))
                windows.append(.object(window))
                continue
            }

            let state = controller.viewState
            window.append(("state", .string(state.connectionState.rawValue)))
            if let database = state.sidebarDatabase {
                var sidebar: [(String, OrderedJSON)] = [("database", .string(database))]
                if let collection = state.sidebarCollection {
                    sidebar.append(("collection", .string(collection)))
                }
                window.append(("sidebarSelection", .object(sidebar)))
            }
            window.append(("tabs", .array(state.tabs.map { .string($0) })))
            if let current = state.currentTab {
                window.append(("currentTab", .string(current)))
            }

            if let query = state.query {
                var tab: [(String, OrderedJSON)] = [
                    ("database", .string(query.database)),
                    ("collection", .string(query.collection)),
                    ("pane", .string(query.pane)),
                ]
                if let find = query.find {
                    var pane: [(String, OrderedJSON)] = [
                        ("filter", .string(find.filter)),
                        ("projection", .string(find.projection)),
                        ("sort", .string(find.sort)),
                        ("query", .string(find.query)),
                        ("resultsShown", .int(find.shownCount)),
                    ]
                    if !find.status.isEmpty {
                        pane.append(("status", .string(find.status)))
                    }
                    if !find.selectedFields.isEmpty {
                        pane.append(
                            ("selectedFields", .array(find.selectedFields.map { .string($0) })))
                    }
                    if !find.selectedDocuments.isEmpty {
                        var written: [OrderedJSON] = []
                        for document in find.selectedDocuments {
                            guard documentsLeft > 0,
                                let text = try? ExtendedJSON.stringify(document, format: format),
                                text.utf8.count <= bytesLeft
                            else { break }
                            written.append(.raw(text))
                            documentsLeft -= 1
                            bytesLeft -= text.utf8.count
                        }
                        pane.append(("selectedCount", .int(find.selectedDocuments.count)))
                        pane.append(("selectedDocuments", .array(written)))
                        if written.count < find.selectedDocuments.count {
                            pane.append(
                                (
                                    "selectionNote",
                                    .string(
                                        "Only \(written.count) of the \(find.selectedDocuments.count) selected documents are included (at most \(maxSelectedDocuments) in all, \(FindLimits.maxOutputBytes / 1000) KB). Use find for the rest."
                                    )
                                ))
                        }
                    }
                    tab.append(("find", .object(pane)))
                }
                window.append(("queryTab", .object(tab)))
            }
            windows.append(.object(window))
        }

        var result: [(String, OrderedJSON)] = [
            ("appActive", .bool(NSApp.isActive)),
            ("windows", .array(windows)),
        ]
        if windows.isEmpty {
            result.append(("message", .string("No connection windows are open in MongoHub Plus.")))
        }
        return .success(OrderedJSON.object(result).written())
    }
}

/// JSON written in the order it's built, with documents embedded as the
/// app's Extended JSON text, so a BSON document never passes through an
/// unordered object (JSONValue sorts keys).
indirect enum OrderedJSON {
    case string(String)
    case int(Int)
    case bool(Bool)
    case null
    /// Text that is already JSON, such as a document's Extended JSON.
    case raw(String)
    case array([OrderedJSON])
    case object([(String, OrderedJSON)])

    func written(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        let inner = pad + "  "
        switch self {
        case .string(let value):
            return String(decoding: JSONValue.string(value).encoded(), as: UTF8.self)
        case .int(let value):
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .null:
            return "null"
        case .raw(let text):
            return text
        case .array(let items):
            guard !items.isEmpty else { return "[]" }
            let body = items.map { inner + $0.written(indent: indent + 1) }
            return "[\n" + body.joined(separator: ",\n") + "\n" + pad + "]"
        case .object(let pairs):
            guard !pairs.isEmpty else { return "{}" }
            let body = pairs.map { key, value in
                inner + OrderedJSON.string(key).written() + ": " + value.written(indent: indent + 1)
            }
            return "{\n" + body.joined(separator: ",\n") + "\n" + pad + "}"
        }
    }
}

import AppKit
import BSON
import ExtendedJSON
import MCPServer
import MongoService

/// Changes an assistant asked for that only the user can apply (internal
/// mcp-tools.md §0, the hard rule): a write tool never runs anything; it
/// creates a pending action, the app shows it, and nothing reaches the
/// database until the user clicks Apply on that one action.
///
/// Nothing here can approve an action except the window's Apply button: no
/// tool, URL or script reaches `apply`. One action waits at a time.
@MainActor
final class PendingActions {
    static let shared = PendingActions()

    /// An update an assistant asked for, exactly as it will run if applied.
    struct UpdateRequest: Sendable {
        let connectionID: UUID
        let connectionName: String
        let database: String
        let collection: String
        /// The filter as the user reads it, and the document that runs.
        let filterText: String
        let filter: Document
        let updateText: String
        let update: Document
        let multi: Bool
        /// When the request was made; the server may have changed since.
        let matchCount: Int?
        let samples: [Document]
    }

    enum Outcome: Sendable, Equatable {
        case applied(matched: Int, modified: Int, errors: [String])
        case failed(String)
        case rejected
        case expired
        case withdrawn(String)
    }

    /// How long a request waits for the user before it's rejected on its own
    /// (owner decision 2026-11-19). Dev builds can shorten it for testing.
    static var expiry: Duration {
        #if DEBUG
            let override = UserDefaults.standard.double(forKey: "MCPPendingExpirySeconds")
            if override > 0 { return .seconds(override) }
        #endif
        return .seconds(600)
    }

    /// How long one tool call waits for the decision before it returns
    /// "still waiting": below Claude Code's 2-minute move to the background
    /// and 5-minute idle limit for MCP calls.
    static var waitPerCall: Duration {
        #if DEBUG
            let override = UserDefaults.standard.double(forKey: "MCPPendingWaitSeconds")
            if override > 0 { return .seconds(override) }
        #endif
        return .seconds(100)
    }

    @MainActor
    final class Action {
        let id: String
        let request: UpdateRequest
        let expiresAt: Date
        fileprivate(set) var outcome: Outcome?
        fileprivate var waiters: [UUID: CheckedContinuation<Outcome?, Never>] = [:]
        fileprivate var window: PendingUpdateWindowController?
        fileprivate var attentionRequest: Int?
        fileprivate var applying = false

        fileprivate init(request: UpdateRequest, expiresAt: Date) {
            self.id = String(UUID().uuidString.prefix(8)).lowercased()
            self.request = request
            self.expiresAt = expiresAt
        }
    }

    private var current: Action?
    /// Recent actions, so a later wait_for_decision can still read an
    /// outcome that arrived between calls.
    private var recent: [Action] = []

    var hasWaitingAction: Bool { current != nil }

    /// Shows the request to the user. Returns nil when another action is
    /// still waiting: one at a time.
    func submit(_ request: UpdateRequest) -> Action? {
        guard current == nil else { return nil }
        let action = Action(
            request: request, expiresAt: Date().addingTimeInterval(Self.seconds(Self.expiry)))
        current = action
        recent.append(action)
        if recent.count > 20 { recent.removeFirst(recent.count - 20) }

        LogStore.shared.add(
            level: "warning", domain: "MCP",
            message:
                "Pending update \(action.id) on \(request.connectionName) \(request.database).\(request.collection): filter \(request.filterText), update \(request.updateText), \(request.multi ? "every match" : "first match only"). Waiting for the user."
        )

        let window = PendingUpdateWindowController(action: action)
        action.window = window
        // The app doesn't take focus; the Dock keeps bouncing until the user
        // switches to it (owner decision 2026-11-19).
        window.showWindow(nil)
        action.attentionRequest = NSApp.requestUserAttention(.criticalRequest)

        let expiry = Self.expiry
        Task { [weak self, weak action] in
            try? await Task.sleep(for: expiry)
            guard let self, let action, action.outcome == nil, !action.applying else { return }
            self.finish(action, .expired)
            action.window?.close()
        }
        return action
    }

    func action(id: String) -> Action? {
        recent.last { $0.id == id.lowercased() }
    }

    /// Waits up to `limit` for the user's decision (and, if applied, for the
    /// update to finish). nil means still waiting.
    func outcome(of action: Action, waitingUpTo limit: Duration) async -> Outcome? {
        if let outcome = action.outcome { return outcome }
        let token = UUID()
        return await withCheckedContinuation { continuation in
            action.waiters[token] = continuation
            Task { @MainActor in
                try? await Task.sleep(for: limit)
                action.waiters.removeValue(forKey: token)?.resume(returning: nil)
            }
        }
    }

    // MARK: - What the tools see

    /// update_documents: shows the request, then waits a while for the
    /// decision.
    func submitAndWait(_ request: UpdateRequest) async -> MCPToolResult {
        guard let action = submit(request) else {
            return .failure(
                "Another change is already waiting for the user's decision in MongoHub Plus. Wait for that one (wait_for_decision) before asking for another."
            )
        }
        return Self.result(action, await outcome(of: action, waitingUpTo: Self.waitPerCall))
    }

    /// wait_for_decision: waits a while longer for a request's outcome.
    func wait(forRequest id: String) async -> MCPToolResult {
        guard let action = action(id: id) else {
            return .failure(
                "There is no recent request \"\(id)\". Use the id update_documents returned.")
        }
        return Self.result(action, await outcome(of: action, waitingUpTo: Self.waitPerCall))
    }

    private static func result(_ action: Action, _ outcome: Outcome?) -> MCPToolResult {
        var result: [String: JSONValue] = ["request": .string(action.id)]
        let isError: Bool
        switch outcome {
        case nil:
            let expires = action.expiresAt.formatted(date: .omitted, time: .shortened)
            result["status"] = "waiting"
            result["message"] = .string(
                "The user hasn't decided yet, and nothing has changed. Call wait_for_decision with this request id to keep waiting. Without an answer the request is rejected at \(expires), the user's local time."
            )
            isError = false
        case .applied(let matched, let modified, let errors)?:
            result["status"] = "applied"
            result["matched"] = .int(matched)
            result["modified"] = .int(modified)
            if !errors.isEmpty {
                result["errors"] = .array(errors.map { .string($0) })
            }
            result["message"] = .string(
                errors.isEmpty
                    ? "The user applied the update."
                    : "The user applied the update, but MongoDB reported errors.")
            isError = !errors.isEmpty
        case .failed(let message)?:
            result["status"] = "failed"
            result["message"] = .string("The user applied the update, but it failed: \(message)")
            isError = true
        case .rejected?:
            result["status"] = "rejected"
            result["message"] =
                "The user rejected the update in MongoHub Plus. Nothing was changed."
            isError = true
        case .expired?:
            result["status"] = "expired"
            result["message"] =
                "Nobody answered within the time limit, so the request expired. Nothing was changed."
            isError = true
        case .withdrawn(let reason)?:
            result["status"] = "withdrawn"
            result["message"] = .string(
                "The request was withdrawn (\(reason)). Nothing was changed.")
            isError = true
        }
        let text = String(decoding: JSONValue.object(result).encoded(pretty: true), as: UTF8.self)
        return isError ? .failure(text) : .success(text)
    }

    // MARK: - Decisions (the window is the only caller)

    /// The user clicked Apply in the window. Runs exactly the request shown,
    /// on a fresh connection, after checking AI Access again: it may have
    /// been lowered while the request waited.
    func apply(_ action: Action) {
        guard action.outcome == nil, !action.applying, current === action else { return }
        action.applying = true
        cancelAttention(action)
        LogStore.shared.add(
            level: "warning", domain: "MCP",
            message: "Pending update \(action.id): applied by the user")

        let request = action.request
        Task {
            let result = await MCPConnections.withSession(
                .string(request.connectionID.uuidString), need: .update
            ) { _, session in
                var spec = Document()
                spec["q"] = request.filter
                spec["u"] = request.update
                spec["upsert"] = false
                spec["multi"] = request.multi
                var updates = Document(isArray: true)
                updates.append(spec)
                var command = Document()
                command["update"] = request.collection
                command["updates"] = updates
                command["ordered"] = true
                return try await session.runCommand(command, onDatabase: request.database)
            }
            let outcome: Outcome
            switch result {
            case .success(let reply):
                outcome = Self.updateOutcome(reply)
            case .failure(let refusal):
                outcome = .failed(refusal.message)
            }
            self.finish(action, outcome)
        }
    }

    /// The user clicked Reject, pressed Esc or closed the window.
    func reject(_ action: Action) {
        guard action.outcome == nil, !action.applying else { return }
        finish(action, .rejected)
    }

    /// MCP was switched off: nothing may be applied any more.
    func withdrawAll(_ reason: String) {
        guard let action = current, action.outcome == nil, !action.applying else { return }
        finish(action, .withdrawn(reason))
        action.window?.close()
    }

    private func finish(_ action: Action, _ outcome: Outcome) {
        guard action.outcome == nil else { return }
        action.outcome = outcome
        cancelAttention(action)
        if current === action { current = nil }
        for waiter in action.waiters.values {
            waiter.resume(returning: outcome)
        }
        action.waiters.removeAll()
        action.window?.show(outcome)
        LogStore.shared.add(
            level: "warning", domain: "MCP",
            message: "Pending update \(action.id): \(Self.logText(outcome))")
    }

    private func cancelAttention(_ action: Action) {
        if let request = action.attentionRequest {
            NSApp.cancelUserAttentionRequest(request)
            action.attentionRequest = nil
        }
    }

    // MARK: - Helpers

    nonisolated static func seconds(_ duration: Duration) -> TimeInterval {
        let (seconds, attoseconds) = duration.components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }

    private static func updateOutcome(_ reply: Document) -> Outcome {
        func integer(_ value: Primitive?) -> Int {
            switch value {
            case let value as Int: return value
            case let value as Int32: return Int(value)
            case let value as Double: return Int(value)
            default: return 0
            }
        }
        var errors: [String] = []
        for case let error as Document in (reply["writeErrors"] as? Document)?.values ?? [] {
            let code = integer(error["code"])
            errors.append("\(error["errmsg"] as? String ?? "write error") (code \(code))")
        }
        if let concern = reply["writeConcernError"] as? Document {
            errors.append("write concern: \(concern["errmsg"] as? String ?? "error")")
        }
        return .applied(
            matched: integer(reply["n"]), modified: integer(reply["nModified"]), errors: errors)
    }

    private static func logText(_ outcome: Outcome) -> String {
        switch outcome {
        case .applied(let matched, let modified, let errors):
            return "done, matched \(matched), modified \(modified)"
                + (errors.isEmpty ? "" : ", errors: \(errors.joined(separator: "; "))")
        case .failed(let message): return "failed: \(message)"
        case .rejected: return "rejected by the user"
        case .expired: return "expired without an answer"
        case .withdrawn(let reason): return "withdrawn: \(reason)"
        }
    }
}

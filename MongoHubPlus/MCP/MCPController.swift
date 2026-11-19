import Foundation
import MCPServer

/// Runs the MCP server that lets AI assistants (Claude Code) use the app
/// (internal mcp-tools.md). Off by default; Settings ▸ MCP turns it on.
///
/// The server listens on 127.0.0.1 only and every request must carry the
/// token, which lives in the Keychain and appears only in the command
/// Settings shows for adding the server to Claude Code.
@MainActor
final class MCPController {
    static let shared = MCPController()

    enum Status: Equatable {
        case off
        case starting
        case running(port: Int)
        case failed(String)
    }

    private(set) var status: Status = .off {
        didSet {
            guard status != oldValue else { return }
            NotificationCenter.default.post(name: .mcpStatusDidChange, object: self)
        }
    }

    private var server: MCPHTTPServer?
    /// Bumped by every reload, so a slow start that a newer reload has
    /// overtaken shuts itself down instead of replacing the newer state.
    private var generation = 0
    private var cachedToken: String?

    static let serverName = "mongohubplus"

    var endpointURL: String { "http://127.0.0.1:\(Preferences.mcpPort)\(MCPEndpoint.path)" }

    /// The assistants Settings ▸ MCP shows a setup for (owner request
    /// 2026-11-19; formats from each one's MCP documentation).
    enum Client: String, CaseIterable, Identifiable {
        case claudeCode, codex, antigravity

        var id: Self { self }

        var displayName: String {
            switch self {
            case .claudeCode: return "Claude Code"
            case .codex: return "Codex"
            case .antigravity: return "Antigravity"
            }
        }
    }

    /// What adds this server to `client`, for every project: a Terminal
    /// command for Claude Code (user scope), a table for Codex's
    /// ~/.codex/config.toml, an mcp_config.json entry for Antigravity. nil
    /// when the token can't be read.
    func setup(for client: Client) -> String? {
        guard let token else { return nil }
        switch client {
        case .claudeCode:
            return
                #"claude mcp add --scope user --transport http \#(Self.serverName) \#(endpointURL) --header "Authorization: Bearer \#(token)""#
        case .codex:
            return """
                [mcp_servers.\(Self.serverName)]
                url = "\(endpointURL)"
                http_headers = { "Authorization" = "Bearer \(token)" }
                """
        case .antigravity:
            return """
                {
                  "mcpServers": {
                    "\(Self.serverName)": {
                      "serverUrl": "\(endpointURL)",
                      "headers": {
                        "Authorization": "Bearer \(token)"
                      }
                    }
                  }
                }
                """
        }
    }

    /// The token, created on first use. nil when the Keychain can't be read,
    /// for example when its access prompt was dismissed: the stored token is
    /// then left alone, never replaced, so assistants already set up with it
    /// work again once the app can read it.
    var token: String? {
        if let cachedToken { return cachedToken }
        do {
            if let stored = try Keychain.secret(.mcpToken), !stored.isEmpty {
                cachedToken = stored
                return stored
            }
        } catch {
            LogStore.shared.add(
                level: "error", domain: "MCP",
                message: "Couldn't read the token from the Keychain: \(error)")
            return nil
        }
        return storeNewToken()
    }

    /// Replaces the token; assistants using the old one are refused until
    /// they're set up again with the new command.
    func regenerateToken() {
        _ = storeNewToken()
        LogStore.shared.add(level: "info", domain: "MCP", message: "New token created")
        reload()
    }

    @discardableResult
    private func storeNewToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        do {
            try Keychain.setSecret(token, for: .mcpToken)
        } catch {
            // Still usable for this run; the next launch makes another.
            LogStore.shared.add(
                level: "warning", domain: "MCP",
                message: "Couldn't save the token in the Keychain: \(error)")
        }
        cachedToken = token
        return token
    }

    /// Starts, stops or restarts the server to match Settings.
    func reload() {
        generation += 1
        let generation = generation
        let oldServer = server
        server = nil
        let enabled = Preferences.mcpEnabled
        let port = Preferences.mcpPort
        let token = enabled ? self.token : nil
        status = enabled ? .starting : .off
        if !enabled {
            PendingActions.shared.withdrawAll("MCP was turned off in Settings")
        }
        if enabled, token == nil {
            status = .failed(
                String(
                    localized:
                        "Couldn't read the token from the Keychain. Turn this off and on again to retry."
                ))
        }

        Task {
            if let oldServer {
                await oldServer.stop()
                LogStore.shared.add(level: "info", domain: "MCP", message: "Server stopped")
            }
            guard enabled, let token, generation == self.generation else { return }
            do {
                let newServer = try await MCPHTTPServer.start(port: port) { boundPort in
                    MCPEndpoint(port: boundPort, token: token, dispatcher: Self.dispatcher())
                }
                guard generation == self.generation else {
                    await newServer.stop()
                    return
                }
                server = newServer
                status = .running(port: newServer.port)
                LogStore.shared.add(
                    level: "info", domain: "MCP",
                    message: "Server listening on 127.0.0.1:\(newServer.port)")
            } catch {
                guard generation == self.generation else { return }
                let message = String(describing: error)
                status = .failed(message)
                LogStore.shared.add(
                    level: "error", domain: "MCP", message: "Server didn't start: \(message)")
            }
        }
    }

    nonisolated private static func dispatcher() -> MCPDispatcher {
        let version =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0"
        return MCPDispatcher(
            serverName: "MongoHub Plus", serverVersion: version,
            instructions: """
                MongoHub Plus is the user's MongoDB GUI on this Mac. Its tools act on the \
                connections the user saved in the app, named as list_connections returns \
                them. Each connection has an access level that only the user sets in the app: \
                off (no tool can use it), readOnly (reading), or readWrite (reading and \
                inserting). Updates and deletes are never run directly: update_documents and \
                delete_documents, on readWrite connections, ask the user, who applies or \
                rejects each one in the app. When the user wants to check or tweak a query or \
                pipeline you ran, show it in the app with open_query or open_aggregation. The \
                app never shares hosts, connection strings or passwords.
                """,
            tools: MCPTools.all,
            log: { event in
                LogStore.log(level: event.level.rawValue, domain: "MCP", message: event.message)
            })
    }
}

extension Notification.Name {
    static let mcpStatusDidChange = Notification.Name("MongoHub Plus.mcpStatusDidChange")
}

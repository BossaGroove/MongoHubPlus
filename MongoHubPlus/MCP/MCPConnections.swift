import Foundation
import MCPServer
import MongoService

/// How MCP tools reach a database (internal mcp-tools.md §4, §7): find the
/// connection the assistant named, check its AI Access, connect, run the
/// tool's work, disconnect. One connection per tool call for now.
enum MCPConnections {
    /// What a tool needs the connection's AI Access to allow.
    enum Need: Sendable {
        case read
        /// Inserting: the one write assistants may run directly, and only on
        /// Read & Write connections (internal mcp-tools.md §0).
        case insert
    }

    /// A reason to refuse, worded for the assistant.
    struct Refusal: Error {
        let message: String
    }

    /// The `connection` argument every database tool takes.
    static let connectionArgumentSchema: JSONValue = [
        "type": "string",
        "description": "The connection's name or id, as list_connections returns them.",
    ]

    /// Runs `body` on a fresh session for the connection named in
    /// `arguments["connection"]`, if its AI Access allows `need`.
    ///
    /// Connection failures reach the assistant only in general terms: the
    /// driver's message can name hosts, which the app never shares. The full
    /// error goes to Window ▸ Logs.
    static func run(
        _ arguments: [String: JSONValue], need: Need,
        _ body: @Sendable (MongoConnection, ConnectionSession) async throws -> MCPToolResult
    ) async -> MCPToolResult {
        let connection: MongoConnection
        let uri: String
        do {
            (connection, uri) = try await MainActor.run {
                try prepare(arguments["connection"], need: need)
            }
        } catch let refusal as Refusal {
            return .failure(refusal.message)
        } catch {
            return .failure(String(describing: error))
        }

        let alias = connection.alias
        let session: ConnectionSession
        do {
            session = try ConnectionSession(connectionString: uri) { level, message in
                LogStore.log(level: level, domain: "\(alias).driver", message: message)
            }
            try await session.connect()
        } catch {
            LogStore.log(
                level: "error", domain: "MCP", message: "Couldn't connect to \(alias): \(error)")
            return .failure(
                "Couldn't connect to \"\(alias)\". The details are in MongoHub Plus, Window ▸ Logs."
            )
        }

        let result: MCPToolResult
        do {
            result = try await body(connection, session)
        } catch {
            result = .failure("MongoDB error: \(error)")
        }
        await session.disconnect()
        return result
    }

    /// Resolves the connection and checks its access; returns it with the
    /// connection string to use.
    @MainActor
    private static func prepare(_ argument: JSONValue?, need: Need) throws -> (
        MongoConnection, String
    ) {
        let connection = try resolve(argument, need: need)

        // The tunnel's host-key prompt needs a window; not supported yet.
        // (open_query is fine: the app's own window handles the prompt.)
        if connection.useSSH, connection.supportsSSHTunnel {
            throw Refusal(
                message:
                    "\"\(connection.alias)\" connects through an SSH tunnel, which MCP tools don't support yet."
            )
        }

        let uri = Preferences.applyingTimeouts(
            to: connection.connectionString(
                password: Keychain.password(for: connection.id, kind: .mongo)))
        return (connection, uri)
    }

    /// Finds the connection named in a tool's `connection` argument (a name
    /// or an id) and checks that its AI Access allows `need`. No connecting.
    @MainActor
    static func resolve(_ argument: JSONValue?, need: Need) throws -> MongoConnection {
        guard let reference = argument?.stringValue?.trimmingCharacters(in: .whitespaces),
            !reference.isEmpty
        else {
            throw Refusal(
                message: "connection is required: a connection name or id from list_connections.")
        }
        let store = ConnectionStore.shared
        guard
            let connection = UUID(uuidString: reference).flatMap({ store.connection(id: $0) })
                ?? store.connection(alias: reference)
        else {
            throw Refusal(
                message:
                    "No connection named \"\(reference)\". Call list_connections for the names.")
        }

        let alias = connection.alias
        switch (need, connection.effectiveAssistantAccess) {
        case (_, .off):
            throw Refusal(
                message: """
                    "\(alias)" has AI Access set to No Access, so assistants can't use it. Only \
                    the user can change that: in MongoHub Plus, edit the connection and set AI \
                    Access to Read Only or Read & Write.
                    """)
        case (.insert, .readOnly):
            throw Refusal(
                message: """
                    "\(alias)" has AI Access set to Read Only, so assistants can read it but not \
                    insert. Only the user can change that: in MongoHub Plus, edit the connection \
                    and set AI Access to Read & Write.
                    """)
        case (.read, .readOnly), (.read, .readWrite), (.insert, .readWrite):
            break
        }
        return connection
    }
}

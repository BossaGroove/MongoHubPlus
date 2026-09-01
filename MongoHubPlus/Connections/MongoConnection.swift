import Foundation

/// A saved connection (feature-spec 1.6). Persisted as JSON via
/// `ConnectionStore`; passwords live in the Keychain, never here.
struct MongoConnection: Codable, Identifiable, Equatable, Sendable {
    /// Deployment kind — the editor's type popup. `srv` is the DNS-seed-list
    /// form (`mongodb+srv://`), which is how Atlas connects.
    enum Kind: String, Codable, CaseIterable, Sendable {
        case standalone
        case replicaSet
        case shardedCluster
        case srv
        case connectionString

        var displayName: String {
            switch self {
            case .standalone: return String(localized: "Standalone")
            case .replicaSet: return String(localized: "Replica Set")
            case .shardedCluster: return String(localized: "Sharded Cluster")
            case .srv: return String(localized: "Atlas / DNS Seed List")
            case .connectionString: return String(localized: "Connection String")
            }
        }
    }

    enum ReadMode: String, Codable, CaseIterable, Sendable {
        case primary, secondary, primaryPreferred, secondaryPreferred, nearest

        var displayName: String {
            switch self {
            case .primary: return String(localized: "Primary")
            case .secondary: return String(localized: "Secondary")
            case .primaryPreferred: return String(localized: "Primary Preferred")
            case .secondaryPreferred: return String(localized: "Secondary Preferred")
            case .nearest: return String(localized: "Nearest")
            }
        }
    }

    var id: UUID = UUID()
    var alias: String = ""
    var kind: Kind = .standalone
    /// Comma-separated `host[:port]` list (single host for standalone/srv).
    var servers: String = ""
    var replicaSetName: String = ""
    var adminUser: String = ""
    var defaultDatabase: String = ""
    var useTLS: Bool = false
    var weakCertificate: Bool = false
    var defaultReadMode: ReadMode = .primary
    /// Extra `key=value&…` URI options preserved verbatim from pasted URLs
    /// (legacy silently dropped these — feature-spec 1.10).
    var extraOptions: String = ""
    /// For `kind == .connectionString`: the full URI, Compass-style, with the
    /// password stripped out (it lives in the Keychain — never on disk).
    /// Optional for backward compatibility with earlier store files.
    var rawConnectionString: String? = nil

    // SSH tunnel settings (feature-spec 2.8).
    /// Favorite flag (optional so pre-4.0 stores keep decoding; nil = false).
    var pinned: Bool? = nil
    var useSSH: Bool = false
    var sshHost: String = ""
    var sshPort: Int = 22
    var sshUser: String = ""
    var sshKeyFileName: String = ""
    /// Security-scoped bookmark for the key file (sandbox access across launches).
    var sshKeyBookmark: Data? = nil
    /// Trust-on-first-use SSH host key (wire-format blob).
    var sshKnownHostKey: Data? = nil

    var serverList: [String] {
        servers.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// (host, port) pairs for SSH forwarding, with the default mongo port.
    var forwardTargets: [(host: String, port: Int)] {
        serverList.map { server in
            let parts = server.split(separator: ":")
            let host = parts.first.map(String.init) ?? server
            let port = parts.count > 1 ? Int(parts[1]) ?? 27017 : 27017
            return (host, port)
        }
    }

    /// SSH tunneling needs explicit host lists — not SRV or raw strings.
    var isPinned: Bool { pinned ?? false }

    /// Short host summary shown on the connection card.
    var displaySubtitle: String {
        switch kind {
        case .standalone, .replicaSet, .shardedCluster, .srv:
            return servers
        case .connectionString:
            guard let raw = rawConnectionString else { return "" }
            var host = raw
            if let scheme = host.range(of: "://") { host = String(host[scheme.upperBound...]) }
            if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
            if let end = host.firstIndex(where: { $0 == "/" || $0 == "?" }) {
                host = String(host[..<end])
            }
            return host
        }
    }

    var supportsSSHTunnel: Bool {
        switch kind {
        case .standalone, .replicaSet, .shardedCluster: return true
        case .srv, .connectionString: return false
        }
    }
}

// MARK: - Connection string building / parsing (feature-spec 1.4, 1.5)

extension MongoConnection {
    private static let userInfoAllowed: CharacterSet = {
        // RFC 3986 userinfo minus the sub-delims MongoDB treats specially.
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    private static func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: userInfoAllowed) ?? s
    }

    /// Builds the `mongodb://` / `mongodb+srv://` connection string.
    /// - Parameter password: from the Keychain; interpolated only here.
    /// - Parameter redacted: replaces the password with `••••` for display/logs.
    /// - Parameter hostRewrite: `"host:port" → local port` mapping from an
    ///   SSH tunnel; matching hosts become `127.0.0.1:<localPort>` (the
    ///   legacy stringURLWithSSHMapping behavior).
    func connectionString(
        password: String?, redacted: Bool = false, hostRewrite: [String: Int]? = nil
    ) -> String {
        if kind == .connectionString {
            let raw = rawConnectionString ?? ""
            guard let password, !password.isEmpty else { return raw }
            return Self.injectPassword(redacted ? "••••" : password, into: raw)
        }
        var out = kind == .srv ? "mongodb+srv://" : "mongodb://"
        if !adminUser.isEmpty {
            out += Self.escape(adminUser)
            if let password, !password.isEmpty {
                out += ":" + (redacted ? "••••" : Self.escape(password))
            }
            out += "@"
        }
        var hosts = serverList
        if let hostRewrite {
            hosts = forwardTargets.map { target in
                if let localPort = hostRewrite["\(target.host):\(target.port)"] {
                    return "127.0.0.1:\(localPort)"
                }
                return "\(target.host):\(target.port)"
            }
        }
        out += hosts.isEmpty ? "127.0.0.1" : hosts.joined(separator: ",")
        out += "/"
        if !defaultDatabase.isEmpty {
            out += Self.escape(defaultDatabase)
        }

        var options: [String] = []
        if kind == .replicaSet, !replicaSetName.isEmpty {
            options.append("replicaSet=\(Self.escape(replicaSetName))")
        }
        // +srv implies TLS; only emit for the standard scheme.
        if useTLS, kind != .srv {
            options.append("tls=true")
        }
        if weakCertificate {
            options.append("tlsAllowInvalidCertificates=true")
        }
        if defaultReadMode != .primary {
            options.append("readPreference=\(defaultReadMode.rawValue)")
        }
        if !extraOptions.isEmpty {
            options.append(extraOptions)
        }
        if !options.isEmpty {
            out += "?" + options.joined(separator: "&")
        }
        return out
    }

    /// Parses a connection string into fields. Keeps the `/database` path and
    /// percent-decodes credentials (both broken in legacy — feature-spec §8.1),
    /// and preserves unrecognized options in `extraOptions`.
    static func parse(connectionString: String) throws -> (connection: MongoConnection, password: String?) {
        var connection = MongoConnection()
        var rest: Substring
        if connectionString.hasPrefix("mongodb+srv://") {
            connection.kind = .srv
            rest = connectionString.dropFirst("mongodb+srv://".count)
        } else if connectionString.hasPrefix("mongodb://") {
            rest = connectionString.dropFirst("mongodb://".count)
        } else {
            throw ConnectionParseError("Connection strings must start with mongodb:// or mongodb+srv://")
        }
        guard !rest.isEmpty else { throw ConnectionParseError("Empty connection string") }

        // Split off ?options
        var optionsPart = ""
        if let q = rest.firstIndex(of: "?") {
            optionsPart = String(rest[rest.index(after: q)...])
            rest = rest[..<q]
        }
        // Split off /database
        if let slash = rest.firstIndex(of: "/") {
            let db = String(rest[rest.index(after: slash)...])
            connection.defaultDatabase = db.removingPercentEncoding ?? db
            rest = rest[..<slash]
        }
        // user:password@hosts
        var password: String?
        if let at = rest.lastIndex(of: "@") {
            let userInfo = rest[..<at]
            rest = rest[rest.index(after: at)...]
            let parts = userInfo.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            connection.adminUser = String(parts[0]).removingPercentEncoding ?? String(parts[0])
            if parts.count == 2 {
                password = String(parts[1]).removingPercentEncoding ?? String(parts[1])
            }
        }
        guard !rest.isEmpty else { throw ConnectionParseError("Missing host") }
        connection.servers = String(rest)

        // Options: extract the ones we have fields for; keep the rest verbatim.
        var extras: [String] = []
        for pair in optionsPart.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = kv[0].lowercased()
            let value = kv.count == 2 ? String(kv[1]) : ""
            switch key {
            case "replicaset":
                connection.replicaSetName = value.removingPercentEncoding ?? value
                if connection.kind != .srv { connection.kind = .replicaSet }
            case "tls", "ssl":
                connection.useTLS = value == "true"
            case "tlsallowinvalidcertificates":
                connection.weakCertificate = value == "true"
            case "readpreference":
                if let mode = ReadMode(rawValue: value) {
                    connection.defaultReadMode = mode
                } else {
                    extras.append(String(pair))
                }
            default:
                extras.append(String(pair))
            }
        }
        connection.extraOptions = extras.joined(separator: "&")

        if connection.kind == .standalone, connection.serverList.count > 1 {
            connection.kind = connection.replicaSetName.isEmpty ? .shardedCluster : .replicaSet
        }
        connection.alias = connection.serverList.first ?? "New Connection"
        return (connection, password)
    }
}

// MARK: - Raw connection strings (the "Connection String" kind)

extension MongoConnection {
    /// Splits the password out of a URI's userinfo.
    /// `mongodb+srv://user:pass@host/db` → (`mongodb+srv://user@host/db`, `pass`)
    static func extractPassword(from uri: String) -> (stripped: String, password: String?) {
        guard let schemeEnd = uri.range(of: "://") else { return (uri, nil) }
        let afterScheme = uri[schemeEnd.upperBound...]
        // The authority ends at the first '/' or '?'; '@' must come before it.
        let authorityEnd =
            afterScheme.firstIndex(where: { $0 == "/" || $0 == "?" }) ?? afterScheme.endIndex
        let authority = afterScheme[..<authorityEnd]
        guard let at = authority.lastIndex(of: "@") else { return (uri, nil) }
        let userInfo = authority[..<at]
        guard let colon = userInfo.firstIndex(of: ":") else { return (uri, nil) }
        let password = String(userInfo[userInfo.index(after: colon)..<at])
        var stripped = uri
        stripped.removeSubrange(colon..<at)
        return (stripped, password.removingPercentEncoding ?? password)
    }

    /// Re-inserts a password after the userinfo's user part.
    static func injectPassword(_ password: String, into uri: String) -> String {
        guard let schemeEnd = uri.range(of: "://") else { return uri }
        let afterScheme = uri[schemeEnd.upperBound...]
        let authorityEnd =
            afterScheme.firstIndex(where: { $0 == "/" || $0 == "?" }) ?? afterScheme.endIndex
        let authority = afterScheme[..<authorityEnd]
        guard let at = authority.lastIndex(of: "@"), !authority[..<at].contains(":") else {
            return uri  // no user part, or a password is already present
        }
        var out = uri
        out.insert(contentsOf: ":" + escape(password), at: at)
        return out
    }

    /// The username embedded in a URI's userinfo, percent-decoded.
    static func username(in uri: String) -> String? {
        guard let schemeEnd = uri.range(of: "://") else { return nil }
        let afterScheme = uri[schemeEnd.upperBound...]
        let authorityEnd =
            afterScheme.firstIndex(where: { $0 == "/" || $0 == "?" }) ?? afterScheme.endIndex
        let authority = afterScheme[..<authorityEnd]
        guard let at = authority.lastIndex(of: "@") else { return nil }
        var userInfo = authority[..<at]
        if let colon = userInfo.firstIndex(of: ":") {
            userInfo = userInfo[..<colon]
        }
        let user = String(userInfo)
        return user.isEmpty ? nil : (user.removingPercentEncoding ?? user)
    }

    /// A display alias guessed from the URI's host part.
    static func aliasSuggestion(for uri: String) -> String {
        guard let schemeEnd = uri.range(of: "://") else { return "New Connection" }
        let afterScheme = uri[schemeEnd.upperBound...]
        let authorityEnd =
            afterScheme.firstIndex(where: { $0 == "/" || $0 == "?" }) ?? afterScheme.endIndex
        var authority = afterScheme[..<authorityEnd]
        if let at = authority.lastIndex(of: "@") {
            authority = authority[authority.index(after: at)...]
        }
        let host = authority.split(separator: ",").first.map(String.init) ?? ""
        return host.isEmpty ? "New Connection" : host
    }
}

struct ConnectionParseError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

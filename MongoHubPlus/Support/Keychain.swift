import Foundation
import Security

/// Passwords for saved connections, keyed by the connection's stable UUID
/// (legacy keyed by the mutable server list, orphaning passwords on edit —
/// feature-spec 1.9). Generic passwords in the data-protection keychain.
enum Keychain {
    private static let service = "com.bossagroove.MongoHubPlus"

    enum Kind: String {
        case mongo = "mongo-password"
        case ssh = "ssh-password"
    }

    private static func account(_ id: UUID, _ kind: Kind) -> String {
        "\(id.uuidString).\(kind.rawValue)"
    }

    /// The data-protection keychain needs an application-identifier
    /// entitlement, which only properly signed builds have. Ad-hoc signed
    /// dev builds get -34018 (errSecMissingEntitlement) — fall back to the
    /// classic login keychain there.
    private static let dataProtectionAvailable: Bool = {
        // Only SecItemAdd actually exercises the entitlement check, so probe
        // with a real (throwaway) item.
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "__entitlement-probe__",
            kSecUseDataProtectionKeychain as String: true,
            kSecValueData as String: Data("probe".utf8),
        ]
        let status = SecItemAdd(probe as CFDictionary, nil)
        if status == errSecSuccess || status == errSecDuplicateItem {
            var delete = probe
            delete[kSecValueData as String] = nil
            SecItemDelete(delete as CFDictionary)
            return true
        }
        return status != errSecMissingEntitlement
    }()

    private static func baseQuery(_ id: UUID, _ kind: Kind) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(id, kind),
        ]
        if dataProtectionAvailable {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    static func password(for id: UUID, kind: Kind) -> String? {
        var query = baseQuery(id, kind)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores, replaces, or (for an empty password) deletes the item.
    static func setPassword(_ password: String, for id: UUID, kind: Kind) throws {
        guard !password.isEmpty else {
            deletePassword(for: id, kind: kind)
            return
        }
        let data = Data(password.utf8)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(id, kind) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(id, kind)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "MongoHub Plus \(kind == .mongo ? "MongoDB" : "SSH") password"
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError(status: addStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    static func deletePassword(for id: UUID, kind: Kind) {
        SecItemDelete(baseQuery(id, kind) as CFDictionary)
    }

    static func deleteAll(for id: UUID) {
        deletePassword(for: id, kind: .mongo)
        deletePassword(for: id, kind: .ssh)
    }
}

struct KeychainError: Error, CustomStringConvertible {
    let status: OSStatus

    var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
        return "Keychain error \(status): \(message)"
    }
}

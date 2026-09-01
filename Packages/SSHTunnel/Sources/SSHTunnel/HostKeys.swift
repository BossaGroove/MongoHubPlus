import Crypto
import Foundation
import NIOCore
import NIOSSH

struct HostKeyRejectedError: Error {
    let message: String
}

/// Trust-on-first-use host key validation (replaces the legacy
/// `StrictHostKeyChecking=no` — feature-spec §8.30). Unknown/changed keys go
/// through the async prompt; no prompt means unknown keys are rejected.
final class TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let trusted: Data?
    private let prompt: SSHTunnel.HostKeyPrompt?
    private let lock = NSLock()
    private var _approvedKey: Data?

    var approvedKey: Data? {
        lock.lock()
        defer { lock.unlock() }
        return _approvedKey
    }

    init(trusted: Data?, prompt: SSHTunnel.HostKeyPrompt?) {
        self.trusted = trusted
        self.prompt = prompt
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presented = HostKeySerializer.serialize(hostKey)

        if let trusted, let presented, trusted == presented {
            store(presented)
            validationCompletePromise.succeed(())
            return
        }

        let changed = trusted != nil
        guard let prompt else {
            validationCompletePromise.fail(
                HostKeyRejectedError(
                    message: changed
                        ? "The SSH host key has CHANGED — possible man-in-the-middle"
                        : "Unknown SSH host key"))
            return
        }

        let fingerprint = presented.map(HostKeySerializer.fingerprint) ?? "(fingerprint unavailable)"
        Task {
            if await prompt(fingerprint, changed) {
                self.store(presented)
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(
                    HostKeyRejectedError(message: "SSH host key rejected by the user"))
            }
        }
    }

    private func store(_ key: Data?) {
        lock.lock()
        _approvedKey = key
        lock.unlock()
    }
}

/// Serializes an `NIOSSHPublicKey` into its SSH wire-format blob for TOFU
/// storage and fingerprinting. NIOSSH exposes no public serialization, so the
/// backing CryptoKit key is reached via reflection; if that ever breaks with
/// a dependency update, serialization returns nil and the tunnel degrades to
/// prompting every session (never to skipping validation).
enum HostKeySerializer {
    static func serialize(_ key: NIOSSHPublicKey) -> Data? {
        guard let backing = Mirror(reflecting: key).children.first?.value,
            let payload = Mirror(reflecting: backing).children.first?.value
        else { return nil }

        switch payload {
        case let key as Curve25519.Signing.PublicKey:
            return blob(prefix: "ssh-ed25519", parts: [key.rawRepresentation])
        case let key as P256.Signing.PublicKey:
            return blob(
                prefix: "ecdsa-sha2-nistp256",
                parts: [Data("nistp256".utf8), key.x963Representation])
        case let key as P384.Signing.PublicKey:
            return blob(
                prefix: "ecdsa-sha2-nistp384",
                parts: [Data("nistp384".utf8), key.x963Representation])
        case let key as P521.Signing.PublicKey:
            return blob(
                prefix: "ecdsa-sha2-nistp521",
                parts: [Data("nistp521".utf8), key.x963Representation])
        case let key as NIOSSHPublicKeyProtocol:
            var buffer = ByteBufferAllocator().buffer(capacity: 512)
            _ = key.write(to: &buffer)
            let bytes = buffer.readData(length: buffer.readableBytes) ?? Data()
            return blob(prefix: type(of: key).publicKeyPrefix, parts: [bytes])
        default:
            return nil
        }
    }

    /// OpenSSH-style fingerprint: `SHA256:` + unpadded base64.
    static func fingerprint(_ blob: Data) -> String {
        let digest = SHA256.hash(data: blob)
        let base64 = Data(digest).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        return "SHA256:\(base64)"
    }

    private static func blob(prefix: String, parts: [Data]) -> Data {
        var out = Data()
        appendSSHString(Data(prefix.utf8), to: &out)
        for part in parts {
            appendSSHString(part, to: &out)
        }
        return out
    }

    private static func appendSSHString(_ data: Data, to out: inout Data) {
        var length = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(data)
    }
}

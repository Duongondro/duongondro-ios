import CryptoKit
import DuongondroAPI
import DuongondroCrypto
import Foundation

/// Where secrets live: the Keychain in the app (this-device-only, after first
/// unlock), memory in tests.
public protocol SecretStore: AnyObject, Sendable {
    func read(_ name: String) throws -> Data?
    func write(_ name: String, _ data: Data) throws
    func delete(_ name: String) throws
}

public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private var values: [String: Data] = [:]
    private let lock = NSLock()
    public init() {}
    public func read(_ name: String) throws -> Data? { lock.withLock { values[name] } }
    public func write(_ name: String, _ data: Data) throws { lock.withLock { values[name] = data } }
    public func delete(_ name: String) throws { lock.withLock { values[name] = nil } }
}

/// The names secrets are stored under.
enum SecretName {
    static let deviceKey = "device-key"
    static let pendingRecovery = "recovery-pending"
    static let deviceID = "device-id"
    static let identitySeed = "identity-seed"
    /// The account a set-up in progress belongs to: Keychain items outlive the
    /// app, so secrets left by another account's unfinished set-up are not reused.
    static let setUpUser = "set-up-user"
    static func practiceKey(_ version: Int) -> String { "practice-key-\(version)" }
}

/// This device's key on the glowie curve: in the Secure Enclave where there is
/// one, otherwise a software key (the Simulator). The tier is recorded with it and
/// published in the device list. A key is created only when none is stored: an
/// unreadable Keychain is an error, never a reason to make a new key.
public struct DeviceKeys: Sendable {
    let store: SecretStore
    let preferSoftware: Bool

    public init(store: SecretStore, preferSoftware: Bool = false) {
        self.store = store
        self.preferSoftware = preferSoftware
    }

    public struct Key: @unchecked Sendable {
        public let agreement: any DeviceKeyAgreement
        public let tier: Tier
        public var publicKey: Data { agreement.publicKeyX963 }
    }

    /// Key and tier are one record, so a key can never be found without its tier.
    struct Stored: Codable {
        let tier: Tier
        let key: Data
    }

    public func current() throws -> Key? {
        guard let data = try store.read(SecretName.deviceKey) else { return nil }
        let stored = try JSONDecoder().decode(Stored.self, from: data)
        switch stored.tier {
        case .hardware:
            return Key(agreement: try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: stored.key), tier: .hardware)
        case .software, .tee:
            return Key(agreement: try P256.KeyAgreement.PrivateKey(rawRepresentation: stored.key), tier: stored.tier)
        }
    }

    /// The stored key, or a new one. `fellBack` says a Secure Enclave existed but
    /// refused to make a key, which the app reports (design: Keys).
    public func currentOrCreate() throws -> (key: Key, fellBack: Bool) {
        if let key = try current() { return (key, false) }
        var fellBack = false
        if !preferSoftware, SecureEnclave.isAvailable {
            // Usable after the first unlock, like the Keychain items, so a sync
            // in the background can unwrap; no user presence (CodeShare's DeviceKey).
            var error: Unmanaged<CFError>?
            if let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                                            .privateKeyUsage, &error),
               let enclave = try? SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access) {
                try save(Stored(tier: .hardware, key: enclave.dataRepresentation))
                return (Key(agreement: enclave, tier: .hardware), false)
            }
            fellBack = true
        }
        let software = P256.KeyAgreement.PrivateKey()
        try save(Stored(tier: .software, key: software.rawRepresentation))
        return (Key(agreement: software, tier: .software), fellBack)
    }

    private func save(_ stored: Stored) throws {
        try store.write(SecretName.deviceKey, try JSONEncoder().encode(stored))
    }
}

/// The 16-byte recovery secret as the person writes it down: Crockford base32,
/// 26 characters in groups, no ambiguous letters; typing tolerates case, spaces,
/// hyphens, and O/I/L for 0/1/1.
public enum RecoveryCode {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public static func encode(_ secret: Data) -> String {
        var bits = 0, value = 0
        var out = ""
        for byte in secret {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(value >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { out.append(alphabet[(value << (5 - bits)) & 31]) }
        return stride(from: 0, to: out.count, by: 4).map { i -> String in
            let start = out.index(out.startIndex, offsetBy: i)
            return String(out[start..<(out.index(start, offsetBy: 4, limitedBy: out.endIndex) ?? out.endIndex)])
        }.joined(separator: "-")
    }

    /// What was typed, as the code's characters: upper case, no separators,
    /// O read as 0 and I or L as 1.
    public static func normalise(_ typed: String) -> String {
        String(typed.uppercased().compactMap { c -> Character? in
            switch c {
            case "-", " ", "\n": return nil
            case "O": return "0"
            case "I", "L": return "1"
            default: return c
            }
        })
    }

    public static func decode(_ code: String) -> Data? {
        let cleaned = normalise(code)
        guard cleaned.count == 26 else { return nil }
        var bits = 0, value = 0
        var out = Data()
        for c in cleaned {
            guard let v = alphabet.firstIndex(of: c) else { return nil }
            value = (value << 5) | v
            bits += 5
            if bits >= 8 {
                out.append(UInt8((value >> (bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        return out.count == 16 ? out : nil
    }
}

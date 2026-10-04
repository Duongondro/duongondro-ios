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
    static let deviceTier = "device-key-tier"
    static let deviceID = "device-id"
    static let identitySeed = "identity-seed"
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

    public func current() throws -> Key? {
        guard let data = try store.read(SecretName.deviceKey),
              let tierRaw = try store.read(SecretName.deviceTier),
              let tier = Tier(rawValue: String(decoding: tierRaw, as: UTF8.self)) else { return nil }
        switch tier {
        case .hardware:
            return Key(agreement: try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: data), tier: tier)
        case .software, .tee:
            return Key(agreement: try P256.KeyAgreement.PrivateKey(rawRepresentation: data), tier: tier)
        }
    }

    public func currentOrCreate() throws -> Key {
        if let key = try current() { return key }
        if !preferSoftware, SecureEnclave.isAvailable,
           let enclave = try? SecureEnclave.P256.KeyAgreement.PrivateKey() {
            try store.write(SecretName.deviceKey, enclave.dataRepresentation)
            try store.write(SecretName.deviceTier, Data(Tier.hardware.rawValue.utf8))
            return Key(agreement: enclave, tier: .hardware)
        }
        let software = P256.KeyAgreement.PrivateKey()
        try store.write(SecretName.deviceKey, software.rawRepresentation)
        try store.write(SecretName.deviceTier, Data(Tier.software.rawValue.utf8))
        return Key(agreement: software, tier: .software)
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

    public static func decode(_ code: String) -> Data? {
        let cleaned = code.uppercased().compactMap { c -> Character? in
            switch c {
            case "-", " ": return nil
            case "O": return "0"
            case "I", "L": return "1"
            default: return c
            }
        }
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

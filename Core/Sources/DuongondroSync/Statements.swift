import DuongondroAPI
import Foundation

/// Signed statements' payloads in the canonical form the server checks and every
/// verifier hashes: compact JSON, keys in lexicographic order, integers only,
/// byte strings as unpadded base64url (docs/crypto.md, Signed statements). Built by
/// hand, so no encoder's choices can change a byte.
public enum Statements {
    public struct ListedDevice: Equatable, Sendable {
        public let id: UUID
        public let publicKey: Data
        public let tier: Tier
        public init(id: UUID, publicKey: Data, tier: Tier) {
            self.id = id
            self.publicKey = publicKey
            self.tier = tier
        }
    }

    public static func deviceList(devices: [ListedDevice], issuedAt: Date, user: UUID, version: Int) -> Data {
        let items = devices.map { d in
            #"{"id":"\#(d.id.uuidString.lowercased())","pk":"\#(base64url(d.publicKey))","tier":"\#(d.tier.rawValue)"}"#
        }.joined(separator: ",")
        let json = #"{"devices":[\#(items)],"issuedAt":\#(millis(issuedAt)),"user":"\#(user.uuidString.lowercased())","version":\#(version)}"#
        return Data(json.utf8)
    }

    /// Reads a device list back (to extend it with a new device).
    public static func parseDeviceList(_ payload: Data) -> (devices: [ListedDevice], version: Int)? {
        struct Raw: Decodable {
            struct D: Decodable { let id: String; let pk: String; let tier: String }
            let devices: [D]
            let version: Int
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: payload) else { return nil }
        let devices = raw.devices.compactMap { d -> ListedDevice? in
            guard let id = UUID(uuidString: d.id), let pk = fromBase64url(d.pk), let tier = Tier(rawValue: d.tier) else { return nil }
            return ListedDevice(id: id, publicKey: pk, tier: tier)
        }
        return devices.count == raw.devices.count ? (devices, raw.version) : nil
    }

    static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded(.down)) }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func fromBase64url(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b.append("=") }
        return Data(base64Encoded: b)
    }
}

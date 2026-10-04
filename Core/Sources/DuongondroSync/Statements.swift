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

    // MARK: Phase 4

    public static func invite(id: String, inviter: UUID, inviterIdentityPk: Data, expiresAt: Date) -> Data {
        Data(#"{"expiresAt":\#(millis(expiresAt)),"inviteId":"\#(id)","inviter":"\#(inviter.uuidString.lowercased())","inviterIdentityPk":"\#(base64url(inviterIdentityPk))"}"#.utf8)
    }

    public struct Invite: Equatable, Sendable {
        public let id: String
        public let inviter: UUID
        public let inviterIdentityPk: Data
        public let expiresAt: Date
    }

    public static func parseInvite(_ payload: Data) -> Invite? {
        struct Raw: Decodable { let expiresAt: Int64; let inviteId: String; let inviter: String; let inviterIdentityPk: String }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: payload), let inviter = UUID(uuidString: raw.inviter),
              let pk = fromBase64url(raw.inviterIdentityPk) else { return nil }
        return Invite(id: raw.inviteId, inviter: inviter, inviterIdentityPk: pk, expiresAt: date(raw.expiresAt))
    }

    public static func acceptance(inviteID: String, invitee: UUID, inviteeIdentityPk: Data) -> Data {
        Data(#"{"inviteId":"\#(inviteID)","invitee":"\#(invitee.uuidString.lowercased())","inviteeIdentityPk":"\#(base64url(inviteeIdentityPk))"}"#.utf8)
    }

    /// A public streak: tracked days only (docs/crypto.md), the day of the last one,
    /// and the deadline the server times streak-at-risk pushes by.
    public struct Streak: Equatable, Sendable {
        public var user: UUID
        public var practice: String
        public var day: String
        public var current: Int
        public var longest: Int
        public var deadline: Date
        public var seq: Int64

        public init(user: UUID, practice: String, day: String, current: Int, longest: Int, deadline: Date, seq: Int64) {
            self.user = user
            self.practice = practice
            self.day = day
            self.current = current
            self.longest = longest
            self.deadline = deadline
            self.seq = seq
        }
    }

    /// The practice id is the client's own and travels as is: lowercase letters,
    /// digits and hyphens (the server's rule), so it needs no escaping.
    public static func streak(_ s: Streak) -> Data {
        Data(#"{"current":\#(s.current),"day":"\#(s.day)","deadline":\#(millis(s.deadline)),"longest":\#(s.longest),"practice":"\#(s.practice)","seq":\#(s.seq),"user":"\#(s.user.uuidString.lowercased())"}"#.utf8)
    }

    public static func parseStreak(_ payload: Data) -> Streak? {
        struct Raw: Decodable {
            let current: Int
            let day: String
            let deadline: Int64
            let longest: Int
            let practice: String
            let seq: Int64
            let user: String
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: payload), let user = UUID(uuidString: raw.user) else { return nil }
        return Streak(user: user, practice: raw.practice, day: raw.day, current: raw.current, longest: raw.longest,
                      deadline: date(raw.deadline), seq: raw.seq)
    }

    static func date(_ millis: Int64) -> Date { Date(timeIntervalSince1970: Double(millis) / 1000) }

    /// To the nearest millisecond: a Date read back from the database or parsed from
    /// RFC 3339 can sit a hair below its millisecond, and rounding down would then
    /// name the one before, so the sealed time and the outer one would disagree.
    static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

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

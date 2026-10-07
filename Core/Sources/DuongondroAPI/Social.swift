import Foundation

/// Phase 4's operations: invitations, friends, public streaks and nudges.
extension APIClient {
    /// The commit the server was built from; needs no session.
    public func version() async throws -> ServerVersion { try await get("api/version") }

    public func setDisplayName(_ name: String) async throws {
        try await send("PATCH", "api/me", body: MeUpdate(displayName: name))
    }

    /// Sets or clears (nil) the grammatical gender friends' phones conjugate with:
    /// "male", "female" or "nonbinary".
    public func setGender(_ gender: String?) async throws {
        try await send("PATCH", "api/me", body: GenderUpdate(gender: gender))
    }

    /// A problem worth knowing about, without personal data (design: Keys, the
    /// Secure Enclave fallback).
    public func reportClientError(message: String, appVersion: String, osVersion: String,
                                  context: [String: String] = [:]) async throws {
        try await send("POST", "api/client-errors", body: ClientErrorReport(
            kind: "error", message: message, appVersion: appVersion, osVersion: osVersion, context: context))
    }

    // MARK: Invitations

    public func createInvite(_ invite: InviteInput) async throws {
        try await send("POST", "api/invites", body: invite)
    }

    /// Needs no session: the invitee may have none yet.
    public func invite(id: String) async throws -> InviteRecord {
        try await get("api/invites/\(id.uppercased())")
    }

    public func invites() async throws -> [InviteSummary] {
        let list: InviteList = try await get("api/invites")
        return list.invites
    }

    public func revokeInvite(id: String) async throws {
        let _: Empty = try await request("DELETE", "api/invites/\(id.uppercased())", query: [], body: Optional<Empty>.none)
    }

    public func redeemInvite(id: String, auth: Data, acceptance: SignedStatement) async throws -> UUID {
        let result: RedemptionResult = try await send("POST", "api/invites/\(id.uppercased())/redemptions",
                                                      body: Redemption(auth: auth, acceptance: acceptance))
        return result.inviterId
    }

    // MARK: Friends

    public func friends() async throws -> [Friend] {
        let list: FriendList = try await get("api/friends")
        return list.friends
    }

    public func friendsStreaks() async throws -> [StreakStatement] {
        let list: StreakList = try await get("api/friends/streaks")
        return list.streaks
    }

    public func unfriend(_ user: UUID) async throws {
        let _: Empty = try await request("DELETE", "api/friends/\(user.lowercased)", query: [], body: Optional<Empty>.none)
    }

    public func block(_ user: UUID) async throws {
        let _: Empty = try await request("PUT", "api/blocks/\(user.lowercased)", query: [], body: Optional<Empty>.none)
    }

    public func report(_ user: UUID, reason: String) async throws {
        let _: ReportResult = try await send("POST", "api/reports", body: ReportInput(userId: user, reason: reason))
    }

    public func setNotifyDone(_ on: Bool, for user: UUID) async throws {
        try await send("PUT", "api/friends/\(user.lowercased)/settings", body: FriendSettings(notifyDone: on))
    }

    /// One per friend per UTC day; a second answers 409.
    public func poke(_ user: UUID) async throws {
        let _: Empty = try await request("POST", "api/friends/\(user.lowercased)/pokes", query: [], body: Optional<Empty>.none)
    }

    // MARK: Public streaks

    public func ownStreaks() async throws -> [StreakStatement] {
        let list: StreakList = try await get("api/streaks")
        return list.streaks
    }

    public func putStreak(practice: String, _ statement: SignedStatement) async throws {
        try await send("PUT", "api/streaks/\(practice)", body: statement)
    }

    public func deleteStreak(practice: String) async throws {
        let _: Empty = try await request("DELETE", "api/streaks/\(practice)", query: [], body: Optional<Empty>.none)
    }
}

struct MeUpdate: Codable { let displayName: String }
/// `PATCH /api/me` with only `gender`: a value sets it, an explicit null clears it
/// (an absent field would leave it as it was).
struct GenderUpdate: Encodable {
    let gender: String?

    private enum CodingKeys: String, CodingKey { case gender }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(gender, forKey: .gender)
    }
}

struct ClientErrorReport: Codable {
    let kind: String
    let message: String
    let appVersion: String
    let osVersion: String
    let context: [String: String]
}

public struct ServerVersion: Codable, Equatable, Sendable {
    public let revision: String
    public let short: String
    public let modified: Bool
}

public struct InviteInput: Codable, Sendable {
    public let id: String
    public let auth: Data
    public let expiresAt: Date
    public let payload: Data
    public let signature: Data
    public let mac: Data
    public init(id: String, auth: Data, expiresAt: Date, payload: Data, signature: Data, mac: Data) {
        self.id = id
        self.auth = auth
        self.expiresAt = expiresAt
        self.payload = payload
        self.signature = signature
        self.mac = mac
    }
}

public struct InviteRecord: Codable, Equatable, Sendable {
    public let id: String
    public let payload: Data
    public let signature: Data
    public let mac: Data
    public let expiresAt: Date
}

public struct InviteSummary: Codable, Equatable, Sendable {
    public let id: String
    public let expiresAt: Date
    public let revokedAt: Date?
    public let createdAt: Date
}

struct InviteList: Codable { let invites: [InviteSummary] }
struct Redemption: Codable { let auth: Data; let acceptance: SignedStatement }
struct RedemptionResult: Codable { let inviterId: UUID }

public struct Friend: Codable, Equatable, Sendable {
    public let userId: UUID
    public let displayName: String
    /// "male", "female" or "nonbinary"; nil when not given.
    public let gender: String?
    public let notifyDone: Bool
    public let identityPublicKey: Data?
    public let since: Date
}

struct FriendList: Codable { let friends: [Friend] }

public struct StreakStatement: Codable, Equatable, Sendable {
    public let userId: UUID
    public let practice: String
    public let payload: Data
    public let signature: Data
}

struct StreakList: Codable { let streaks: [StreakStatement] }
struct FriendSettings: Codable { let notifyDone: Bool }
struct ReportInput: Codable { let userId: UUID; let reason: String }
struct ReportResult: Codable { let id: UUID }

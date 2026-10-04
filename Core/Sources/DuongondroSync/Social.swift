import CryptoKit
import DuongondroAPI
import DuongondroCore
import DuongondroCrypto
import DuongondroStore
import Foundation

/// An invite or add-friend link: `HTTPS://DUONGONDRO.APP/I/<id>#<secret>`, all
/// upper case so a QR code can carry it in alphanumeric mode (design: Social ›
/// Codes). The id is 8 Crockford characters the server knows; the secret, 16
/// characters (10 bytes) in the fragment, never reaches it.
public struct InviteLink: Equatable, Sendable {
    public enum Kind: String, Sendable { case invite = "I", friend = "F" }

    public let kind: Kind
    public let id: String
    public let secret: Data

    public init(kind: Kind, id: String, secret: Data) {
        self.kind = kind
        self.id = id
        self.secret = secret
    }

    public static let host = "DUONGONDRO.APP"

    public var string: String { "HTTPS://\(Self.host)/\(kind.rawValue)/\(id)#\(Crockford.encode(secret))" }
    public var url: URL { URL(string: string)! }

    /// Reads a link in any case, as typed, pasted or opened (a browser may lower
    /// the scheme and host); nil for anything else.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let hash = trimmed.firstIndex(of: "#") else { return nil }
        let fragment = String(trimmed[trimmed.index(after: hash)...])
        let head = trimmed[..<hash].uppercased()
        let prefix = "HTTPS://\(Self.host)/"
        guard head.hasPrefix(prefix) else { return nil }
        let parts = head.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let kind = Kind(rawValue: String(parts[0])),
              parts[1].count == 8, Crockford.decode(String(parts[1])) != nil,
              let id = Crockford.decode(String(parts[1])),
              let secret = Crockford.decode(fragment), secret.count == 10 else { return nil }
        // Canonical spelling: a hand-typed O, I or L becomes the 0 or 1 it stands for.
        self.init(kind: kind, id: Crockford.encode(id), secret: secret)
    }

    public static func new(_ kind: Kind) -> InviteLink {
        var id = Data(count: 5)
        var secret = Data(count: 10)
        _ = id.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 5, $0.baseAddress!) }
        _ = secret.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 10, $0.baseAddress!) }
        return InviteLink(kind: kind, id: Crockford.encode(id), secret: secret)
    }
}

/// Crockford base32 without separators, for byte strings that are a whole number
/// of 5-bit groups (5 bytes → 8 characters, 10 → 16).
public enum Crockford {
    public static func encode(_ data: Data) -> String {
        RecoveryCode.encode(data).replacingOccurrences(of: "-", with: "")
    }

    public static func decode(_ text: String) -> Data? {
        let cleaned = RecoveryCode.normalise(text)
        guard cleaned.count % 8 == 0 else { return nil }
        var bits = 0, value = 0
        var out = Data()
        for c in cleaned {
            guard let v = RecoveryCode.alphabet.firstIndex(of: c) else { return nil }
            value = (value << 5) | v
            bits += 5
            if bits >= 8 {
                out.append(UInt8((value >> (bits - 8)) & 0xFF))
                bits -= 8
            }
            value &= (1 << bits) - 1
        }
        return out
    }
}

/// Phase 4 on the phone: invitations, friends with pinned keys, and public streaks
/// (design: Social). Only streaks leave the phone, signed; counts never do. An
/// actor, so a publish and a toggle running at once never share state unguarded.
public actor Social {
    public let account: Account
    let now: @Sendable () -> Date

    public init(account: Account, now: @escaping @Sendable () -> Date = { Date() }) {
        self.account = account
        self.now = now
    }

    public enum Failure: Error, Equatable {
        /// The invite does not verify: its signature, or the MAC only the link's
        /// holder can make, is wrong. Possibly a server swapping the inviter's key.
        case notAuthentic
        case expired
        case ownInvite
    }

    var api: APIClient { account.api }
    var database: AppDatabase { account.database }

    func user() throws -> UUID {
        guard let state = try database.syncState() else { throw Account.Failure.accountHasNoKeys }
        return state.userID
    }

    // MARK: Inviting

    /// Makes a reusable invite (seven days) or an add-friend code (ten minutes).
    public func createInvite(_ kind: InviteLink.Kind = .invite) async throws -> (link: InviteLink, expiresAt: Date) {
        let me = try user()
        let identity = try account.identity()
        let lifetime: TimeInterval = kind == .invite ? 7 * 86400 : 10 * 60
        // Whole milliseconds, as the statement carries them.
        let expiresAt = Date(timeIntervalSince1970: (now().addingTimeInterval(lifetime).timeIntervalSince1970 * 1000).rounded(.down) / 1000)
        for _ in 0..<3 {
            let link = InviteLink.new(kind)
            let keys = E2EE.inviteKeys(secret: link.secret)
            let pk = identity.publicKey.rawRepresentation
            let payload = Statements.invite(id: link.id, inviter: me, inviterIdentityPk: pk, expiresAt: expiresAt)
            let signature = try E2EE.signStatement(type: "invite", payload: payload, identity: identity)
            do {
                try await api.createInvite(InviteInput(id: link.id, auth: keys.auth, expiresAt: expiresAt, payload: payload,
                                                       signature: signature, mac: E2EE.inviteMAC(pin: keys.pin, inviterIdentityPk: pk)))
                return (link, expiresAt)
            } catch APIError.conflict {
                continue // the id is taken: draw another
            }
        }
        throw APIError.conflict("no free invite id")
    }

    // MARK: Being invited

    public struct CheckedInvite: Equatable, Sendable {
        public let link: InviteLink
        public let inviter: UUID
        public let inviterIdentityPk: Data
        public let expiresAt: Date
    }

    /// Fetches the invite and checks it as the design says: the statement is signed
    /// by the key it names, and the MAC under the link's pin covers that key, so the
    /// server (which knows only auth) cannot have swapped it.
    public func check(_ link: InviteLink) async throws -> CheckedInvite {
        let record = try await api.invite(id: link.id)
        guard let st = Statements.parseInvite(record.payload), st.id == link.id,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: st.inviterIdentityPk),
              E2EE.verifyStatement(type: "invite", payload: record.payload, signature: record.signature, identity: key)
        else { throw Failure.notAuthentic }
        let pin = E2EE.inviteKeys(secret: link.secret).pin
        let expected = E2EE.inviteMAC(pin: pin, inviterIdentityPk: st.inviterIdentityPk)
        guard Self.constantTimeEqual(expected, record.mac) else { throw Failure.notAuthentic }
        guard st.expiresAt > now() else { throw Failure.expired }
        return CheckedInvite(link: link, inviter: st.inviter, inviterIdentityPk: st.inviterIdentityPk, expiresAt: st.expiresAt)
    }

    /// Redeems a checked invite with a signed acceptance, and pins the inviter's
    /// key as the invite proved it.
    public func redeem(_ invite: CheckedInvite) async throws {
        let me = try user()
        guard invite.inviter != me else { throw Failure.ownInvite }
        let identity = try account.identity()
        let payload = Statements.acceptance(inviteID: invite.link.id, invitee: me,
                                            inviteeIdentityPk: identity.publicKey.rawRepresentation)
        let signature = try E2EE.signStatement(type: "acceptance", payload: payload, identity: identity)
        let auth = E2EE.inviteKeys(secret: invite.link.secret).auth
        _ = try await api.redeemInvite(id: invite.link.id, auth: auth,
                                       acceptance: SignedStatement(payload: payload, signature: signature))
        // The key the invite proved wins over anything pinned on the server's word,
        // so a re-invite is how a changed key gets sorted out.
        let name = (try? await api.friends())?.first { $0.userId == invite.inviter }?.displayName ?? ""
        try database.repin(invite.inviter, identityPublicKey: invite.inviterIdentityPk, displayName: name, at: now())
    }

    // MARK: Friends

    public struct FriendStreak: Equatable, Sendable {
        public let practice: String
        public let day: CivilDate?
        public let current: Int
        public let longest: Int
        public let deadline: Date
        public let seq: Int64
    }

    public struct FriendView: Equatable, Sendable, Identifiable {
        public let userID: UUID
        public let displayName: String
        public let notifyDone: Bool
        /// The server now names a different key than the one pinned: nothing from
        /// this friend is shown until it is sorted out (meet, re-invite).
        public let keyChanged: Bool
        public let streaks: [FriendStreak]
        public var id: UUID { userID }
    }

    /// The server's friend list, with keys pinned on first sight and every streak
    /// verified against the pinned key; one that does not verify is dropped.
    public func friends() async throws -> [FriendView] {
        let generation = database.generation
        let listed = try await api.friends()
        let statements = try await api.friendsStreaks()
        var pins = Dictionary(uniqueKeysWithValues: try database.friends().map { ($0.userID, $0) })
        for f in listed where pins[f.userId] == nil || pins[f.userId]?.displayName != f.displayName {
            guard let pk = f.identityPublicKey ?? pins[f.userId]?.identityPublicKey else { continue }
            pins[f.userId] = try database.pin(f.userId, identityPublicKey: pk, displayName: f.displayName, at: now(),
                                              generation: generation)
        }
        try database.keepFriends(Set(listed.map(\.userId)), generation: generation)
        var views: [FriendView] = []
        for f in listed {
            let pin = pins[f.userId]
            let keyChanged = pin == nil || (f.identityPublicKey != nil && f.identityPublicKey != pin?.identityPublicKey)
            var streaks: [FriendStreak] = []
            if !keyChanged, let pin, let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pin.identityPublicKey) {
                for s in statements where s.userId == f.userId {
                    guard E2EE.verifyStatement(type: "streak", payload: s.payload, signature: s.signature, identity: key),
                          let st = Statements.parseStreak(s.payload), st.user == f.userId, st.practice == s.practice,
                          // Never older than one already seen: the server could replay
                          // yesterday's statement to deflate a streak.
                          st.seq >= (try database.seenSeq(f.userId, practice: st.practice))
                    else { continue }
                    try database.noteSeq(f.userId, practice: st.practice, seq: st.seq, generation: generation)
                    streaks.append(FriendStreak(practice: st.practice, day: CivilDate(st.day), current: st.current,
                                                longest: st.longest, deadline: st.deadline, seq: st.seq))
                }
            }
            views.append(FriendView(userID: f.userId, displayName: f.displayName, notifyDone: f.notifyDone,
                                    keyChanged: keyChanged, streaks: streaks.sorted { $0.current > $1.current }))
        }
        return views
    }

    /// Ends the friendship both ways and forgets the pinned key.
    public func unfriend(_ user: UUID) async throws {
        try await api.unfriend(user)
        try database.forgetFriend(user)
    }

    /// Blocks (ending any friendship, both ways) and forgets the pinned key.
    public func block(_ user: UUID) async throws {
        try await api.block(user)
        try database.forgetFriend(user)
    }

    // MARK: Public streaks

    /// What would be published for a practice: tracked days only, never a seed.
    public static func statement(for practice: String, sessions: [Session], user: UUID, seq: Int64, now: Date,
                                 timeZone: TimeZone) -> Statements.Streak? {
        let r = Streak.of(practiceID: practice, sessions: sessions, seed: nil, now: now, timeZone: timeZone)
        guard let day = r.lastDay, let deadline = r.deadline else { return nil }
        return Statements.Streak(user: user, practice: practice, day: day.description, current: r.currentTracked,
                                 longest: r.longestTracked, deadline: deadline, seq: seq)
    }

    /// Publishes every public practice's streak whose content changed since the
    /// last time; returns how many went up. The seq is the time in milliseconds,
    /// kept above the last one sent.
    @discardableResult
    public func publishStreaks(timeZone: TimeZone = .current) async throws -> Int {
        let generation = database.generation
        let me = try user()
        let identity = try account.identity()
        // The server is the record of what is public: another phone or a restore
        // may have made a practice public that this phone did not know about.
        var published: [String: Int64] = [:]
        for s in try await api.ownStreaks() {
            if let st = Statements.parseStreak(s.payload) { published[s.practice] = st.seq }
        }
        try database.mergePublished(published, generation: generation)
        let snapshot = try database.snapshot()
        var sent = 0
        for (practice, lastSeq) in try database.publicStreakSeqs() {
            let seq = max(lastSeq + 1, Statements.millis(now()))
            guard var st = Self.statement(for: practice, sessions: snapshot.sessions(of: practice), user: me, seq: seq,
                                          now: now(), timeZone: timeZone) else { continue }
            if let last = lastPublished[practice], last == content(st) { continue }
            // Made private while this publish ran: leave it.
            guard try database.isPublic(practice) else { continue }
            let payload = Statements.streak(st)
            do {
                try await api.putStreak(practice: practice, SignedStatement(
                    payload: payload, signature: try E2EE.signStatement(type: "streak", payload: payload, identity: identity)))
            } catch APIError.conflict {
                // Another phone sent a higher seq: go above the server's.
                let stored = try await api.ownStreaks().first { $0.practice == practice }.flatMap { Statements.parseStreak($0.payload) }
                st.seq = max(st.seq, (stored?.seq ?? 0) + 1)
                let retry = Statements.streak(st)
                try await api.putStreak(practice: practice, SignedStatement(
                    payload: retry, signature: try E2EE.signStatement(type: "streak", payload: retry, identity: identity)))
            }
            // Made private while the statement was on its way: take it back down.
            guard try database.isPublic(practice) else {
                do { try await api.deleteStreak(practice: practice) } catch APIError.notFound {}
                continue
            }
            try database.savePublishedSeq(practice, st.seq, generation: generation)
            lastPublished[practice] = content(st)
            sent += 1
        }
        return sent
    }

    /// Makes a practice's streak public (published now) or private (removed from the server).
    public func setPublic(_ practice: String, _ isPublic: Bool) async throws {
        if isPublic {
            try database.setPublic(practice, true)
            lastPublished[practice] = nil
            try await publishStreaks()
        } else {
            // Private here first, so a publish already under way sees it and takes
            // its statement back down; restored if the server cannot be reached.
            try database.setPublic(practice, false)
            do {
                try await api.deleteStreak(practice: practice)
            } catch APIError.notFound {
            } catch {
                try database.setPublic(practice, true)
                throw error
            }
        }
    }

    private var lastPublished: [String: String] = [:]
    private func content(_ s: Statements.Streak) -> String { "\(s.day) \(s.current) \(s.longest) \(Statements.millis(s.deadline))" }

    nonisolated static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

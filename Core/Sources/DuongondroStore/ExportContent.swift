import Foundation
import DuongondroCore

/// What the PDF and CSV exports show (design: Data export and deletion › Export),
/// built on the phone from the local database and, with an account, the server's
/// `GET /api/me/export` with the sealed sessions opened here. Offline and local
/// mode build it from the local database alone. Final sessions only, and no
/// cover photos.
public struct ExportContent: Equatable, Sendable {
    /// Where the server's part stands: no account (local mode), included, or an
    /// account whose part could not be fetched.
    public enum ServerPart: Equatable, Sendable { case local, included, missing }

    public struct Account: Equatable, Sendable {
        public var displayName: String
        public var username: String?
        public var gender: String?
        public var emails: [String]
        public var createdAt: Date?
        public var passkeys: [Passkey]
        public var devices: [Device]
    }

    public struct Passkey: Equatable, Sendable {
        public var createdAt: Date
        public var lastUsedAt: Date?
    }

    public struct Device: Equatable, Sendable {
        public var id: String
        /// "hardware", "tee" or "software" (design: Keys).
        public var tier: String
        public var createdAt: Date
    }

    public struct PracticeRow: Equatable, Sendable {
        public var id: String
        public var practice: Practice
        public var streakOnly: Bool
        public var archived: Bool
        public var malaSize: Int
        /// Lifetime total: the opening count plus every session.
        public var total: Int
        /// The round now under way and the count within it; nil for streak-only or open-ended practices.
        public var round: Int?
        public var inRound: Int?
        public var currentStreak: Int
        public var longestStreak: Int
        public var isPublic: Bool
    }

    public struct SessionRow: Equatable, Sendable {
        public var id: UUID
        public var practiceID: String
        public var start: Date
        public var timeZone: TimeZone
        /// The local date the session started on.
        public var startDay: CivilDate
        /// The day it counts for.
        public var day: CivilDate
        /// The person picked `day` in the after-midnight sheet.
        public var dayChosen: Bool
        public var count: Int
        /// The round the session's last count fell in; nil where there are no rounds.
        public var round: Int?
    }

    public struct Friend: Equatable, Sendable {
        public var displayName: String
        public var since: Date?
    }

    public struct Invite: Equatable, Sendable {
        public var id: String
        /// Made by this account (the friendship code it shares), or one it redeemed.
        public var made: Bool
        public var createdAt: Date
        public var expiresAt: Date?
        public var revokedAt: Date?
        /// How many people redeemed a code this account made.
        public var redemptions: Int
    }

    public struct Block: Equatable, Sendable {
        /// The blocked person's display name where this phone knows it, otherwise their account id.
        public var who: String
        public var createdAt: Date
    }

    public struct Report: Equatable, Sendable {
        public var about: String
        public var reason: String
        public var createdAt: Date
    }

    public var exportedAt: Date
    public var timeZone: TimeZone
    public var serverPart: ServerPart
    /// nil in local mode.
    public var account: Account?
    public var practices: [PracticeRow]
    /// Ordered by practice (as `practices`), then by start.
    public var sessions: [SessionRow]
    public var friends: [Friend]
    public var invites: [Invite]
    public var blocks: [Block]
    public var reports: [Report]
    /// Sealed sessions that could not be opened or were refused, so they are only in the JSON.
    public var unreadable: Int

    /// What the phone knows of its account without the server: Settings' cached
    /// profile and the pinned friends.
    public struct Local: Sendable {
        public var displayName: String
        public var username: String?
        public var email: String?
        public var gender: String?
        public var friends: [PinnedFriend]

        public init(displayName: String = "", username: String? = nil, email: String? = nil, gender: String? = nil,
                    friends: [PinnedFriend] = []) {
            self.displayName = displayName
            self.username = username
            self.email = email
            self.gender = gender
            self.friends = friends
        }
    }

    /// `local` is nil in local mode (no account on this phone). `knownSessionIDs` are
    /// all of this phone's session ids, deleted ones too, as for the JSON.
    public static func build(snapshot: Snapshot, server: DataExport.Server?, local: Local?,
                             knownSessionIDs: Set<UUID> = [], now: Date = Date(),
                             timeZone: TimeZone = .current) -> ExportContent {
        let s = DataExport.merged(snapshot.withoutPending, server, known: knownSessionIDs)
        let part: ServerPart = server != nil ? .included : (local != nil ? .missing : .local)
        let tables = server.flatMap { ServerTables(raw: $0.raw) }

        let ordered = s.practices.sorted { ($0.archived ? 1 : 0, $0.sortOrder) < ($1.archived ? 1 : 0, $1.sortOrder) }
        var practices: [PracticeRow] = []
        var sessions: [SessionRow] = []
        for t in ordered {
            let own = s.sessions.filter { $0.practiceID == t.id }
                .sorted { ($0.startedAt, $0.id.uuidString) < ($1.startedAt, $1.id.uuidString) }
            let rounds = t.rounds(sessions: own)
            let streak = Streak.of(practiceID: t.id, sessions: own, seed: s.seed(of: t.id), now: now, timeZone: timeZone)
            practices.append(PracticeRow(
                id: t.id, practice: t.practice, streakOnly: t.streakOnly, archived: t.archived,
                malaSize: t.practice.effectiveMalaSize(default: s.preferences.malaSize),
                total: t.lifetime(sessions: own), round: rounds?.round, inRound: rounds?.inRound,
                currentStreak: streak.current, longestStreak: streak.longest,
                isPublic: s.publicPractices.contains(t.id)))
            var running = t.openingCount
            let target = rounds != nil ? t.practice.target : nil
            for x in own {
                running += x.amount
                sessions.append(SessionRow(
                    id: x.id, practiceID: t.id, start: x.startedAt, timeZone: x.timeZone,
                    startDay: CivilDate.of(x.startedAt, in: x.timeZone), day: x.day, dayChosen: x.chosenDay != nil,
                    count: x.amount, round: target.map { Self.round(after: running, target: $0) }))
            }
        }

        var account: Account?
        var friends: [Friend] = []
        var invites: [Invite] = []
        var blocks: [Block] = []
        var reports: [Report] = []
        if let tables {
            account = tables.account
            friends = tables.friends
            invites = tables.invites
            var names = Dictionary(local?.friends.map { ($0.userID.uuidString.lowercased(), $0.displayName) } ?? [],
                                   uniquingKeysWith: { a, _ in a })
            for (id, name) in tables.friendNames { names[id] = name }
            func who(_ id: String?) -> String {
                guard let id else { return "" }
                return names[id.lowercased()].flatMap { $0.isEmpty ? nil : $0 } ?? id.lowercased()
            }
            blocks = tables.blocks.map { Block(who: who($0.id), createdAt: $0.at) }
            reports = tables.reports.map { Report(about: who($0.id), reason: $0.reason, createdAt: $0.at) }
        } else if let local {
            account = Account(displayName: local.displayName, username: local.username, gender: local.gender,
                              emails: local.email.map { [$0] } ?? [], createdAt: nil, passkeys: [], devices: [])
            friends = local.friends.filter(\.listed).map { Friend(displayName: $0.displayName, since: $0.pinnedAt) }
        }

        return ExportContent(exportedAt: now, timeZone: timeZone, serverPart: part, account: account,
                             practices: practices, sessions: sessions, friends: friends, invites: invites,
                             blocks: blocks, reports: reports,
                             unreadable: (server?.unreadable ?? 0) + (server?.refused ?? 0))
    }

    /// The round a running total ends in: the count that completes a round still belongs to it.
    static func round(after total: Int, target: Int) -> Int {
        total <= 0 ? 1 : (total - 1) / target + 1
    }

    /// Sessions of one practice, grouped by the day they started on, in order.
    public func sessionDays(of practiceID: String) -> [(day: CivilDate, sessions: [SessionRow])] {
        var out: [(day: CivilDate, sessions: [SessionRow])] = []
        for x in sessions where x.practiceID == practiceID {
            if out.last?.day == x.startDay { out[out.count - 1].sessions.append(x) } else { out.append((x.startDay, [x])) }
        }
        return out
    }
}

/// The parts of `GET /api/me/export` the PDF and CSV show, read leniently: a
/// missing table is empty, an unknown field ignored.
struct ServerTables {
    var account: ExportContent.Account
    var friends: [ExportContent.Friend]
    var friendNames: [String: String]
    var invites: [ExportContent.Invite]
    var blocks: [(id: String?, at: Date)]
    var reports: [(id: String?, reason: String, at: Date)]

    init?(raw: Data) {
        guard let o = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { return nil }
        func rows(_ key: String) -> [[String: Any]] { o[key] as? [[String: Any]] ?? [] }
        let user = o["users"] as? [String: Any] ?? [:]
        let me = (user["id"] as? String)?.lowercased()
        let emails = rows("auth_identities").compactMap { $0["email"] as? String }
        account = ExportContent.Account(
            displayName: user["displayName"] as? String ?? "",
            username: user["username"] as? String, gender: user["gender"] as? String,
            emails: emails, createdAt: Self.date(user["createdAt"]),
            passkeys: rows("credentials").compactMap { r in
                Self.date(r["createdAt"]).map { ExportContent.Passkey(createdAt: $0, lastUsedAt: Self.date(r["lastUsedAt"])) }
            },
            devices: rows("devices").compactMap { r in
                Self.date(r["createdAt"]).map {
                    ExportContent.Device(id: (r["id"] as? String ?? "").lowercased(), tier: r["tier"] as? String ?? "", createdAt: $0)
                }
            })
        let friendRows = rows("friendships")
        friends = friendRows.map { ExportContent.Friend(displayName: $0["displayName"] as? String ?? "", since: Self.date($0["createdAt"])) }
        friendNames = Dictionary(friendRows.compactMap { r in
            (r["id"] as? String).map { ($0.lowercased(), r["displayName"] as? String ?? "") }
        }, uniquingKeysWith: { a, _ in a })
        let redemptions = rows("invite_redemptions")
        var made: [ExportContent.Invite] = rows("invites").compactMap { r in
            guard let id = r["id"] as? String, let at = Self.date(r["createdAt"]) else { return nil }
            return ExportContent.Invite(id: id, made: true, createdAt: at, expiresAt: Self.date(r["expiresAt"]),
                                        revokedAt: Self.date(r["revokedAt"]),
                                        redemptions: redemptions.filter { $0["inviteId"] as? String == id }.count)
        }
        let madeIDs = Set(made.map(\.id))
        for r in redemptions {
            guard let id = r["inviteId"] as? String, !madeIDs.contains(id), let at = Self.date(r["createdAt"]),
                  me == nil || (r["inviteeId"] as? String)?.lowercased() == me else { continue }
            made.append(ExportContent.Invite(id: id, made: false, createdAt: at, expiresAt: nil, revokedAt: nil, redemptions: 0))
        }
        invites = made.sorted { $0.createdAt < $1.createdAt }
        blocks = rows("blocks").compactMap { r in Self.date(r["createdAt"]).map { (r["blockedId"] as? String, $0) } }
        reports = rows("reports").compactMap { r in
            Self.date(r["createdAt"]).map { (r["reportedId"] as? String, r["reason"] as? String ?? "", $0) }
        }
    }

    /// RFC 3339 as Go writes it, with up to nine fraction digits.
    static func date(_ value: Any?) -> Date? {
        guard var s = value as? String else { return nil }
        if let dot = s.firstIndex(of: "."), let end = s[dot...].firstIndex(where: { !$0.isNumber && $0 != "." }) {
            let digits = s[s.index(after: dot)..<end]
            if digits.count > 3 { s.removeSubrange(s.index(dot, offsetBy: 4)..<end) }
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = s.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return f.date(from: s)
    }
}

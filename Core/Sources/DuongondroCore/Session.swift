import Foundation

/// One logged session of one practice. Personal: inside the sealed blobs once
/// sync exists, never published. Carries no source (button, watch, custom).
public struct Session: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let practiceID: String
    /// Count added; 0 for a streak-only "done today".
    public var amount: Int
    /// Exact when the user tapped Start, otherwise estimated (`SessionStart`).
    public var startedAt: Date
    public var startExact: Bool
    /// The zone the phone was in at the start (an identifier such as "Europe/Amsterdam").
    public var timeZoneID: String
    /// The user's explicit choice in the after-midnight sheet; nil means the start's own date.
    public var chosenDay: CivilDate?
    public let loggedAt: Date
    /// A correction of the practice's count (design decision 34): `amount` is the
    /// change, which may be negative. It goes into the lifetime total and rounds,
    /// never into a day's total, malas, the usual time or the streak.
    public var correction: Bool

    /// `id` defaults to a UUIDv7 stamped with the logging time, the form the server
    /// requires for session ids (design: From ngondro-tracker).
    public init(id: UUID? = nil, practiceID: String, amount: Int, startedAt: Date, startExact: Bool,
                timeZoneID: String, chosenDay: CivilDate? = nil, loggedAt: Date, correction: Bool = false) {
        self.id = id ?? UUID.v7(at: loggedAt)
        self.practiceID = practiceID
        self.amount = amount
        self.startedAt = startedAt
        self.startExact = startExact
        self.timeZoneID = timeZoneID
        self.chosenDay = chosenDay
        self.loggedAt = loggedAt
        self.correction = correction
    }

    /// A correction saved now: the difference between the count the person typed
    /// and the one the app had. Exact, logged at once, in the phone's zone.
    public static func countCorrection(practiceID: String, change: Int, at now: Date, timeZone: TimeZone) -> Session {
        Session(practiceID: practiceID, amount: change, startedAt: now, startExact: true,
                timeZoneID: timeZone.identifier, loggedAt: now, correction: true)
    }

    /// Whether the session belongs to its day: every session but a correction,
    /// which changes the total and nothing a day shows (a day's total, malas, the streak).
    public var countsForDay: Bool { !correction }

    public var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .gmt }

    /// The day this session counts for: the local date it started on, unless the user chose.
    public var day: CivilDate { chosenDay ?? CivilDate.of(startedAt, in: timeZone) }

    public var streakEvent: Streak.Event {
        .session(start: startedAt, timeZone: timeZone, day: chosenDay)
    }
}

/// The after-midnight sheet: a session logged after midnight whose estimated
/// start falls before it counts for the earlier day, and the app says so with a
/// one-tap switch to the other day. Nothing is backdated further than that.
public struct AfterMidnight: Equatable, Sendable {
    /// The day the session counts for now.
    public let countedFor: CivilDate
    /// The one alternative offered.
    public let alternative: CivilDate
    /// The estimated start, for "you started around 23:30".
    public let startedAround: Date

    /// Nil when there is nothing to say: an exact start, or start and logging on one date.
    public static func check(_ session: Session) -> AfterMidnight? {
        guard !session.startExact else { return nil }
        let tz = session.timeZone
        let started = CivilDate.of(session.startedAt, in: tz)
        let logged = CivilDate.of(session.loggedAt, in: tz)
        guard started < logged else { return nil }
        let counted = session.chosenDay ?? started
        return AfterMidnight(countedFor: counted, alternative: counted == started ? logged : started,
                             startedAround: session.startedAt)
    }
}

/// A practice the user tracks: a catalogue entry plus their own settings.
public struct TrackedPractice: Identifiable, Hashable, Codable, Sendable {
    public var practice: Practice
    /// A "done today" check with no count (never for ngöndro).
    public var streakOnly: Bool
    /// Count brought in from paper or a spreadsheet at onboarding, across all rounds.
    public var openingCount: Int
    public var archived: Bool
    public var sortOrder: Int

    public var id: String { practice.id }

    public init(practice: Practice, streakOnly: Bool = false, openingCount: Int = 0,
                archived: Bool = false, sortOrder: Int = 0) {
        self.practice = practice
        self.streakOnly = practice.streakOnlyAllowed && streakOnly
        self.openingCount = max(0, openingCount)
        self.archived = archived
        self.sortOrder = sortOrder
    }

    /// The opening count for someone in `round` (1-based) with `inRound` done in it.
    /// In round 1 the count may run past the target (a lifetime total typed in
    /// one go, which then lands in its own round); in a later round it is the
    /// count within that round, so it stops short of the target.
    public static func openingCount(round: Int, inRound: Int, target: Int?) -> Int {
        guard let target, target > 0 else { return max(0, inRound) }
        let r = max(1, round)
        let count = r > 1 ? min(max(0, inRound), target - 1) : max(0, inRound)
        return (r - 1) * target + count
    }

    /// Lifetime total: the opening count plus every logged session and correction,
    /// never below zero.
    public func lifetime(sessions: [Session]) -> Int {
        max(0, openingCount + sessions.lazy.filter { $0.practiceID == id }.reduce(0) { $0 + $1.amount })
    }

    /// The change a correction saves so the total becomes `count` (design decision
    /// 34). Measured from the sum before clamping at zero, so the total afterwards
    /// is exactly `count` even after corrections took it below zero.
    public func correction(to count: Int, sessions: [Session]) -> Int {
        max(0, count) - (openingCount + sessions.lazy.filter { $0.practiceID == id }.reduce(0) { $0 + $1.amount })
    }

    /// Round progress, or nil for open-ended or streak-only practices.
    public func rounds(sessions: [Session]) -> RoundProgress? {
        guard !streakOnly, let target = practice.target, target > 0 else { return nil }
        return RoundProgress(lifetime: lifetime(sessions: sessions), target: target)
    }
}

/// A private streak seed from onboarding: counts on the user's own Today, never
/// in public streaks or the leaderboard.
public struct StreakSeed: Hashable, Codable, Sendable {
    public let practiceID: String
    public var days: Int
    public var longest: Int?
    public var lastDay: CivilDate
    public var timeZoneID: String

    public init(practiceID: String, days: Int, longest: Int? = nil, lastDay: CivilDate, timeZoneID: String) {
        self.practiceID = practiceID
        self.days = days
        self.longest = longest
        self.lastDay = lastDay
        self.timeZoneID = timeZoneID
    }

    public var streakSeed: Streak.Seed {
        Streak.Seed(days: days, lastDay: lastDay, timeZone: TimeZone(identifier: timeZoneID) ?? .gmt)
    }
}

public extension Streak {
    /// One practice's streak from its sessions and optional seed.
    static func of(practiceID: String, sessions: [Session], seed: StreakSeed?, now: Date, timeZone: TimeZone) -> Result {
        var r = compute(events: sessions.filter { $0.practiceID == practiceID && $0.countsForDay }.map(\.streakEvent),
                        seed: seed?.practiceID == practiceID ? seed?.streakSeed : nil,
                        now: now, nowTimeZone: timeZone)
        if let longest = seed?.longest { r.longest = max(r.longest, longest) }
        return r
    }

    /// The headline streak on Today: days with any practice. With several seeds,
    /// the one that gives the longest current streak wins.
    static func headline(sessions: [Session], seeds: [StreakSeed], now: Date, timeZone: TimeZone) -> Result {
        let events = sessions.filter(\.countsForDay).map(\.streakEvent)
        let candidates = [nil] + seeds.map(\.streakSeed)
        return candidates
            .map { compute(events: events, seed: $0, now: now, nowTimeZone: timeZone) }
            .max { ($0.current, $0.longest) < ($1.current, $1.longest) }!
    }
}

public extension Session {
    /// What a day shows of a practice: the sum of its sessions on `day`, corrections left out.
    static func dayTotal(_ sessions: [Session], on day: CivilDate) -> Int {
        sessions.filter { $0.countsForDay && $0.day == day }.reduce(0) { $0 + $1.amount }
    }

    /// Whether any session counted for `day` (a correction never does).
    static func practised(_ sessions: [Session], on day: CivilDate) -> Bool {
        sessions.contains { $0.countsForDay && $0.day == day }
    }
}

/// Correcting a practice's count (design decision 34): the person types the count
/// as it is now, and the difference is saved as a correction session.
public enum CountCorrection {
    /// The lifetime total for `round` (1-based) with `inRound` done in it; without
    /// a target, `inRound` is the whole count. Never below zero.
    public static func lifetime(round: Int, inRound: Int, target: Int?) -> Int {
        guard let target, target > 0 else { return max(0, inRound) }
        return (max(1, round) - 1) * target + max(0, inRound)
    }

    /// Where the count stands now, to prefill the form: the round and the count in
    /// it, or round 1 and the lifetime total without a target.
    public static func prefill(lifetime: Int, target: Int?) -> (round: Int, inRound: Int) {
        guard let target, target > 0 else { return (1, max(0, lifetime)) }
        let r = RoundProgress(lifetime: max(0, lifetime), target: target)
        return (r.round, r.inRound)
    }
}

public extension SessionStart {
    /// Lengths of the sessions the user timed with Start, for the median estimate.
    static func timedLengths(_ sessions: [Session]) -> [TimeInterval] {
        sessions.filter { $0.startExact && $0.countsForDay }.map { $0.loggedAt.timeIntervalSince($0.startedAt) }.filter { $0 > 0 }
    }
}

extension UUID {
    /// A version-7 UUID (RFC 9562): 48 bits of Unix milliseconds, then random bits.
    public static func v7(at date: Date = Date()) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { bytes[i] = UInt8.random(in: 0...255) }
        let ms = UInt64(max(0, (date.timeIntervalSince1970 * 1000).rounded(.down)))
        for i in 0..<6 { bytes[i] = UInt8((ms >> (8 * (5 - i))) & 0xFF) }
        bytes[6] = (bytes[6] & 0x0F) | 0x70
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Whether this is a version-7, RFC 9562 variant UUID.
    public var isV7: Bool { uuid.6 >> 4 == 7 && uuid.8 >> 6 == 0b10 }
}

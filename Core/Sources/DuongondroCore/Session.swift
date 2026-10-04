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

    public init(id: UUID = UUID(), practiceID: String, amount: Int, startedAt: Date, startExact: Bool,
                timeZoneID: String, chosenDay: CivilDate? = nil, loggedAt: Date) {
        self.id = id
        self.practiceID = practiceID
        self.amount = amount
        self.startedAt = startedAt
        self.startExact = startExact
        self.timeZoneID = timeZoneID
        self.chosenDay = chosenDay
        self.loggedAt = loggedAt
    }

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

    /// Lifetime total: the opening count plus every logged session.
    public func lifetime(sessions: [Session]) -> Int {
        openingCount + sessions.lazy.filter { $0.practiceID == id }.reduce(0) { $0 + $1.amount }
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
        var r = compute(events: sessions.filter { $0.practiceID == practiceID }.map(\.streakEvent),
                        seed: seed?.practiceID == practiceID ? seed?.streakSeed : nil,
                        now: now, nowTimeZone: timeZone)
        if let longest = seed?.longest { r.longest = max(r.longest, longest) }
        return r
    }

    /// The headline streak on Today: days with any practice. With several seeds,
    /// the one that gives the longest current streak wins.
    static func headline(sessions: [Session], seeds: [StreakSeed], now: Date, timeZone: TimeZone) -> Result {
        let events = sessions.map(\.streakEvent)
        let candidates = [nil] + seeds.map(\.streakSeed)
        return candidates
            .map { compute(events: events, seed: $0, now: now, nowTimeZone: timeZone) }
            .max { ($0.current, $0.longest) < ($1.current, $1.longest) }!
    }
}

public extension SessionStart {
    /// Lengths of the sessions the user timed with Start, for the median estimate.
    static func timedLengths(_ sessions: [Session]) -> [TimeInterval] {
        sessions.filter(\.startExact).map { $0.loggedAt.timeIntervalSince($0.startedAt) }.filter { $0 > 0 }
    }
}

import Foundation

/// The streak rules of `duongondro-api/docs/streaks.md`, tested against the
/// shared `streak-cases.json` (copied into the test resources unchanged).
public enum Streak {
    public enum Kind: String, Codable, Sendable {
        case session
        case bardo
    }

    public struct Event: Sendable {
        public let kind: Kind
        public let start: Date?
        public let timeZone: TimeZone
        public let day: CivilDate?

        /// A logged session; `day` is the user's explicit choice in the after-midnight sheet.
        public static func session(start: Date, timeZone: TimeZone, day: CivilDate? = nil) -> Event {
            Event(kind: .session, start: start, timeZone: timeZone, day: day)
        }

        /// A bardo day covering `day`.
        public static func bardo(day: CivilDate, timeZone: TimeZone) -> Event {
            Event(kind: .bardo, start: nil, timeZone: timeZone, day: day)
        }
    }

    public struct Seed: Sendable {
        public let days: Int
        public let lastDay: CivilDate
        public let timeZone: TimeZone

        public init(days: Int, lastDay: CivilDate, timeZone: TimeZone) {
            self.days = days
            self.lastDay = lastDay
            self.timeZone = timeZone
        }
    }

    public struct Result: Equatable, Sendable {
        public var current = 0
        public var currentTracked = 0
        public var longest = 0
        public var longestTracked = 0
        public var lastDay: CivilDate?
        public var deadline: Date?
    }

    private struct Resolved {
        let kind: Kind
        let day: CivilDate
        let timeZone: TimeZone
        let at: Date
        let index: Int
    }

    public static func compute(events: [Event], seed: Seed? = nil, now: Date, nowTimeZone: TimeZone) -> Result {
        var resolved: [Resolved] = []
        for (index, e) in events.enumerated() {
            switch e.kind {
            case .session:
                guard let start = e.start else { continue }
                var day = CivilDate.of(start, in: e.timeZone)
                var at = start
                if let chosen = e.day {
                    day = chosen
                    let lastSecond = chosen.startOfDay(offset: 1, in: e.timeZone).addingTimeInterval(-1)
                    if lastSecond < at { at = lastSecond }
                }
                resolved.append(Resolved(kind: .session, day: day, timeZone: e.timeZone, at: at, index: index))
            case .bardo:
                guard let day = e.day else { continue }
                resolved.append(Resolved(kind: .bardo, day: day, timeZone: e.timeZone,
                                         at: day.startOfDay(in: e.timeZone), index: index))
            }
        }
        resolved.sort { a, b in
            if a.at != b.at { return a.at < b.at }
            if a.kind != b.kind { return a.kind == .session }
            return a.index < b.index
        }

        var result = Result()
        var started = false
        var count = 0
        var tracked = 0
        var lastDay = CivilDate(year: 1970, month: 1, day: 1)
        var zones: [TimeZone] = []

        func note() {
            result.longest = max(result.longest, count)
            result.longestTracked = max(result.longestTracked, tracked)
        }
        func addZone(_ z: TimeZone) {
            if !zones.contains(where: { $0.identifier == z.identifier }) { zones.append(z) }
        }

        if let seed {
            started = true
            count = seed.days
            tracked = 0
            lastDay = seed.lastDay
            zones = [seed.timeZone]
            note()
        }

        for e in resolved {
            if !started {
                if e.kind == .session {
                    started = true
                    count = 1
                    tracked = 1
                    lastDay = e.day
                    zones = [e.timeZone]
                }
            } else if !(lastDay < e.day) {
                // Same date, or an earlier one after flying west over the date line.
                addZone(e.timeZone)
            } else if e.at < deadline(after: lastDay, zones: zones, from: e.timeZone) {
                if e.kind == .session {
                    count += 1
                    tracked += 1
                }
                lastDay = e.day
                zones = [e.timeZone]
            } else if e.kind == .session {
                count = 1
                tracked = 1
                lastDay = e.day
                zones = [e.timeZone]
            } else {
                started = false
                count = 0
                tracked = 0
                zones = []
            }
            note()
        }

        guard started else { return result }
        let due = deadline(after: lastDay, zones: zones, from: nowTimeZone)
        result.lastDay = lastDay
        result.deadline = due
        if now < due {
            result.current = count
            result.currentTracked = tracked
        }
        return result
    }

    /// Midnight at the end of the day after `day`, in whichever zone gives the most time.
    public static func deadline(after day: CivilDate, zones: [TimeZone], from viewer: TimeZone) -> Date {
        var best = day.startOfDay(offset: 2, in: viewer)
        for z in zones {
            let t = day.startOfDay(offset: 2, in: z)
            if t > best { best = t }
        }
        return best
    }
}

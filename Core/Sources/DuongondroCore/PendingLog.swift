import Foundation

/// The undo window after +mala, +custom or "done today". The session is written
/// to the phone's database at once, marked pending, so every number includes it
/// and a crash cannot lose it; Undo deletes that row outright. A pending row is
/// never synced: it becomes final, and syncs, when the window closes. Sessions
/// carry no source (button, watch or custom amount).
public struct PendingLog: Equatable, Sendable {
    public static let window: TimeInterval = 5

    public let practiceID: String
    public private(set) var amount: Int
    public let startedAt: Date
    public private(set) var deadline: Date
    /// The pending row's id, kept when the window is extended.
    public let sessionID: UUID

    public init(practiceID: String, amount: Int, at now: Date) {
        self.init(practiceID: practiceID, amount: amount, startedAt: now,
                  deadline: now.addingTimeInterval(Self.window), sessionID: UUID.v7(at: now))
    }

    /// A window read back from its pending row (a launch inside the window).
    public init(practiceID: String, amount: Int, startedAt: Date, deadline: Date, sessionID: UUID) {
        self.practiceID = practiceID
        self.amount = amount
        self.startedAt = startedAt
        self.deadline = deadline
        self.sessionID = sessionID
    }

    /// Another +mala on the same practice inside the window extends it.
    public mutating func add(_ more: Int, at now: Date) {
        amount += more
        deadline = now.addingTimeInterval(Self.window)
    }

    public func isDue(at now: Date) -> Bool { now >= deadline }

    /// The session this window writes; its start is estimated from when the window opened.
    public func session(timeZone: TimeZone, timedSessionLengths: [TimeInterval]) -> Session {
        Session(id: sessionID, practiceID: practiceID, amount: amount,
                startedAt: SessionStart.estimate(loggedAt: startedAt, tappedStart: nil, timedSessionLengths: timedSessionLengths),
                startExact: false, timeZoneID: timeZone.identifier, loggedAt: startedAt)
    }

    /// Whether a pending row found on launch is final by now: its window has
    /// passed, or it ends further ahead than a window can (the clock moved back),
    /// so a row can never stay pending for good.
    public static func isOver(deadline: Date, at now: Date) -> Bool {
        now >= deadline || deadline > now.addingTimeInterval(window)
    }
}

/// Estimated start of a session logged at the end: exact when the user
/// tapped Start, otherwise the logging time minus the typical session length.
public enum SessionStart {
    public static let defaultLength: TimeInterval = 3600

    public static func estimate(loggedAt: Date, tappedStart: Date?, timedSessionLengths: [TimeInterval]) -> Date {
        if let tappedStart { return tappedStart }
        return loggedAt.addingTimeInterval(-(median(timedSessionLengths) ?? defaultLength))
    }

    static func median(_ xs: [TimeInterval]) -> TimeInterval? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}

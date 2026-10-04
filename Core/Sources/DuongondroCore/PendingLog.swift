import Foundation

/// The undo window after +mala: a session is only written when the window
/// closes, so an undone tap leaves no record anywhere. Sessions carry no
/// source (button, watch or custom amount).
public struct PendingLog: Equatable, Sendable {
    public static let window: TimeInterval = 5

    public let practiceID: String
    public private(set) var amount: Int
    public let startedAt: Date
    public private(set) var deadline: Date

    public init(practiceID: String, amount: Int, at now: Date) {
        self.practiceID = practiceID
        self.amount = amount
        self.startedAt = now
        self.deadline = now.addingTimeInterval(Self.window)
    }

    /// Another +mala on the same practice inside the window extends it.
    public mutating func add(_ more: Int, at now: Date) {
        amount += more
        deadline = now.addingTimeInterval(Self.window)
    }

    public func isDue(at now: Date) -> Bool { now >= deadline }
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

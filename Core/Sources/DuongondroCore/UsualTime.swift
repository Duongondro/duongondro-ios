import Foundation

/// When a person usually finishes a practice, learned from their own log (design:
/// Social › Nudges, "Shouldn't you be meditating?"): the median wall-clock time
/// at which sessions were logged over the last two weeks. Nothing leaves the phone.
public enum UsualTime {
    /// Sessions needed before there is a habit to speak of.
    public static let minimumSessions = 3

    /// Minutes after local midnight, or nil without enough sessions. Times are read
    /// in each session's own zone, so a trip does not move the habit. Around
    /// midnight the times are taken as a circle: 23:50 and 00:10 average to midnight,
    /// not noon.
    public static func minutes(of sessions: [Session], now: Date) -> Int? {
        let cutoff = now.addingTimeInterval(-14 * 86400)
        let times = sessions.filter { $0.loggedAt > cutoff && $0.loggedAt <= now }.map { s -> Int in
            let tz = TimeZone(identifier: s.timeZoneID) ?? .current
            let c = Calendar.gregorian(in: tz).dateComponents([.hour, .minute], from: s.loggedAt)
            return (c.hour ?? 0) * 60 + (c.minute ?? 0)
        }
        guard times.count >= minimumSessions else { return nil }
        // Rotate the circle so the widest gap between times sits at the cut, then
        // take an ordinary median and rotate back.
        let sorted = times.sorted()
        var cut = sorted[0], widest = sorted[0] + 1440 - sorted[sorted.count - 1]
        for (a, b) in zip(sorted, sorted.dropFirst()) where b - a > widest {
            widest = b - a
            cut = b
        }
        let rotated = sorted.map { ($0 - cut + 1440) % 1440 }.sorted()
        let mid = rotated.count / 2
        let median = rotated.count % 2 == 1 ? rotated[mid] : (rotated[mid - 1] + rotated[mid]) / 2
        return (median + cut) % 1440
    }
}

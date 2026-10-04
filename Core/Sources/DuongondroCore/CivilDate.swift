import Foundation

/// A Gregorian calendar date with no time or zone, e.g. 2026-10-05.
///
/// Day keys are always built from Gregorian components in an explicit time
/// zone: never `DateFormatter` with `YYYY` (the week-based year stamps
/// 29 December 2025 as 2026) and never the device's own calendar.
public struct CivilDate: Hashable, Comparable, Codable, CustomStringConvertible, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses `YYYY-MM-DD`.
    public init?(_ string: String) {
        let parts = string.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d)
        else { return nil }
        self.init(year: y, month: m, day: d)
    }

    /// The date of `instant` in `timeZone`.
    public static func of(_ instant: Date, in timeZone: TimeZone) -> CivilDate {
        let c = Calendar.gregorian(in: timeZone).dateComponents([.year, .month, .day], from: instant)
        return CivilDate(year: c.year!, month: c.month!, day: c.day!)
    }

    /// The first instant of this date plus `offset` days in `timeZone`. Where
    /// local midnight does not exist (a DST jump), the first instant that does.
    public func startOfDay(offset: Int = 0, in timeZone: TimeZone) -> Date {
        let cal = Calendar.gregorian(in: timeZone)
        // Noon is never skipped by DST, so it is a safe anchor for day arithmetic.
        let noon = cal.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
        let shifted = cal.date(byAdding: .day, value: offset, to: noon)!
        return cal.startOfDay(for: shifted)
    }

    public func adding(days: Int) -> CivilDate {
        let utc = TimeZone(identifier: "UTC")!
        return CivilDate.of(startOfDay(offset: days, in: utc), in: utc)
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func < (lhs: CivilDate, rhs: CivilDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

extension Calendar {
    /// A Gregorian calendar fixed to `timeZone`, independent of the device's settings.
    public static func gregorian(in timeZone: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        cal.locale = Locale(identifier: "en_US_POSIX")
        return cal
    }
}

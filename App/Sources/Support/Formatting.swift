import Foundation
import DuongondroCore

extension CivilDate {
    /// The weekday's name in the user's locale, e.g. "Sunday" or "niedziela".
    func weekdayName(in timeZone: TimeZone = .current) -> String {
        var style = Date.FormatStyle(timeZone: timeZone).weekday(.wide)
        style.locale = .current
        // Noon is never skipped by a DST change.
        return startOfDay(in: timeZone).addingTimeInterval(12 * 3600).formatted(style)
    }
}

extension Date {
    /// "23:30" or "11:30 PM", as the locale prefers.
    var shortTime: String { formatted(date: .omitted, time: .shortened) }
}

extension Int {
    /// Locale grouping: 43,308 · 43.308 · 43 308.
    var grouped: String { formatted(.number) }
}

import Foundation
import DuongondroCore

extension CivilDate {
    /// The weekday's name in the user's locale, e.g. "Sunday" or "niedziela".
    func weekdayName(in timeZone: TimeZone = .current) -> String {
        var style = Date.FormatStyle(timeZone: timeZone).weekday(.wide)
        style.locale = .appLanguage
        // Noon is never skipped by a DST change.
        return startOfDay(in: timeZone).addingTimeInterval(12 * 3600).formatted(style)
    }
}

extension Date {
    /// "23:30" or "11:30 PM", as the locale prefers.
    var shortTime: String { formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: .appLanguage)) }
}

extension Int {
    /// Locale grouping: 43,308 · 43.308 · 43 308.
    /// Grouped for the interface language: 43,308 in English, 43 308 in Polish.
    var grouped: String { formatted(.number.locale(.appLanguage)) }

    /// With its sign, grouped: "+1,200", "−300" (a correction's change).
    var signed: String { signed(in: .appLanguage) }

    /// With its sign, grouped in `locale`, and a true minus sign (U+2212), never
    /// the hyphen most locales' formats give.
    func signed(in locale: Locale) -> String {
        let digits = magnitude.formatted(.number.locale(locale))
        return self > 0 ? "+" + digits : self < 0 ? "\u{2212}" + digits : digits
    }
}

import Foundation
import UserNotifications
import DuongondroCore
import DuongondroStore

/// The private streak-at-risk reminder: a local notification at the user's
/// evening time on days nothing has been logged yet. Scheduled on the phone, so
/// the server learns nothing (design: Social › Nudges).
@MainActor
enum Reminders {
    static let prefix = "streak-at-risk-"

    static func requestAndSchedule(_ model: AppModel) async {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        if granted { reschedule(model) }
    }

    /// Replaces the pending reminders for today and tomorrow from the current state.
    static func reschedule(_ model: AppModel, now: Date = Date()) {
        scheduleUsualTime(model, now: now)
        let center = UNUserNotificationCenter.current()
        let tz = TimeZone.current
        let today = CivilDate.of(now, in: tz)
        let days = [today, today.adding(days: 1)]
        center.removePendingNotificationRequests(withIdentifiers: days.map { prefix + $0.description })
        guard let minutes = model.preferences.reminderMinutes, !model.snapshot.activePractices.isEmpty else { return }
        let practisedToday = model.snapshot.sessions.contains { $0.day == today }

        for day in days {
            if day == today && practisedToday { continue }
            guard let fire = fireDate(on: day, minutes: minutes, in: tz), fire > now else { continue }
            // The streak as it will stand when the reminder fires: tomorrow's is
            // still alive then only if today gets logged.
            let streak = model.headline(now: fire).current
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Nothing logged today", bundle: .appLanguage, locale: .appLanguage)
            content.body = streak > 0
                ? String(localized: "Your streak of \(streak) days ends at midnight.", bundle: .appLanguage, locale: .appLanguage)
                : String(localized: "A short session still counts.", bundle: .appLanguage, locale: .appLanguage)
            content.sound = .default
            let comps = Calendar.gregorian(in: tz).dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            center.add(UNNotificationRequest(identifier: prefix + day.description, content: content, trigger: trigger))
        }
    }

    static let usualPrefix = "usual-time-"

    /// "Shouldn't you be meditating?": an hour before the time each practice is
    /// usually logged (the median of two weeks), today and tomorrow, unless that
    /// practice is already done that day. Learned and scheduled on the phone only.
    static func scheduleUsualTime(_ model: AppModel, now: Date) {
        let center = UNUserNotificationCenter.current()
        let enabled = model.preferences.usualTimeNudge
        let discreet = model.preferences.discreetNotifications
        let snapshot = model.snapshot
        Task { @MainActor in
            let stale = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(usualPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: stale)
            guard enabled else { return }
            let tz = TimeZone.current
            let today = CivilDate.of(now, in: tz)
            for p in snapshot.activePractices {
                let sessions = snapshot.sessions(of: p.id)
                guard let usual = UsualTime.minutes(of: sessions, now: now) else { continue }
                let minutes = (usual - 60 + 1440) % 1440
                for day in [today, today.adding(days: 1)] {
                    if sessions.contains(where: { $0.day == day }) { continue }
                    guard let fire = fireDate(on: day, minutes: minutes, in: tz), fire > now else { continue }
                    let content = UNMutableNotificationContent()
                    content.title = String(localized: "Shouldn't you be meditating?", bundle: .appLanguage, locale: .appLanguage)
                    content.body = discreet
                        ? String(localized: "You usually sit down around now.", bundle: .appLanguage, locale: .appLanguage)
                        : String(localized: "You usually sit down for \(p.practice.shownName) around now.", bundle: .appLanguage, locale: .appLanguage)
                    content.sound = .default
                    let comps = Calendar.gregorian(in: tz).dateComponents([.year, .month, .day, .hour, .minute], from: fire)
                    try? await center.add(UNNotificationRequest(identifier: usualPrefix + p.id + "-" + day.description, content: content,
                                                     trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
                }
            }
        }
    }

    /// The wall-clock time `minutes` after midnight on `day`, built from
    /// components so a DST change that day does not shift it by an hour.
    static func fireDate(on day: CivilDate, minutes: Int, in tz: TimeZone) -> Date? {
        Calendar.gregorian(in: tz).date(from: DateComponents(year: day.year, month: day.month, day: day.day,
                                                             hour: minutes / 60, minute: minutes % 60))
    }
}

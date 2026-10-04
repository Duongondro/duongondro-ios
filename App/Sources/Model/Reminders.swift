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
        let center = UNUserNotificationCenter.current()
        let tz = TimeZone.current
        let today = CivilDate.of(now, in: tz)
        let days = [today, today.adding(days: 1)]
        center.removePendingNotificationRequests(withIdentifiers: days.map { prefix + $0.description })
        guard let minutes = model.preferences.reminderMinutes, !model.snapshot.activePractices.isEmpty else { return }
        let practisedToday = model.snapshot.sessions.contains { $0.day == today }
        let streak = model.headline(now: now).current

        for day in days {
            if day == today && practisedToday { continue }
            let fire = day.startOfDay(in: tz).addingTimeInterval(TimeInterval(minutes * 60))
            guard fire > now else { continue }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Nothing logged today")
            content.body = day == today && streak > 0
                ? String(localized: "Your \(streak)-day streak ends at midnight.")
                : String(localized: "A short session still counts.")
            content.sound = .default
            let comps = Calendar.gregorian(in: tz).dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            center.add(UNNotificationRequest(identifier: prefix + day.description, content: content, trigger: trigger))
        }
    }
}

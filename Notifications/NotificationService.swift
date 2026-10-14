import DuongondroCore
import Foundation
import UserNotifications

/// Renders the server's pushes in the app's language before they are shown (design:
/// Localisation › Localised pushes; Social › Nudges): the practice id becomes its name
/// as the person's practice books have it, the day count is formatted for the locale,
/// and with Discreet notifications on nothing names a practice. The server marks every
/// push mutable-content for this. If it cannot render a push that may name a
/// practice, or runs out of time, it shows the discreet text rather than the system's
/// rendering; other pushes keep the system's rendering of the loc-key.
final class NotificationService: UNNotificationServiceExtension {
    private var handler: ((UNNotificationContent) -> Void)?
    private var fallback: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler handler: @escaping (UNNotificationContent) -> Void) {
        self.handler = handler
        let fallback = Self.failSafe(request.content)
        self.fallback = fallback
        handler(Self.render(request.content) ?? fallback)
    }

    override func serviceExtensionTimeWillExpire() {
        if let handler, let fallback { handler(fallback) }
    }

    /// The discreet text for FRIEND_DONE and STREAK_AT_RISK, in the app's language if
    /// its strings can be read, in English otherwise; anything else as it came.
    static func failSafe(_ content: UNNotificationContent) -> UNNotificationContent {
        guard let alert = (content.userInfo["aps"] as? [String: Any])?["alert"] as? [String: Any],
              let safe = (alert["loc-key"] as? String).flatMap(PushKey.init(rawValue:))?.failSafe,
              let copy = content.mutableCopy() as? UNMutableNotificationContent
        else { return content }
        let missing = "\u{1}"
        let localized = strings(for: localization(UserDefaults(suiteName: PushShared.appGroup)))?
            .localizedString(forKey: safe.rawValue, value: missing, table: nil)
        copy.body = localized.flatMap { $0 == missing ? nil : $0 }
            ?? (safe == .friendDoneDiscreet ? "A friend practised" : "One of your streaks ends in under two hours")
        return copy
    }

    /// The language the app shows; the phone's when it follows the phone.
    private static func localization(_ shared: UserDefaults?) -> String {
        shared?.string(forKey: PushShared.localization)
            ?? Bundle.preferredLocalizations(from: app.localizations).first ?? "en"
    }

    private static func strings(for localization: String) -> Bundle? {
        app.path(forResource: localization, ofType: "lproj").flatMap(Bundle.init(path:))
    }

    /// The app this extension is embedded in: its bundle holds the strings.
    private static let app: Bundle = Bundle(url: Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()) ?? .main

    static func render(_ content: UNNotificationContent) -> UNNotificationContent? {
        guard let aps = content.userInfo["aps"] as? [String: Any],
              let alert = aps["alert"] as? [String: Any],
              let locKey = alert["loc-key"] as? String
        else { return nil }
        let args = alert["loc-args"] as? [String] ?? []
        let shared = UserDefaults(suiteName: PushShared.appGroup)
        let localization = Self.localization(shared)
        guard let strings = Self.strings(for: localization) else { return nil }
        let locale = Self.locale(for: localization)
        let own = shared?.dictionary(forKey: PushShared.practiceNames) as? [String: String] ?? [:]
        let numbers = NumberFormatter()
        numbers.numberStyle = .decimal
        numbers.locale = locale

        guard let text = PushText.render(
            // Discreet unless the app said otherwise: a missing setting never shows more.
            locKey: locKey, args: args, discreet: shared?.object(forKey: PushShared.discreet) as? Bool ?? true,
            practiceName: { id in
                if let p = Catalogue.builtIn.first(where: { $0.id == id }) {
                    return strings.localizedString(forKey: p.name, value: p.name, table: "Practices")
                }
                return own[id]
            },
            number: { numbers.string(from: NSNumber(value: $0)) ?? String($0) })
        else { return nil }
        let missing = "\u{1}"
        let format = strings.localizedString(forKey: text.key.rawValue, value: missing, table: nil)
        guard format != missing, let rendered = content.mutableCopy() as? UNMutableNotificationContent else { return nil }
        rendered.body = text.string(format: format, locale: locale)
        return rendered
    }

    /// The strings' language with the phone's region, as the app formats (AppLanguage).
    private static func locale(for localization: String) -> Locale {
        let system = Locale.autoupdatingCurrent
        if system.language.languageCode?.identifier == localization { return system }
        guard let region = system.region?.identifier else { return Locale(identifier: localization) }
        return Locale(identifier: "\(localization)_\(region)")
    }
}

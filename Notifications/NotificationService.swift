import DuongondroCore
import Foundation
import UserNotifications

/// Renders the server's pushes in the app's language before they are shown (design:
/// Localisation › Localised pushes; Social › Nudges): the practice id becomes its name
/// as the person's practice books have it, the day count is formatted for the locale,
/// and with Discreet notifications on nothing names a practice. The server marks every
/// push mutable-content for this. If it fails or runs out of time, the system's own
/// rendering of the loc-key from the app's Localizable stands.
final class NotificationService: UNNotificationServiceExtension {
    private var handler: ((UNNotificationContent) -> Void)?
    private var original: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler handler: @escaping (UNNotificationContent) -> Void) {
        self.handler = handler
        original = request.content
        handler(Self.render(request.content) ?? request.content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let handler, let original { handler(original) }
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
        let localization = shared?.string(forKey: PushShared.localization)
            ?? Bundle.preferredLocalizations(from: app.localizations).first ?? "en"
        guard let path = app.path(forResource: localization, ofType: "lproj"), let strings = Bundle(path: path) else { return nil }
        let locale = Self.locale(for: localization)
        let own = shared?.dictionary(forKey: PushShared.practiceNames) as? [String: String] ?? [:]
        let numbers = NumberFormatter()
        numbers.numberStyle = .decimal
        numbers.locale = locale

        guard let text = PushText.render(
            locKey: locKey, args: args, discreet: shared?.bool(forKey: PushShared.discreet) ?? false,
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

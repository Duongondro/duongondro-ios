import Combine
import DuongondroCore
import DuongondroStore
import Foundation
import UIKit
import UserNotifications

/// Receives the APNs token and notification taps for SwiftUI.
final class AppDelegate: NSObject, UIApplicationDelegate {
    let push = PushModel()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Before launch finishes, so a tap that launched the app is delivered.
        UNUserNotificationCenter.current().delegate = push
        KeyboardDismissal.install()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in await push.received(token: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // No token (no network, or no push entitlement in this signing): tried again
        // at the next launch or return to the foreground.
    }
}

/// Friends' pushes (design: Social › Nudges): the permission, asked with a reason
/// (Friends, "Tell me when they practise", a poke) and never at launch; the device
/// token, registered only for an account with keys and sent to the server whenever it
/// or the account changes; and where a tap leads. Local mode registers nothing and
/// makes no network call.
@MainActor
final class PushModel: NSObject, ObservableObject {
    /// Nil until the system has answered: the Friends card waits for a known
    /// .notDetermined rather than flashing for someone who already decided.
    @Published private(set) var authorization: UNAuthorizationStatus?
    /// Friends › "Not now" on the permission card.
    @Published private(set) var askDismissed = UserDefaults.standard.bool(forKey: PushModel.dismissedKey)
    /// A friend's page to open, from a tapped push.
    @Published var openFriend: UUID?

    static let dismissedKey = "push.askDismissed"

    private weak var model: AppModel?
    private weak var account: AccountModel?
    private var statusWatch: AnyCancellable?
    /// A tap that arrived before the models were attached (it launched the app).
    private var pendingRoute: PushRoute?
    private var token: String?

    func attach(model: AppModel, account: AccountModel) {
        guard self.account == nil else { return }
        self.model = model
        self.account = account
        statusWatch = account.$status.removeDuplicates().sink { [weak self] status in
            // Sent before the change is stored: the new status travels along.
            Task { @MainActor in
                guard let self else { return }
                if let model = self.model { self.share(model.snapshot, ready: status == .ready) }
                if status == .ready { await self.refresh() }
            }
        }
        share(model.snapshot)
        Task { await refresh() }
        if let pendingRoute { open(pendingRoute) }
        pendingRoute = nil
    }

    /// On launch, return to the foreground and an account becoming ready: the
    /// permission may have changed in Settings, and Apple asks for registration at
    /// every launch (the token can change).
    func refresh() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        guard account?.status == .ready, let authorization, [.authorized, .provisional, .ephemeral].contains(authorization) else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// The system prompt, once, at a moment with a reason; then registration.
    func ask() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if authorization == .notDetermined {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
        await refresh()
    }

    func dismissAsk() {
        askDismissed = true
        UserDefaults.standard.set(true, forKey: Self.dismissedKey)
    }

    func received(token data: Data) async {
        token = PushToken.hex(data)
        await upload()
    }

    /// Sends the token when the server may not have it: a new token, another device
    /// (after a sign-in or restore), another APNs environment, or a day since it was
    /// last sent, in case the server dropped it.
    private func upload(now: Date = Date()) async {
        guard let token, let account, let device = account.pushDevice else { return }
        let platform = PushPlatform.of(profile: Self.profile, simulator: Self.simulator)
        let sent = "\(device.uuidString)|\(platform)|\(token)"
        let defaults = UserDefaults.standard
        let sentAt = defaults.object(forKey: AccountModel.Keys.pushSentAt) as? Date ?? .distantPast
        guard defaults.string(forKey: AccountModel.Keys.pushSent) != sent || now.timeIntervalSince(sentAt) > 86400 else { return }
        do {
            try await account.putPushToken(token, platform: platform)
            defaults.set(sent, forKey: AccountModel.Keys.pushSent)
            defaults.set(now, forKey: AccountModel.Keys.pushSentAt)
        } catch {
            // Offline: sent at the next launch or return to the foreground.
        }
    }

    private static let profile: Data? = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
        .flatMap { try? Data(contentsOf: $0) }

    private static var simulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    // MARK: Shared with the notification extension

    /// What the extension needs to render a push, in the app group: Discreet
    /// notifications, the app's language and the names of the person's own practices.
    /// Only for an account with keys, the only kind that gets pushes; otherwise the
    /// group holds nothing.
    func share(_ snapshot: Snapshot, ready: Bool? = nil) {
        guard let shared = UserDefaults(suiteName: PushShared.appGroup) else { return }
        guard ready ?? (account?.status == .ready) else {
            return shared.removePersistentDomain(forName: PushShared.appGroup)
        }
        // Nothing for System: the extension then follows the phone's language as it
        // is when the push arrives, not as it was when the app last ran.
        let language = AppLanguage.stored()
        let localization = language == .system ? nil : language.rawValue
        let names = Dictionary(snapshot.practices.filter(\.practice.isCustom).map { ($0.id, $0.practice.name) },
                               uniquingKeysWith: { a, _ in a })
        // Always written: the extension treats a missing value as discreet.
        if shared.object(forKey: PushShared.discreet) as? Bool != snapshot.preferences.discreetNotifications {
            shared.set(snapshot.preferences.discreetNotifications, forKey: PushShared.discreet)
        }
        if shared.string(forKey: PushShared.localization) != localization {
            shared.set(localization, forKey: PushShared.localization)
        }
        if shared.dictionary(forKey: PushShared.practiceNames) as? [String: String] != names {
            shared.set(names, forKey: PushShared.practiceNames)
        }
    }

    // MARK: Taps

    private func open(_ route: PushRoute) {
        guard let model, model.preferences.onboarded else { return pendingRoute = route }
        switch route {
        case .friend(let id):
            model.tab = .friends
            // Friends' pages exist only with an account (a push after signing out).
            if account?.status == .ready { openFriend = id }
        case .today:
            model.tab = .today
        }
    }
}

extension PushModel: UNUserNotificationCenterDelegate {
    /// Friends' pushes show while the app is open too, and refresh the list; the
    /// local reminders keep the system's default (not shown in the foreground).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void) {
        guard notification.request.trigger is UNPushNotificationTrigger else { return completion([]) }
        completion([.banner, .list, .sound])
        Task { @MainActor in await self.account?.refreshFriends() }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completion: @escaping () -> Void) {
        let route = PushRoute(userInfo: response.notification.request.content.userInfo)
        Task { @MainActor in
            if let route { self.open(route) }
            completion()
        }
    }
}

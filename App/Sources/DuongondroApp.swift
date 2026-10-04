import SwiftUI
import DuongondroCore
import DuongondroStore
import DuongondroSync

@main
struct DuongondroApp: App {
    @StateObject private var model: AppModel
    @StateObject private var account: AccountModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let model = AppModel.live()
        _model = StateObject(wrappedValue: model)
        _account = StateObject(wrappedValue: AccountModel(database: model.database))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(account)
                .tint(Theme.accent)
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            // A session in its undo window is written before the app can be
            // killed; .inactive (Control Center, a call banner) keeps the window.
            case .background: model.commitPending()
            case .active:
                model.tick()
                Task { await account.syncNow() }
            default: break
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: AccountModel

    var body: some View {
        Group {
            if model.preferences.onboarded {
                TabView {
                    // The mockup's tabs: Today, Friends, You.
                    NavigationStack { TodayView() }
                        .tabItem { Label("Today", systemImage: "clock") }
                    NavigationStack { FriendsView() }
                        .tabItem { Label("Friends", systemImage: "person.2") }
                    NavigationStack { SettingsView() }
                        .tabItem { Label("You", systemImage: "person") }
                }
            } else {
                OnboardingView()
            }
        }
        .sheet(item: $model.afterMidnight) { prompt in
            AfterMidnightSheet(prompt: prompt)
        }
        .onChange(of: model.snapshot) { _ in
            Reminders.reschedule(model)
            account.scheduleSync()
        }
        // Invite and add-friend links (Universal Links on duongondro.app).
        .onOpenURL { url in
            if let link = InviteLink(url.absoluteString) { account.pendingInvite = link }
        }
        .sheet(isPresented: Binding(get: { account.pendingInvite != nil && account.recoveryCode == nil },
                                    set: { if !$0 { account.pendingInvite = nil } })) {
            if let link = account.pendingInvite { AcceptInviteView(link: link).environmentObject(account) }
        }
        .fullScreenCover(isPresented: Binding(get: { account.recoveryCode != nil }, set: { _ in })) {
            if let code = account.recoveryCode { RecoveryCodeView(code: code).environmentObject(account) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            model.tick()
        }
        .safeAreaInset(edge: .top) {
            if let error = model.storageError {
                StorageBanner(message: error, persistent: model.persistent) { model.dismissStorageError() }
            }
        }
    }
}

/// Says plainly when data is not being saved, instead of losing it quietly.
private struct StorageBanner: View {
    let message: String
    let persistent: Bool
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.destructive)
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(persistent ? "Something could not be saved." : "The database could not be opened. Nothing you log now would be kept, so logging is off until the app restarts.")
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: message).font(.footnote).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
            if persistent {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel(Text("Dismiss"))
            }
        }
        .cardStyle()
        .padding(.horizontal, Theme.Space.l)
    }
}

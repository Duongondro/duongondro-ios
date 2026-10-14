import SwiftUI
import DuongondroCore
import DuongondroStore
import DuongondroSync

@main
struct DuongondroApp: App {
    @StateObject private var model: AppModel
    @StateObject private var account: AccountModel
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    /// Settings › Language. System (the default) follows the phone.
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system

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
                .environmentObject(delegate.push)
                .onAppear { delegate.push.attach(model: model, account: account) }
                // The interface language for every view below: string lookups and
                // formatting. Always set (System = the phone's own locale).
                .environment(\.locale, language.locale())
                .tint(Theme.accent)
                .onChange(of: language) { _ in delegate.push.share(model.snapshot) }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            // Leaving closes the undo window: its pending session becomes final
            // and syncs; .inactive (Control Center, a call banner) keeps the window.
            case .background: model.finalisePending()
            case .active:
                model.tick()
                Task {
                    await account.syncNow()
                    await account.refreshFriends()
                }
                Task { await delegate.push.refresh() }
            default: break
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: AccountModel
    @EnvironmentObject private var push: PushModel

    var body: some View {
        Group {
            if model.preferences.onboarded {
                TabView(selection: $model.tab) {
                    // The mockup's tabs: Today, Friends, You.
                    NavigationStack { TodayView() }
                        .tabItem { Label("Today", systemImage: "clock") }
                        .tag(AppModel.Tab.today)
                    NavigationStack { FriendsView() }
                        .tabItem { Label("Friends", systemImage: "person.2") }
                        .tag(AppModel.Tab.friends)
                    NavigationStack { SettingsView() }
                        .tabItem { Label("You", systemImage: "person") }
                        .tag(AppModel.Tab.you)
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
            push.share(model.snapshot)
        }
        // Invite, add-friend and magic links (Universal Links on duongondro.app).
        .onOpenURL { open($0) }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL { open(url) }
        }
        // Offered for accepting only to an account with keys, outside onboarding,
        // not over the recovery code, and not while a sign-up from this very link
        // finishes (that one redeems it itself). Before that, the invitation step
        // picks it up.
        .sheet(isPresented: Binding(get: { account.pendingInvite != nil && account.recoveryCode == nil
                                               && account.status == .ready && !account.signingUpWithInvite
                                               && model.preferences.onboarded && account.accountFlow == nil },
                                    set: { if !$0 { account.pendingInvite = nil } })) {
            if let link = account.pendingInvite {
                // A new identity per link, so a second link never redeems the first's check.
                AcceptInviteView(link: link).environmentObject(account).id(link.string)
            }
        }
        // The account steps from Settings or Friends: a new account from the
        // invitation on, or signing in (again).
        .fullScreenCover(item: $account.accountFlow) { flow in
            OnboardingView(start: flow == .signIn ? .signIn : .invite) { account.accountFlow = nil }
                .environmentObject(model)
                .environmentObject(account)
                .environment(\.locale, AppLanguage.stored().locale())
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

extension RootView {
    /// An invite link is kept for accepting or for a sign-up; a magic link's token
    /// only while this phone expects one (it asked in the last 15 minutes), and
    /// only Check your email redeems it. Anything else is ignored.
    func open(_ url: URL) {
        switch AppLink(url) {
        case .invite(let link): account.pendingInvite = link
        case .magic(let token): account.opened(magicToken: token)
        case nil: break
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
                (persistent ? Text("Something could not be saved.")
                 : Text(verbatim: Gendered.mine("The database could not be opened. Nothing you log now would be kept, so logging is off until the app restarts.")))
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

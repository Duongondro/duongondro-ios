import SwiftUI
import DuongondroCore
import DuongondroStore

@main
struct DuongondroApp: App {
    @StateObject private var model = AppModel.live()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .tint(Theme.accent)
        }
        .onChange(of: scenePhase) { phase in
            // A session in its undo window is written before the app can be killed.
            if phase != .active { model.commitPending() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.preferences.onboarded {
                TabView {
                    NavigationStack { TodayView() }
                        .tabItem { Label("Today", systemImage: "flame") }
                    NavigationStack { SettingsView() }
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                }
            } else {
                OnboardingView()
            }
        }
        .sheet(item: $model.afterMidnight) { prompt in
            AfterMidnightSheet(prompt: prompt)
        }
        .onChange(of: model.snapshot) { _ in Reminders.reschedule(model) }
    }
}

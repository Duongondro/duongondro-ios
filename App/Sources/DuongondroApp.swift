import SwiftUI
import DuongondroCore

@main
struct DuongondroApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .tint(Theme.accent)
        }
    }
}

/// Placeholder state until GRDB storage lands (duongondro-ios #5).
@MainActor
final class AppModel: ObservableObject {
    @Published var practices: [Practice] = Catalogue.builtIn.filter { ["dorje-sempa", "mandala", "chenrezig"].contains($0.id) }
    @Published var malaSize = 108
    @Published var pending: PendingLog?
}

struct RootView: View {
    var body: some View {
        TabView {
            NavigationStack { TodayView() }
                .tabItem { Label("Today", systemImage: "clock") }
            NavigationStack { SettingsView() }
                .tabItem { Label("You", systemImage: "person") }
        }
    }
}

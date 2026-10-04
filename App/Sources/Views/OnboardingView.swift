import SwiftUI
import DuongondroCore
import DuongondroStore

/// Stand-in until onboarding lands (#6): starts local mode with Dorje Sempa.
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button("Just me, on this phone") {
            var prefs = Preferences()
            prefs.onboarded = true
            let ds = TrackedPractice(practice: Catalogue.builtIn.first { $0.id == "dorje-sempa" }!)
            model.perform { try $0.completeOnboarding(practices: [ds], seeds: [], preferences: prefs) }
        }
        .buttonStyle(.borderedProminent)
    }
}

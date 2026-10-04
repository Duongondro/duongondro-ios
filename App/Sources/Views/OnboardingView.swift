import SwiftUI
import DuongondroCore
import DuongondroStore

/// The practice comes before the account: one question per screen, each with
/// a back button that returns one step and keeps the answers given so far.
/// Yes/no questions advance on tap.
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var flow = OnboardingFlow()

    var body: some View {
        NavigationStack {
            Group {
                switch flow.step {
                case .welcome: WelcomeStep()
                case .finishedNgondro: FinishedNgondroStep()
                case .finishedShortRefuge: FinishedShortRefugeStep()
                case .practices: PracticesStep()
                case .counts(let index): CountsStep(index: index).id(index)
                case .mala: MalaStep()
                case .reminder: ReminderStep()
                case .door: DoorStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, Theme.Space.xl)
            .background(Theme.ground.ignoresSafeArea())
            .toolbar {
                if flow.canGoBack {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button { flow.back() } label: { Label("Back", systemImage: "chevron.backward") }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .animation(.default, value: flow.step)
        }
        .environmentObject(flow)
    }
}

// MARK: - State

enum OnboardingDoor: Equatable { case invite, justMe, existingAccount }

enum OnboardingStep: Hashable {
    case welcome, finishedNgondro, finishedShortRefuge, practices, counts(Int), mala, reminder, door
}

/// What the user said about one chosen practice.
struct OnboardingPractice: Identifiable, Equatable {
    var practice: Practice
    var streakOnly = false
    var countSoFar = 0
    var round = 1
    var showsRound = false
    var streak = 0
    var lastWasToday = true
    var longest: Int?

    var id: String { practice.id }
}

@MainActor
final class OnboardingFlow: ObservableObject {
    @Published private(set) var step: OnboardingStep = .welcome
    private var history: [OnboardingStep] = []

    @Published var door: OnboardingDoor = .justMe
    @Published var finishedNgondro = false
    @Published var finishedShortRefuge = false
    /// Chosen practices, in the order picked. Kept when the user goes back.
    @Published var chosen: [OnboardingPractice] = []
    @Published var malaSize = 108
    @Published var reminder: Date? = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: Date())

    var canGoBack: Bool { !history.isEmpty }

    func go(_ next: OnboardingStep) {
        history.append(step)
        step = next
    }

    func back() {
        guard let previous = history.popLast() else { return }
        step = previous
    }

    var available: [Practice] {
        Catalogue.available(finishedNgondro: finishedNgondro, finishedShortRefuge: finishedShortRefuge)
    }

    func isChosen(_ id: String) -> Bool { chosen.contains { $0.id == id } }

    func toggle(_ p: Practice) {
        if let i = chosen.firstIndex(where: { $0.id == p.id }) {
            chosen.remove(at: i)
        } else {
            chosen.append(OnboardingPractice(practice: p, streakOnly: p.id == "8th-karmapa"))
        }
    }

    /// After the path questions, drop choices the answers no longer allow.
    func pruneToAvailable() {
        let allowed = Set(available.map(\.id))
        chosen.removeAll { !$0.practice.isCustom && !allowed.contains($0.id) }
    }

    func finish(into model: AppModel, now: Date = Date()) {
        let tz = TimeZone.current
        let today = CivilDate.of(now, in: tz)
        let practices = chosen.enumerated().map { i, c in
            TrackedPractice(practice: c.practice, streakOnly: c.streakOnly,
                            openingCount: c.streakOnly ? 0 : TrackedPractice.openingCount(round: c.round, inRound: c.countSoFar, target: c.practice.target),
                            sortOrder: i)
        }
        let seeds = chosen.compactMap { c -> StreakSeed? in
            guard c.streak > 0 else { return nil }
            return StreakSeed(practiceID: c.id, days: c.streak, longest: c.longest,
                              lastDay: c.lastWasToday ? today : today.adding(days: -1), timeZoneID: tz.identifier)
        }
        var prefs = Preferences()
        prefs.onboarded = true
        prefs.finishedNgondro = finishedNgondro
        prefs.finishedShortRefuge = finishedShortRefuge || finishedNgondro
        prefs.malaSize = malaSize
        prefs.reminderMinutes = reminder.map { r in
            let c = Calendar.current.dateComponents([.hour, .minute], from: r)
            return (c.hour ?? 20) * 60 + (c.minute ?? 0)
        }
        model.perform { try $0.completeOnboarding(practices: practices, seeds: seeds, preferences: prefs) }
        if prefs.reminderMinutes != nil { Task { await Reminders.requestAndSchedule(model) } }
    }
}

// MARK: - Building blocks

private struct StepHeader: View {
    let title: LocalizedStringKey
    var detail: LocalizedStringKey?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title)
                .font(Typography.largeTitle)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, Theme.Space.l)
        .padding(.bottom, Theme.Space.xl)
    }
}

struct PrimaryButton: View {
    let title: LocalizedStringKey
    var fill: Color = Theme.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.onAccent)
                .frame(maxWidth: .infinity, minHeight: Theme.Size.button)
        }
        .primaryButtonStyle()
        .tint(fill)
    }
}

private struct ChoiceButton: View {
    let title: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: Theme.Size.button)
        }
        .secondaryButtonStyle()
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    @EnvironmentObject private var flow: OnboardingFlow

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Spacer()
            Image(systemName: "bird.fill")
                .font(.system(size: 56))
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text(verbatim: "Duongöndro")
                .font(Typography.largeTitle)
                .foregroundStyle(Theme.accent)
            Text("Count your practice. Keep your streak. Let your friends nag.")
                .font(.title3)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            PrimaryButton(title: "I have an invite", fill: Theme.welcomePrimary) { pick(.invite) }
            ChoiceButton(title: "Just me, on this phone") { pick(.justMe) }
            ChoiceButton(title: "I already have an account") { pick(.existingAccount) }
        }
        .padding(.bottom, Theme.Space.xl)
        .background(Theme.welcomeGround.padding(.horizontal, -Theme.Space.xl).ignoresSafeArea())
    }

    private func pick(_ door: OnboardingDoor) {
        flow.door = door
        flow.go(.finishedNgondro)
    }
}

private struct FinishedNgondroStep: View {
    @EnvironmentObject private var flow: OnboardingFlow

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            StepHeader(title: "Have you finished ngöndro?")
            ChoiceButton(title: "Yes") {
                flow.finishedNgondro = true
                flow.finishedShortRefuge = true
                flow.pruneToAvailable()
                flow.go(.practices)
            }
            ChoiceButton(title: "No") {
                flow.finishedNgondro = false
                flow.go(.finishedShortRefuge)
            }
        }
    }
}

private struct FinishedShortRefugeStep: View {
    @EnvironmentObject private var flow: OnboardingFlow

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            StepHeader(title: "Have you finished short refuge?")
            ChoiceButton(title: "Yes") {
                flow.finishedShortRefuge = true
                flow.pruneToAvailable()
                flow.go(.practices)
            }
            ChoiceButton(title: "No") {
                flow.finishedShortRefuge = false
                flow.pruneToAvailable()
                flow.go(.practices)
            }
        }
    }
}

private struct PracticesStep: View {
    @EnvironmentObject private var flow: OnboardingFlow
    @State private var addingCustom = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(title: "Which practices do you do daily?",
                       detail: "Pick as many as you like. You can add more later in Settings.")
            ScrollView {
                VStack(spacing: Theme.Space.s) {
                    ForEach(flow.available + flow.chosen.map(\.practice).filter(\.isCustom)) { p in
                        PracticeChoiceRow(practice: p)
                    }
                    Button { addingCustom = true } label: {
                        Label("Add your own", systemImage: "plus")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .cardStyle()
                }
            }
            .plainBottomEdge()
            PrimaryButton(title: "Continue") { flow.go(.counts(0)) }
                .disabled(flow.chosen.isEmpty)
                .padding(.vertical, Theme.Space.l)
        }
        .sheet(isPresented: $addingCustom) {
            CustomPracticeSheet { p, streakOnly in
                flow.chosen.append(OnboardingPractice(practice: p, streakOnly: streakOnly))
            }
        }
    }
}

private struct PracticeChoiceRow: View {
    @EnvironmentObject private var flow: OnboardingFlow
    let practice: Practice

    var body: some View {
        let chosen = flow.isChosen(practice.id)
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Button { flow.toggle(practice) } label: {
                HStack(spacing: Theme.Space.m) {
                    Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(chosen ? Theme.accent : Theme.muted)
                    PracticeName(practice: practice)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(chosen ? .isSelected : [])
            if chosen, practice.streakOnlyAllowed, let i = flow.chosen.firstIndex(where: { $0.id == practice.id }) {
                Toggle("Streak only, no count", isOn: $flow.chosen[i].streakOnly)
                    .font(.subheadline)
            }
        }
        .cardStyle()
    }
}

/// A custom practice: a name, a target or none, and the streak-only switch.
struct CustomPracticeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: (Practice, Bool) -> Void
    @State private var name = ""
    @State private var target = ""
    @State private var streakOnly = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Toggle("Streak only, no count", isOn: $streakOnly)
                if !streakOnly {
                    TextField("Target (optional)", text: $target)
                        .keyboardType(.numberPad)
                }
            }
            .navigationTitle("Your own practice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let goal = Int(target.filter { $0.isASCII && $0.isNumber }.prefix(9)).flatMap { $0 > 0 ? $0 : nil }
                        let p = Practice(id: "custom-" + UUID().uuidString.lowercased(), name: trimmed, group: .anyTime,
                                         target: streakOnly ? nil : goal, streakOnlyAllowed: true, isCustom: true)
                        onAdd(p, streakOnly)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// One screen per chosen practice: count so far (first round assumed), the
/// current streak and when it was last practised, optionally the longest.
private struct CountsStep: View {
    @EnvironmentObject private var flow: OnboardingFlow
    let index: Int

    var body: some View {
        if flow.chosen.indices.contains(index) {
            VStack(spacing: 0) {
                Form {
                    Group { sections($flow.chosen[index]) }
                        .themedRows()
                }
                .themedList()
                .plainBottomEdge()
                .padding(.horizontal, -Theme.Space.xl)
                PrimaryButton(title: "Continue") {
                    flow.go(index + 1 < flow.chosen.count ? .counts(index + 1) : .mala)
                }
                .padding(.vertical, Theme.Space.l)
            }
        }
    }

    @ViewBuilder
    private func sections(_ p: Binding<OnboardingPractice>) -> some View {
        Section {
            PracticeName(practice: p.wrappedValue.practice)
        } header: {
            Text("Practice \(index + 1) of \(flow.chosen.count)")
        }
        if !p.wrappedValue.streakOnly {
            Section {
                NumberField(title: "Count so far", value: p.countSoFar)
                if p.wrappedValue.showsRound {
                    Stepper(value: p.round, in: 1...99) { Text("Round \(p.wrappedValue.round)") }
                } else if p.wrappedValue.practice.target != nil {
                    Button("I'm doing a later round") { p.wrappedValue.showsRound = true }
                }
            } footer: {
                Text("From paper or a spreadsheet; rough is fine.")
            }
        }
        Section {
            NumberField(title: "Current streak, in days", value: p.streak)
            if p.wrappedValue.streak > 0 {
                Picker("Last practised", selection: p.lastWasToday) {
                    Text("Today").tag(true)
                    Text("Yesterday").tag(false)
                }
                .pickerStyle(.segmented)
                NumberField(title: "Longest streak (optional)",
                            value: Binding(get: { p.wrappedValue.longest ?? 0 },
                                           set: { p.wrappedValue.longest = $0 > 0 ? $0 : nil }))
            }
        } footer: {
            Text("Your streak so far counts on your own Today screen. Friends only ever see days tracked in the app.")
        }
    }
}

/// A whole-number field that shows empty for 0 (no "035000" from typing after a
/// prefilled zero) and wraps its label rather than truncating it.
struct NumberField: View {
    let title: LocalizedStringKey
    @Binding var value: Int

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.s)
            TextField("0", text: Binding(
                get: { value == 0 ? "" : String(value) },
                set: { value = Int($0.filter { $0.isASCII && $0.isNumber }.prefix(9)) ?? 0 }))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: Theme.Size.numberField)
        }
    }
}

private struct MalaStep: View {
    @EnvironmentObject private var flow: OnboardingFlow

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            StepHeader(title: "How much does one mala count?",
                       detail: "Teachers differ. Each practice can change this later in Settings.")
            ChoiceButton(title: "100") { flow.malaSize = 100; flow.go(.reminder) }
            ChoiceButton(title: "108") { flow.malaSize = 108; flow.go(.reminder) }
        }
    }
}

private struct ReminderStep: View {
    @EnvironmentObject private var flow: OnboardingFlow
    @State private var time = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: Date()) ?? Date()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            StepHeader(title: "When should we remind you?",
                       detail: "An evening nudge when a streak is at risk. It is scheduled on this phone; nothing leaves it.")
            DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity)
            Spacer()
            PrimaryButton(title: "Remind me at this time") {
                flow.reminder = time
                flow.go(.door)
            }
            ChoiceButton(title: "No reminders") {
                flow.reminder = nil
                flow.go(.door)
            }
        }
        .padding(.bottom, Theme.Space.xl)
        .onAppear { if let r = flow.reminder { time = r } }
    }
}

/// Where the doors part. Accounts and friends need the server (phase 3); until
/// then every door ends in local mode, said plainly rather than faked.
private struct DoorStep: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var flow: OnboardingFlow

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            switch flow.door {
            case .justMe:
                StepHeader(title: "Everything stays on this phone",
                           detail: "No account and no network. You can sign up later and keep everything.")
            case .invite, .existingAccount:
                StepHeader(title: "Accounts are not ready yet",
                           detail: "This build has no server. Your practice is kept on this phone, and joining friends will pick it up later.")
            }
            Spacer()
            PrimaryButton(title: "Start practising") { flow.finish(into: model) }
        }
        .padding(.bottom, Theme.Space.xl)
    }
}

#Preview {
    OnboardingView().environmentObject(AppModel.preview())
}

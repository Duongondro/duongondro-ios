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
            VStack(spacing: 0) {
                if flow.step != .welcome { StepTopBar() }
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
            }
            .padding(.horizontal, Theme.Space.xl)
            .background(Theme.ground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .animation(.default, value: flow.step)
        }
        .environmentObject(flow)
    }
}

// MARK: - State

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
            chosen.append(OnboardingPractice(practice: p, streakOnly: p.streakOnlyByDefault))
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

extension OnboardingStep {
    /// Which of the five progress dashes this step reaches.
    var dashes: Int {
        switch self {
        case .welcome, .finishedNgondro: return 1
        case .finishedShortRefuge: return 2
        case .practices: return 3
        case .counts, .mala: return 4
        case .reminder, .door: return 5
        }
    }
}

// MARK: - Building blocks

/// Back chevron on the left, five progress dashes centred (the mockups' top bar).
private struct StepTopBar: View {
    @EnvironmentObject private var flow: OnboardingFlow
    private let total = 5

    var body: some View {
        HStack(spacing: 0) {
            Button { flow.back() } label: {
                Image(systemName: "chevron.backward")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: Theme.Size.minTap, height: Theme.Size.minTap)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            .opacity(flow.canGoBack ? 1 : 0)
            .disabled(!flow.canGoBack)
            Spacer(minLength: 0)
            HStack(spacing: Theme.Space.dash) {
                ForEach(1...total, id: \.self) { n in
                    RoundedRectangle(cornerRadius: Theme.Radius.dash, style: .continuous)
                        .fill(n <= flow.step.dashes ? Theme.accent : Theme.inputBorder)
                        .frame(width: Theme.Size.stepDash.width, height: Theme.Size.stepDash.height)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(flow.step.dashes) of \(total)")
            Spacer(minLength: 0)
            Color.clear.frame(width: Theme.Size.minTap, height: Theme.Size.minTap)
        }
        .padding(.horizontal, -Theme.Space.s)
    }
}

private struct StepHeader: View {
    let title: LocalizedStringKey
    var detail: LocalizedStringKey?
    var titleSize: CGFloat = 32
    var titleStyle: Font.TextStyle = .title
    var detailFont: Font = .system(size: 16)
    var detailColor: Color = Theme.soft

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(title)
                .font(Typography.headingBold(titleSize, relativeTo: titleStyle))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(detailFont)
                    .foregroundStyle(detailColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A full-width flat button of the given style, with a text label.
struct PrimaryButton: View {
    let title: LocalizedStringKey
    var fill: Color = Theme.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) { Text(title) }
            .buttonStyle(FilledButtonStyle(fill: fill, height: Theme.Size.welcomeButton))
    }
}

private struct ChoiceButton: View {
    let title: LocalizedStringKey
    var filled = false
    let action: () -> Void

    var body: some View {
        if filled {
            Button(action: action) { Text(title) }
                .buttonStyle(FilledButtonStyle(height: Theme.Size.answer))
        } else {
            Button(action: action) { Text(title) }
                .buttonStyle(OutlinedButtonStyle(height: Theme.Size.answer))
        }
    }
}

/// Yes/no screens: centred question, the two answers at the bottom.
private struct QuestionLayout<Answers: View>: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    @ViewBuilder let answers: Answers

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            Spacer(minLength: 0)
            StepHeader(title: title, detail: detail, titleSize: 36, titleStyle: .largeTitle)
            Spacer(minLength: 0)
            VStack(spacing: Theme.Space.m) { answers }
        }
        .padding(.bottom, Theme.Space.xl)
    }
}

// MARK: - Steps

// MARK: - Steps

private struct WelcomeStep: View {
    @EnvironmentObject private var flow: OnboardingFlow

    // The Welcome mockup (design canvas "Welcome, light" / "Welcome, dark"): centred,
    // the emblem, the name, the tagline with its encryption line in gold, then the
    // three doors: a filled button, an outlined one, and a text link.
    var body: some View {
        VStack(spacing: Theme.Space.xxl) {
            Spacer(minLength: Theme.Space.xxl)
            Image("Emblem")
                .resizable()
                .scaledToFit()
                .frame(width: Theme.Size.emblem)
                .accessibilityHidden(true)
            VStack(spacing: Theme.Space.m) {
                Text(verbatim: "Duongöndro")
                    .font(Typography.headingBold(44, relativeTo: .largeTitle))
                    .foregroundStyle(Theme.welcomeTitle)
                Text("Track your meditation practice together with your friends.")
                    .font(.title3)
                    .foregroundStyle(Theme.welcomeSoft)
                Text("End-to-end encrypted and fully open source.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.welcomeGoldText)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            Spacer()
            VStack(spacing: Theme.Space.m) {
                Button { pick(.invite) } label: {
                    Text("I have an invite")
                        .font(.headline)
                        .foregroundStyle(Theme.welcomePrimaryInk)
                        .frame(maxWidth: .infinity, minHeight: Theme.Size.welcomeButton)
                        .background(Theme.welcomePrimary, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                }
                Button { pick(.justMe) } label: {
                    Text("Just me, on this phone")
                        .font(.headline)
                        .foregroundStyle(Theme.welcomeOutlineInk)
                        .frame(maxWidth: .infinity, minHeight: Theme.Size.welcomeButton)
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
                            .strokeBorder(Theme.welcomeOutline, lineWidth: 2))
                }
                Button { pick(.existingAccount) } label: {
                    Text("I already have an account")
                        .font(.subheadline.weight(.semibold))
                        .underline()
                        .foregroundStyle(Theme.welcomeSoft)
                        .frame(maxWidth: .infinity, minHeight: Theme.Size.minTap)
                }
            }
            .buttonStyle(.plain)
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
        QuestionLayout(title: LocalizedStringKey(Gendered.mine("Have you finished ngöndro?")),
                       detail: "All four parts, 111,111 each. Repeat rounds come later.") {
            ChoiceButton(title: "Yes", filled: true) {
                flow.finishedNgondro = true
                flow.finishedShortRefuge = true
                flow.pruneToAvailable()
                flow.go(.practices)
            }
            ChoiceButton(title: "Not yet") {
                flow.finishedNgondro = false
                flow.go(.finishedShortRefuge)
            }
        }
    }
}

private struct FinishedShortRefugeStep: View {
    @EnvironmentObject private var flow: OnboardingFlow

    var body: some View {
        QuestionLayout(title: LocalizedStringKey(Gendered.mine("Have you finished short refuge?")),
                       detail: "The short refuge meditation you do before starting ngöndro.") {
            ChoiceButton(title: "Yes", filled: true) {
                flow.finishedShortRefuge = true
                flow.pruneToAvailable()
                flow.go(.practices)
            }
            ChoiceButton(title: "Not yet") {
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
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            StepHeader(title: "Which do you practise daily?", detail: "Pick as many as you do.",
                       detailFont: .system(size: 14), detailColor: Theme.muted)
                .padding(.top, Theme.Space.s)
            ScrollView {
                CardSection {
                    ForEach(flow.available + flow.chosen.map(\.practice).filter(\.isCustom)) { p in
                        PracticeChoiceRow(practice: p)
                    }
                    Button { addingCustom = true } label: {
                        Text("+ Add your own")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(maxWidth: .infinity, minHeight: Theme.Size.field, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .plainBottomEdge()
            PrimaryButton(title: "Continue") { flow.go(.counts(0)) }
                .disabled(flow.chosen.isEmpty)
                .opacity(flow.chosen.isEmpty ? 0.4 : 1)
                .padding(.bottom, Theme.Space.xl)
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
    /// Second names longer than this go on their own line.
    private let inlineLimit = 20

    var body: some View {
        let chosen = flow.isChosen(practice.id)
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Button { flow.toggle(practice) } label: {
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    Image(systemName: chosen ? "checkmark.square.fill" : "square")
                        .font(.system(size: 22))
                        .foregroundStyle(chosen ? Theme.accent : Theme.inputBorder)
                    nameText(chosen: chosen)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, Theme.Space.s)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(chosen ? .isSelected : [])
            if chosen, practice.streakOnlyAllowed, let i = flow.chosen.firstIndex(where: { $0.id == practice.id }) {
                Toggle("Streak only, no count", isOn: $flow.chosen[i].streakOnly)
                    .font(.footnote)
                    .foregroundStyle(Theme.soft)
                    .padding(.bottom, Theme.Space.s)
            }
        }
    }

    @ViewBuilder
    private func nameText(chosen: Bool) -> some View {
        let name = Text(verbatim: practice.shownName).font(.system(size: 16, weight: chosen ? .bold : .regular)).foregroundColor(Theme.ink)
        if let second = practice.shownSecondName {
            if second.count > inlineLimit {
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    name
                    Text(second).font(.system(size: 13)).foregroundColor(Theme.muted)
                }
            } else {
                name + Text("  ") + Text(second).font(.system(size: 14)).foregroundColor(Theme.muted)
            }
        } else {
            name
        }
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
            let p = $flow.chosen[index]
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.l) {
                        Text("\(index + 1) of \(flow.chosen.count) practices")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Theme.muted)
                        StepHeader(title: "Where are you with \(p.wrappedValue.practice.shownName)?", titleSize: 28)
                        card(p)
                        if !p.wrappedValue.streakOnly, p.wrappedValue.showsRound {
                            Stepper(value: p.round, in: 1...99) { Text("Round \(p.wrappedValue.round)") }
                                .foregroundStyle(Theme.soft)
                        } else if !p.wrappedValue.streakOnly, p.wrappedValue.practice.target != nil {
                            Button { p.wrappedValue.showsRound = true } label: {
                                Text("I'm doing a later round")
                                    .font(.system(size: 14, weight: .semibold))
                                    .underline()
                                    .foregroundStyle(Theme.accent)
                                    .frame(minHeight: Theme.Size.minTap, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                        if p.wrappedValue.streak > 0 {
                            NumberField(title: "Longest streak (optional)",
                                        value: Binding(get: { p.wrappedValue.longest ?? 0 },
                                                       set: { p.wrappedValue.longest = $0 > 0 ? $0 : nil }))
                                .font(.footnote)
                                .foregroundStyle(Theme.soft)
                        }
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            if !p.wrappedValue.streakOnly {
                                Text("From paper or a spreadsheet; rough is fine.")
                            }
                            Text("Your streak so far counts on your own Today screen. Friends only ever see days tracked in the app.")
                        }
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, Theme.Space.s)
                }
                .plainBottomEdge()
                PrimaryButton(title: "Continue") {
                    flow.go(index + 1 < flow.chosen.count ? .counts(index + 1) : .mala)
                }
                .padding(.bottom, Theme.Space.xl)
            }
        }
    }

    private func card(_ p: Binding<OnboardingPractice>) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                if !p.wrappedValue.streakOnly {
                    CountField(label: "So far", value: p.countSoFar)
                }
                CountField(label: "Streak, days", value: p.streak)
            }
            HStack(spacing: Theme.Space.s) {
                Text("Last practised")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.soft)
                SegmentedChoice(options: [(true, String(localized: "Today", bundle: .appLanguage, locale: .appLanguage)), (false, String(localized: "Yesterday", bundle: .appLanguage, locale: .appLanguage))],
                                selection: p.lastWasToday)
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

/// A labelled whole-number box of the Totals mockup; empty for 0, digits only.
private struct CountField: View {
    let label: LocalizedStringKey
    @Binding var value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(label)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.soft)
            TextField("0", text: Binding(
                get: { value == 0 ? "" : value.grouped },
                set: { value = Int($0.filter { $0.isASCII && $0.isNumber }.prefix(9)) ?? 0 }))
                .keyboardType(.numberPad)
                .font(Typography.headingBold(20, relativeTo: .title3))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, Theme.Space.m)
                .frame(height: Theme.Size.field)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .strokeBorder(Theme.inputBorder, lineWidth: 1))
                .accessibilityLabel(label)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                get: { value == 0 ? "" : value.grouped },
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
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            StepHeader(title: "How much does one mala count?",
                       detail: "Teachers differ. Each practice can change this later in Settings.")
                .padding(.top, Theme.Space.s)
            Spacer(minLength: 0)
            ChoiceButton(title: "100") { flow.malaSize = 100; flow.go(.reminder) }
            ChoiceButton(title: "108") { flow.malaSize = 108; flow.go(.reminder) }
                .padding(.bottom, Theme.Space.xl)
        }
    }
}

private struct ReminderStep: View {
    @EnvironmentObject private var flow: OnboardingFlow
    @State private var time = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: Date()) ?? Date()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            StepHeader(title: "When should we remind you?",
                       detail: "An evening nudge when a streak is at risk. It is scheduled on this phone; nothing leaves it.")
                .padding(.top, Theme.Space.s)
            DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            ChoiceButton(title: "Remind me at this time", filled: true) {
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
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Group {
                switch flow.door {
                case .justMe:
                    StepHeader(title: "Everything stays on this phone",
                           detail: "No account and no network. You can sign up later and keep everything.")
                case .invite, .existingAccount:
                    StepHeader(title: "Accounts are not ready yet",
                               detail: "This build has no server. Your practice is kept on this phone, and joining friends will pick it up later.")
                }
            }
            .padding(.top, Theme.Space.s)
            Spacer(minLength: 0)
            PrimaryButton(title: "Start practising") { flow.finish(into: model) }
        }
        .padding(.bottom, Theme.Space.xl)
    }
}

#Preview {
    OnboardingView().environmentObject(AppModel.preview())
}

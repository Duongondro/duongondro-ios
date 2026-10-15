import SwiftUI
import DuongondroCore
import DuongondroStore

/// The practice comes before the account: one question per screen, each with
/// a back button that returns one step and keeps the answers given so far.
/// Yes/no questions advance on tap. From Settings, with `done`, only the account
/// steps from `start` (sign in again, or make an account later), leaving the
/// practices and preferences as they are.
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: AccountModel
    @StateObject private var flow = OnboardingFlow()
    var start: OnboardingStep = .welcome
    var done: (() -> Void)?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if flow.step != .welcome { StepTopBar(leave: done != nil && !flow.canGoBack ? done : nil) }
                Group {
                    switch flow.step {
                    case .welcome: WelcomeStep()
                    case .finishedNgondro: FinishedNgondroStep()
                    case .finishedShortRefuge: FinishedShortRefugeStep()
                    case .practices: PracticesStep()
                    case .counts(let index): CountsStep(index: index).id(index)
                    case .reminder: ReminderStep()
                    case .where: WhereStep()
                    case .consent: ConsentStep()
                    case .email: EmailStep()
                    case .checkEmail: CheckEmailStep()
                    case .name: NameStep()
                    case .gender: GenderStep()
                    case .passkey: PasskeyStep()
                    case .recovery: RecoveryStep()
                    case .recoveryCheck: RecoveryCheckStep()
                    case .signIn: SignInStep()
                    case .restore: RestoreStep()
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
        .onAppear {
            flow.begin(start)
            flow.finishLocal = { [weak flow, model] in
                if let done { done() } else { flow?.finish(into: model) }
            }
            flow.finishOnline = { [weak flow, model, account] in
                if let done {
                    Task { await account.syncNow() }
                    done()
                } else {
                    flow?.finish(into: model)
                    Task { await account.syncNow() }
                }
            }
        }
    }
}

// MARK: - State

enum OnboardingStep: Hashable {
    case welcome, finishedNgondro, finishedShortRefuge, practices, counts(Int), reminder
    /// "Keep it on this phone, or online?"
    case `where`
    /// Sign-up: consent, then the passkey (or an emailed link) makes the account;
    /// name and gender may be skipped.
    case consent, email, checkEmail, name, gender, passkey, recovery
    /// Two groups of the recovery code typed back.
    case recoveryCheck
    /// "Welcome back": sign in with a passkey or an emailed link.
    case signIn
    /// Signed in to an account with keys on a new phone: the recovery code brings them back.
    case restore
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

    /// True after "I already have an account": the email steps sign in rather than up.
    @Published var signingIn = false
    /// A sign-in waits for "erase the other account's practice here, or cancel".
    @Published var otherAccount = false
    @Published var consented = false
    /// What a magic-link request carries: nil signs in; a sign-up sends the
    /// consent given on the Consent step, which every sign-up path passes first.
    var signUpConsent: Bool? { signingIn ? nil : consented }
    @Published var email = ""
    @Published var displayName = ""
    /// The name the server gave the new account (a random one when none was
    /// given), read once; Skip keeps it.
    var serverName: String?
    @Published var gender: Gender?
    /// Set by the view: local mode keeps the onboarding's answers; from Settings
    /// nothing about the practices changes.
    var finishLocal: () -> Void = {}
    var finishOnline: () -> Void = {}
    private var begun = false
    @Published var finishedNgondro = false
    @Published var finishedShortRefuge = false
    /// Chosen practices, in the order picked. Kept when the user goes back.
    @Published var chosen: [OnboardingPractice] = []
    @Published var reminder: Date? = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: Date())

    var canGoBack: Bool { !history.isEmpty }

    /// Where a flow from Settings starts, once.
    func begin(_ start: OnboardingStep) {
        guard !begun else { return }
        begun = true
        if start != .welcome {
            step = start
            signingIn = start == .signIn
        }
    }

    func go(_ next: OnboardingStep) {
        history.append(step)
        step = next
    }

    func back() {
        guard let previous = history.popLast() else { return }
        step = previous
    }

    /// The account exists: the steps that made it are behind for good, so Back
    /// cannot ask for another passkey or sign-up.
    func signedUp(next: OnboardingStep) {
        history.removeAll()
        step = next
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
        // Signing in skips the practice questions, the reminder's among them.
        prefs.reminderMinutes = signingIn ? nil : reminder.map { r in
            let c = Calendar.current.dateComponents([.hour, .minute], from: r)
            return (c.hour ?? 20) * 60 + (c.minute ?? 0)
        }
        model.perform { try $0.completeOnboarding(practices: practices, seeds: seeds, preferences: prefs) }
        if prefs.reminderMinutes != nil { Task { await Reminders.requestAndSchedule(model) } }
    }
}

extension OnboardingStep {
    static let practiceSteps = 5
    static let accountSteps = 3

    /// How far along the dashes a step is, and out of how many: five practice
    /// questions, then three account steps; nil for steps without dashes.
    func progress(signingIn: Bool) -> (reached: Int, total: Int)? {
        switch self {
        case .finishedNgondro: return (1, Self.practiceSteps)
        case .finishedShortRefuge: return (2, Self.practiceSteps)
        case .practices: return (3, Self.practiceSteps)
        case .counts: return (4, Self.practiceSteps)
        case .reminder: return (5, Self.practiceSteps)
        case .passkey, .email, .checkEmail: return signingIn ? nil : (1, Self.accountSteps)
        case .name: return signingIn ? nil : (2, Self.accountSteps)
        case .gender: return signingIn ? nil : (3, Self.accountSteps)
        default: return nil
        }
    }
}

// MARK: - Building blocks

/// Back chevron on the left, the progress dashes centred where the step has
/// them (the mockups' top bar). `leave` closes the account steps opened from Settings.
private struct StepTopBar: View {
    @EnvironmentObject private var flow: OnboardingFlow
    @EnvironmentObject private var account: AccountModel
    var leave: (() -> Void)?

    var body: some View {
        let progress = flow.step.progress(signingIn: flow.signingIn)
        // No way back while keys are being made: the work goes on regardless, and
        // the steps behind it would ask for a passkey or profile it already has.
        let canLeave = (flow.canGoBack || leave != nil) && !account.keyWorkRunning
        HStack(spacing: 0) {
            Button { if let leave { leave() } else { flow.back() } } label: {
                Image(systemName: "chevron.backward")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: Theme.Size.minTap, height: Theme.Size.minTap)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            .opacity(flow.canGoBack || leave != nil ? 1 : 0)
            .disabled(!canLeave)
            Spacer(minLength: 0)
            if let progress {
                HStack(spacing: Theme.Space.dash) {
                    ForEach(1...progress.total, id: \.self) { n in
                        RoundedRectangle(cornerRadius: Theme.Radius.dash, style: .continuous)
                            .fill(n <= progress.reached ? Theme.accent : Theme.inputBorder)
                            .frame(width: Theme.Size.stepDash.width, height: Theme.Size.stepDash.height)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(progress.total == OnboardingStep.accountSteps
                                    ? Text("Account, step \(progress.reached) of \(progress.total)")
                                    : Text("Step \(progress.reached) of \(progress.total)"))
            }
            Spacer(minLength: 0)
            Color.clear.frame(width: Theme.Size.minTap, height: Theme.Size.minTap)
        }
        .padding(.horizontal, -Theme.Space.s)
    }
}

struct StepHeader: View {
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

struct ChoiceButton: View {
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

private struct WelcomeStep: View {
    @EnvironmentObject private var flow: OnboardingFlow

    // Onboarding v2's Welcome: centred, the emblem, the name, the motto, the
    // tagline with its encryption line in gold, then two equal doors.
    var body: some View {
        VStack(spacing: Theme.Space.xxl) {
            Spacer(minLength: Theme.Space.xxl)
            Image("Emblem")
                .resizable()
                .scaledToFit()
                .frame(width: Theme.Size.emblem)
                .accessibilityHidden(true)
            VStack(spacing: Theme.Space.m) {
                VStack(spacing: Theme.Space.xs) {
                    Text(verbatim: "Duongöndro")
                        .font(Typography.headingBold(44, relativeTo: .largeTitle))
                        .foregroundStyle(Theme.welcomeTitle)
                    // The motto stays English in every language, on one line,
                    // shrinking rather than wrapping.
                    Text(verbatim: "A ngöndro tracker for the TikTok generation")
                        .font(.footnote)
                        .foregroundStyle(Theme.welcomeSoft)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                Button {
                    flow.signingIn = false
                    flow.go(.finishedNgondro)
                } label: {
                    Text("Get started")
                        .font(.headline)
                        .foregroundStyle(Theme.welcomePrimaryInk)
                        .frame(maxWidth: .infinity, minHeight: Theme.Size.welcomeButton)
                        .background(Theme.welcomePrimary, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                }
                Button {
                    flow.signingIn = true
                    flow.go(.signIn)
                } label: {
                    Text("I already have an account")
                        .font(.headline)
                        .foregroundStyle(Theme.welcomeOutlineInk)
                        .frame(maxWidth: .infinity, minHeight: Theme.Size.welcomeButton)
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
                            .strokeBorder(Theme.welcomeOutline, lineWidth: 2))
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, Theme.Space.xl)
        .background(Theme.welcomeGround.padding(.horizontal, -Theme.Space.xl).ignoresSafeArea())
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
                    flow.go(index + 1 < flow.chosen.count ? .counts(index + 1) : .reminder)
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
                flow.go(.where)
            }
            ChoiceButton(title: "No reminders") {
                flow.reminder = nil
                flow.go(.where)
            }
        }
        .padding(.bottom, Theme.Space.xl)
        .onAppear { if let r = flow.reminder { time = r } }
    }
}

#Preview {
    OnboardingView().environmentObject(AppModel.preview())
        .environmentObject(AccountModel(database: AppModel.preview().database))
}

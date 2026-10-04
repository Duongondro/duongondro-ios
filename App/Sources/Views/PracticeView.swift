import SwiftUI
import DuongondroCore
import DuongondroStore

/// A practice's own screen: the only place counts are logged. Each +mala opens
/// a few seconds' Undo; the session is written only when that window closes.
struct PracticeView: View {
    @EnvironmentObject private var model: AppModel
    let practiceID: String
    @State private var taps = 0
    @State private var customAmount: String?

    var body: some View {
        if let practice = model.snapshot.practices.first(where: { $0.id == practiceID }) {
            content(practice)
        } else {
            Text("This practice is gone.").foregroundStyle(Theme.muted)
        }
    }

    private func content(_ practice: TrackedPractice) -> some View {
        let streak = model.streak(of: practice.id)
        let mala = model.malaSize(of: practice)
        let doneToday = model.practisedToday(practice.id)
        return ScrollView {
            VStack(spacing: Theme.Space.l) {
                PracticeName(practice: practice.practice, large: true)
                    .padding(.top, Theme.Space.l)
                stats(practice, streak: streak)
                StartRow(practiceID: practice.id)
                if practice.streakOnly {
                    BigButton(title: doneToday ? "Done today" : "Mark today done", systemImage: "checkmark") {
                        taps += 1
                        model.add(0, to: practice.id)
                    }
                    .disabled(doneToday || model.pending?.practiceID == practice.id)
                } else {
                    BigButton(title: "+\(mala)", systemImage: nil) {
                        taps += 1
                        model.add(mala, to: practice.id)
                    }
                    .accessibilityLabel(Text("Add one mala, \(mala)"))
                    Button("Add another amount") { customAmount = "" }
                        .font(.body.weight(.medium))
                }
                // Below the button, so it never moves under the thumb mid-count.
                if let pending = model.pending, pending.practiceID == practice.id {
                    UndoBar(pending: pending, streakOnly: practice.streakOnly)
                }
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.bottom, Theme.Space.xxl)
        }
        .countTapFeedback(trigger: taps)
        .successFeedback(trigger: model.practisedToday(practiceID))
        .background(Theme.ground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: Binding(get: { customAmount != nil }, set: { if !$0 { customAmount = nil } })) {
            CustomAmountSheet { amount in
                taps += 1
                model.add(amount, to: practice.id)
            }
        }
    }

    @ViewBuilder
    private func stats(_ practice: TrackedPractice, streak: Streak.Result) -> some View {
        let sessions = model.snapshot.sessions(of: practice.id)
        VStack(spacing: Theme.Space.s) {
            if let r = practice.rounds(sessions: sessions), let target = practice.practice.target {
                Text(r.inRound.grouped)
                    .font(Typography.count)
                    .contentTransition(.numericText())
                Text("Round \(r.round) · \(r.inRound.grouped) of \(target.grouped)")
                    .foregroundStyle(Theme.muted)
                ProgressView(value: Double(r.inRound), total: Double(target))
                if r.round > 1 {
                    Text("\(r.lifetime.grouped) in all rounds")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                }
            } else if !practice.streakOnly {
                Text(practice.lifetime(sessions: sessions).grouped)
                    .font(Typography.count)
                    .contentTransition(.numericText())
            }
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "flame.fill").foregroundStyle(Theme.flame)
                    .symbolBounce(value: streak.current)
                Text("\(streak.current) days")
                if streak.longest > streak.current {
                    Text("· longest \(streak.longest)").foregroundStyle(Theme.muted)
                }
            }
            .font(Typography.headline)
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity)
        .cardStyle()
    }
}

/// Start: records the exact start, so the session needs no estimate.
private struct StartRow: View {
    @EnvironmentObject private var model: AppModel
    let practiceID: String

    var body: some View {
        if let started = model.started[practiceID] {
            HStack {
                Image(systemName: "timer").foregroundStyle(Theme.accent)
                Text("Started \(started.shortTime) · \(Text(started, style: .timer))")
                Spacer()
                Button("Cancel") { model.cancelStart(practiceID) }
            }
            .cardStyle()
        } else {
            Button {
                model.start(practiceID)
            } label: {
                Label("Start", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .secondaryButtonStyle()
        }
    }
}

private struct UndoBar: View {
    @EnvironmentObject private var model: AppModel
    let pending: PendingLog
    let streakOnly: Bool

    var body: some View {
        HStack {
            if streakOnly {
                Text("Marked done")
            } else {
                Text("Added \(pending.amount.grouped)")
            }
            Spacer()
            Button("Undo") { model.undo() }
                .bold()
        }
        .floatingBar()
        .transition(.opacity)
        .onAppear { announce() }
        .onChange(of: pending.amount) { _ in announce() }
    }

    /// VoiceOver hears that something was added and Undo is there.
    private func announce() {
        let text = streakOnly ? String(localized: "Marked done. Undo available.")
                              : String(localized: "Added \(pending.amount.grouped). Undo available.")
        UIAccessibility.post(notification: .announcement, argument: text)
    }
}

/// The large +mala button: 8 pt corners, the one big control on the screen.
private struct BigButton: View {
    let title: LocalizedStringKey
    let systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            // The count reads large; a sentence (streak-only practices) stays on one line.
            .font(systemImage == nil ? Typography.count : Typography.headingBold(22, relativeTo: .title2))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(Theme.onAccent)
            .frame(maxWidth: .infinity, minHeight: Theme.Size.bigButton)
        }
        .primaryButtonStyle(radius: Theme.Radius.bigButton)
    }
}

private struct CustomAmountSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: (Int) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    private var amount: Int? { Int(text.filter { $0.isASCII && $0.isNumber }.prefix(9)).flatMap { $0 > 0 ? $0 : nil } }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Amount", text: $text)
                    .keyboardType(.numberPad)
                    .focused($focused)
            }
            .navigationTitle("Add another amount")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if let amount { onAdd(amount) }
                        dismiss()
                    }
                    .disabled(amount == nil)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }
}

/// "Counted for Sunday · you started around 23:30", with the one-tap switch.
struct AfterMidnightSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let prompt: AfterMidnightPrompt

    var body: some View {
        let tz = prompt.session.timeZone
        VStack(spacing: Theme.Space.l) {
            Text("Counted for \(prompt.sheet.countedFor.weekdayName(in: tz))")
                .font(Typography.title)
            Text("You started around \(prompt.sheet.startedAround.shortTime).")
                .foregroundStyle(Theme.muted)
            Button("Count it for \(prompt.sheet.alternative.weekdayName(in: tz)) instead") {
                model.choose(day: prompt.sheet.alternative, for: prompt)
            }
            .secondaryButtonStyle()
            Button("Keep \(prompt.sheet.countedFor.weekdayName(in: tz))") { dismiss() }
                .primaryButtonStyle()
        }
        .multilineTextAlignment(.center)
        .padding(Theme.Space.xl)
        .presentationDetents([.medium])
    }
}

#Preview {
    NavigationStack { PracticeView(practiceID: "dorje-sempa") }.environmentObject(AppModel.preview())
}

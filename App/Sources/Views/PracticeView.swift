import SwiftUI
import DuongondroCore
import DuongondroStore

/// A practice's own screen (design canvas "Practice"): the name, where the count
/// stands, and at the bottom, under the thumb, the big +mala button with Custom,
/// Start and History beside it. The only place counts are logged. Each +mala
/// opens a few seconds' Undo; the session is written only when that window closes.
struct PracticeView: View {
    @EnvironmentObject private var model: AppModel
    let practiceID: String
    @State private var taps = 0
    @State private var customAmount: String?
    @State private var showsHistory = false
    /// Bumped when a cover is added, so the header reloads it.
    @State private var coverVersion = 0

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
        return VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                CoverView(practiceID: practice.id).id(coverVersion)
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    header(practice)
                    if practice.streakOnly {
                        streakOnlyStatus(streak: streak, done: doneToday)
                    } else {
                        countBlock(practice, streak: streak, mala: mala)
                    }
                }
                .padding(.horizontal, Theme.Space.xl)
                .padding(.top, hasCover(practice.id) ? Theme.Space.xl : Theme.Space.s)
            }
            .plainBottomEdge()
            // The cover runs up under the status bar, as in the mockup.
            .ignoresSafeArea(edges: hasCover(practice.id) ? .top : [])
            VStack(spacing: Theme.Space.m) {
                // The Undo toast sits above the button, which is pinned to the bottom,
                // so the button never moves under the thumb mid-count.
                if let pending = model.pending, pending.practiceID == practice.id {
                    UndoToast(pending: pending, streakOnly: practice.streakOnly)
                }
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
                }
                HStack(spacing: Theme.Space.m) {
                    if !practice.streakOnly {
                        Button("+ Custom") { customAmount = "" }
                            .buttonStyle(OutlinedButtonStyle(height: Theme.Size.secondary))
                    }
                    Button("History") { showsHistory = true }
                        .buttonStyle(SoftButtonStyle())
                }
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.bottom, Theme.Space.xl)
            .animation(.default, value: model.pending?.practiceID)
        }
        .countTapFeedback(trigger: taps)
        .successFeedback(trigger: model.practisedToday(practiceID))
        .background(Theme.ground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        // Full screen, as in the mockup: the big button owns the bottom edge.
        .toolbar(.hidden, for: .tabBar)
        .sheet(isPresented: Binding(get: { customAmount != nil }, set: { if !$0 { customAmount = nil } })) {
            CustomAmountSheet { amount in
                taps += 1
                model.add(amount, to: practice.id)
            }
        }
        .sheet(isPresented: $showsHistory) {
            HistoryView(practice: practice)
        }
    }

    private func hasCover(_ id: String) -> Bool {
        _ = coverVersion
        return Covers.photo(for: id) != nil || Covers.builtIn(for: id) != nil
    }

    /// "Dorje Sempa", and below it "Diamond Mind · round 1 · 43,308 lifetime".
    private func header(_ practice: TrackedPractice) -> some View {
        let sessions = model.snapshot.sessions(of: practice.id)
        var parts: [String] = []
        if let second = practice.practice.shownSecondName { parts.append(second) }
        if !practice.streakOnly {
            if let r = practice.rounds(sessions: sessions) { parts.append(String(localized: "round \(r.round)", bundle: .appLanguage, locale: .appLanguage)) }
            parts.append(String(localized: "\(practice.lifetime(sessions: sessions).grouped) lifetime", bundle: .appLanguage, locale: .appLanguage))
        } else {
            parts.append(String(localized: "streak only", bundle: .appLanguage, locale: .appLanguage))
        }
        return VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(practice.practice.shownName)
                .font(Typography.headingBold(30, relativeTo: .largeTitle))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(parts.joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if !hasCover(practice.id) {
                AddCoverButton(practiceID: practice.id) { coverVersion += 1 }
                    .padding(.top, Theme.Space.xs)
            }
        }
    }

    /// The count in the current round, its target, a bar, today's total and the streak.
    private func countBlock(_ practice: TrackedPractice, streak: Streak.Result, mala: Int) -> some View {
        let sessions = model.snapshot.sessions(of: practice.id)
        let rounds = practice.rounds(sessions: sessions)
        let shown = rounds?.inRound ?? practice.lifetime(sessions: sessions)
        let today = CivilDate.of(model.clock, in: .current)
        let todayTotal = sessions.filter { $0.day == today }.reduce(0) { $0 + $1.amount }
        return VStack(alignment: .leading, spacing: Theme.Space.s + Theme.Space.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(shown.grouped)
                    .font(Typography.headingBold(52, relativeTo: .largeTitle))
                    .foregroundStyle(Theme.accent)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let target = practice.practice.target {
                    Text("of \(target.grouped)")
                        .foregroundStyle(Theme.muted)
                }
            }
            if let rounds, let target = practice.practice.target {
                Bar(fraction: Double(rounds.inRound) / Double(target), height: Theme.Size.barThick)
            }
            HStack {
                Text(todayTotal >= mala
                     ? String(localized: "Today \(todayTotal.grouped) · \(todayTotal / mala) malas", bundle: .appLanguage, locale: .appLanguage)
                     : String(localized: "Today \(todayTotal.grouped)", bundle: .appLanguage, locale: .appLanguage))
                    .foregroundStyle(Theme.muted)
                Spacer()
                StreakBadge(streak: streak)
            }
            .font(.subheadline)
        }
    }

    private func streakOnlyStatus(streak: Streak.Result, done: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "flame.fill").foregroundStyle(Theme.flame)
                Text("\(streak.current) days")
                    .foregroundStyle(Theme.accent)
            }
            .font(Typography.headingBold(52, relativeTo: .largeTitle))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            Text(done ? "Done today" : "Not yet today")
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
            if streak.longest > streak.current {
                Text("Longest \(streak.longest)")
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct StreakBadge: View {
    let streak: Streak.Result

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: "flame.fill").foregroundStyle(Theme.flame)
                .symbolBounce(value: streak.current)
            Text("\(streak.current) days")
                .foregroundStyle(Theme.ink)
        }
        .font(.subheadline.weight(.bold))
        .accessibilityElement(children: .combine)
    }
}

/// "Added 108 · Undo" on a dark strip, with a ring that empties as the window closes.
private struct UndoToast: View {
    @EnvironmentObject private var model: AppModel
    let pending: PendingLog
    let streakOnly: Bool

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            TimelineView(.animation(minimumInterval: 0.1)) { context in
                let left = max(0, pending.deadline.timeIntervalSince(context.date)) / PendingLog.window
                ZStack {
                    Circle().stroke(Theme.toastTrack, lineWidth: Theme.Radius.bar)
                    Circle().trim(from: 0, to: left)
                        .stroke(Theme.toastInk, style: StrokeStyle(lineWidth: Theme.Radius.bar, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: Theme.Space.xl, height: Theme.Space.xl)
            }
            .accessibilityHidden(true)
            Text(streakOnly ? "Marked done" : "Added \(pending.amount.grouped)")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Button("Undo") { model.undo() }
                .font(.subheadline.weight(.heavy))
                .underline()
                .frame(minHeight: Theme.Size.minTap)
                .padding(.horizontal, Theme.Space.m)
        }
        .foregroundStyle(Theme.toastInk)
        .padding(.leading, Theme.Space.l)
        .padding(.trailing, Theme.Space.s)
        .frame(minHeight: Theme.Size.secondary)
        .background(Theme.toast, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .onAppear { announce() }
        .onChange(of: pending.amount) { _ in announce() }
    }

    /// VoiceOver hears that something was added and Undo is there.
    private func announce() {
        let text = streakOnly ? String(localized: "Marked done. Undo available.", bundle: .appLanguage, locale: .appLanguage)
                              : String(localized: "Added \(pending.amount.grouped). Undo available.", bundle: .appLanguage, locale: .appLanguage)
        UIAccessibility.post(notification: .announcement, argument: text)
    }
}

/// The large +mala button: 88 pt, 8 pt corners, the one big control on the screen.
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
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.bigButton, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Every session of one practice, newest day first, with each day's total.
private struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let practice: TrackedPractice

    var body: some View {
        let sessions = model.snapshot.sessions(of: practice.id)
        let days = Dictionary(grouping: sessions, by: \.day).sorted { $0.key > $1.key }
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    if days.isEmpty {
                        Text("Nothing logged yet.")
                            .foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.top, Theme.Space.xxl)
                    }
                    ForEach(days, id: \.key) { day, list in
                        CardSection(header: LocalizedStringKey(day.startOfDay(in: .current).addingTimeInterval(12 * 3600).formatted(.dateTime.weekday(.wide).day().month(.wide).locale(.appLanguage)))) {
                            ForEach(list.sorted { $0.startedAt > $1.startedAt }) { s in
                                HStack {
                                    Text(s.startedAt.shortTime)
                                        .foregroundStyle(Theme.muted)
                                        .monospacedDigit()
                                    Spacer()
                                    Text(practice.streakOnly ? String(localized: "done", bundle: .appLanguage, locale: .appLanguage) : s.amount.grouped)
                                        .font(.body.weight(.semibold))
                                }
                            }
                            if !practice.streakOnly && list.count > 1 {
                                HStack {
                                    Text("Total")
                                    Spacer()
                                    Text(list.reduce(0) { $0 + $1.amount }.grouped)
                                        .font(.body.weight(.bold))
                                }
                            }
                        }
                    }
                }
                .padding(Theme.Space.xl)
            }
            .background(Theme.ground.ignoresSafeArea())
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
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

/// After a session logged past midnight whose estimated start fell before it
/// (design: Social › Which day a session counts for): the day it counted for, OK,
/// or the one alternative.
struct AfterMidnightSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let prompt: AfterMidnightPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Counted for \(prompt.sheet.countedFor.weekdayName(in: prompt.session.timeZone))")
                    .font(Typography.headingBold(26, relativeTo: .title))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.Space.xs) {
                    Text(prompt.session.amount > 0 ? "Logged \(prompt.session.amount.grouped)" : "Marked done")
                    Text(verbatim: "·")
                    Text(prompt.session.loggedAt.shortTime)
                }
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
            }
            Button("OK") { dismiss() }
                .buttonStyle(FilledButtonStyle())
            Button(Gendered.mine("I started after midnight")) { model.choose(day: prompt.sheet.alternative, for: prompt) }
                .buttonStyle(SoftButtonStyle())
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.top, Theme.Space.xl)
        .padding(.bottom, Theme.Space.l)
        .sheetBackground(Theme.card)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

#Preview {
    NavigationStack { PracticeView(practiceID: "dorje-sempa") }.environmentObject(AppModel.preview())
}

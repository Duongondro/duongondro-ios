import SwiftUI
import DuongondroCore
import DuongondroStore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var adding = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                Text("Settings")
                    .font(Typography.largeTitle)
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, Theme.Space.xs)
                    .accessibilityAddTraits(.isHeader)
                CardSection(header: "Practices") {
                    NavigationLink { PracticeListView() } label: {
                        SettingsRow("Your practices", detail: Text(verbatim: "\(model.snapshot.activePractices.count)"), chevron: true)
                    }
                    Button { adding = true } label: {
                        Text("Add a practice")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.vertical, Theme.Space.s)
                            .frame(maxWidth: .infinity, minHeight: Theme.Size.minTap, alignment: .leading)
                    }
                }
                GeneralSection()
                AccountSection()
                CardSection(header: "Your data") {
                    NavigationLink { YourDataView() } label: {
                        SettingsRow("Export and delete", chevron: true)
                    }
                }
                AboutSection()
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.bottom, Theme.Space.xl)
        }
        .buttonStyle(.plain)
        .background(Theme.ground.ignoresSafeArea())
        .statusBarScrim()
        .toolbar(.hidden, for: .navigationBar)
        .numberPadDone()
        .sheet(isPresented: $adding) { AddPracticeView() }
    }
}

/// A label on the left, an optional muted value and chevron on the right.
struct SettingsRow: View {
    let title: LocalizedStringKey
    var detail: Text?
    var detailColor: Color
    var chevron = false

    init(_ title: LocalizedStringKey, detail: Text? = nil, detailColor: Color = Theme.muted, chevron: Bool = false) {
        self.title = title
        self.detail = detail
        self.detailColor = detailColor
        self.chevron = chevron
    }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            // The value goes under the title when the two do not fit on one line
            // ("Code de récupération · En créer un nouveau", a long email).
            FittingRow {
                Text(title).foregroundStyle(Theme.ink)
            } control: {
                if let detail { detail.foregroundStyle(detailColor) }
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Theme.muted)
                    .accessibilityHidden(true)
            }
        }
        // Room above and below a label that wraps in a longer language; a one-line
        // row stays at the minimum height.
        .padding(.vertical, Theme.Space.s)
        .frame(minHeight: Theme.Size.minTap)
        .contentShape(Rectangle())
    }
}

/// The practices, reorderable, with the archived ones behind a row.
private struct PracticeListView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            Group {
                Section {
                    ForEach(model.snapshot.activePractices) { p in
                        NavigationLink { PracticeSettingsView(practiceID: p.id) } label: { PracticeName(practice: p.practice) }
                    }
                    .onMove { from, to in
                        var ids = model.snapshot.activePractices.map(\.id)
                        ids.move(fromOffsets: from, toOffset: to)
                        model.perform { try $0.reorder(ids + model.snapshot.practices.filter(\.archived).map(\.id)) }
                    }
                    let archived = model.snapshot.practices.filter(\.archived)
                    if !archived.isEmpty {
                        NavigationLink("Archived (\(archived.count))") { ArchivedPracticesView() }
                    }
                }
            }
            .themedRows()
        }
        .themedList()
        .navigationTitle("Your practices")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
    }
}

private struct GeneralSection: View {
    @EnvironmentObject private var model: AppModel

    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system
    @AppStorage(Gender.storageKey) private var gender = ""
    @EnvironmentObject private var account: AccountModel

    var body: some View {
        CardSection(header: "General") {
            // Picked in the app itself, as in CodeShare, not by a trip to Settings.
            NavigationLink { LanguageView() } label: {
                SettingsRow("Language", detail: language.nativeName.map { Text(verbatim: $0) } ?? Text("System"), chevron: true)
            }
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                FittingRow {
                    Text("Gender").foregroundStyle(Theme.ink)
                } control: {
                    Picker("Gender", selection: Binding(get: { gender }, set: { v in
                        gender = v
                        Task { await account.setGender(Gender(rawValue: v)) }
                    })) {
                        Text("Not given").tag("")
                        Text("Male").tag(Gender.male.rawValue)
                        Text("Female").tag(Gender.female.rawValue)
                        Text("Non-binary").tag(Gender.nonbinary.rawValue)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .tint(Theme.accent)
                }
                Text("Optional. Some languages use different forms for men and women.")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, Theme.Space.s)
            MalaSizeRows(value: model.preferences.malaSize, resetTo: Preferences.standardMalaSize,
                         resettable: model.preferences.malaSize != Preferences.standardMalaSize,
                         onChange: { v in model.update { $0.malaSize = v } },
                         onReset: { model.update { $0.malaSize = Preferences.standardMalaSize } })
            Toggle(isOn: Binding(
                get: { model.preferences.reminderMinutes != nil },
                set: { on in
                    model.update { $0.reminderMinutes = on ? 20 * 60 : nil }
                    if on { Task { await Reminders.requestAndSchedule(model) } }
                })) {
                Text("Evening reminder").foregroundStyle(Theme.ink)
            }
            .tint(Theme.accent)
            .padding(.vertical, Theme.Space.s)
            .frame(minHeight: Theme.Size.minTap)
            if let minutes = model.preferences.reminderMinutes {
                DatePicker(selection: Binding(
                    get: { Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date() },
                    set: { d in
                        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                        model.update { $0.reminderMinutes = (c.hour ?? 20) * 60 + (c.minute ?? 0) }
                    }), displayedComponents: .hourAndMinute) {
                    Text("Time").foregroundStyle(Theme.ink)
                }
                .tint(Theme.accent)
                .padding(.vertical, Theme.Space.s)
                .frame(minHeight: Theme.Size.minTap)
            }
            Toggle(isOn: Binding(
                get: { model.preferences.usualTimeNudge },
                set: { on in
                    model.update { $0.usualTimeNudge = on }
                    if on { Task { await Reminders.requestAndSchedule(model) } }
                })) {
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text("Nudge at my usual time").foregroundStyle(Theme.ink)
                    Text("An hour before you usually practise, learned on this phone from the last two weeks.")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                }
            }
            .tint(Theme.accent)
            .padding(.vertical, Theme.Space.s)
            Toggle(isOn: Binding(get: { model.preferences.discreetNotifications },
                                 set: { v in model.update { $0.discreetNotifications = v } })) {
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text("Discreet notifications").foregroundStyle(Theme.ink)
                    Text("Lock screens say \u{201C}A friend practised\u{201D} instead of the practice.")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                }
            }
            .tint(Theme.accent)
            .padding(.vertical, Theme.Space.s)
        }
    }

}

/// One practice's own settings: target, streak-only, mala override, archive.
struct PracticeSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: AccountModel
    @Environment(\.dismiss) private var dismiss
    let practiceID: String
    @State private var correcting = false

    var body: some View {
        if let p = model.snapshot.practices.first(where: { $0.id == practiceID }) {
            Form {
                Group {
                    // Design decision 34: where the count stands, and its correction.
                    if !p.streakOnly {
                        Section("Count") {
                            CountSummary(practice: p, sessions: model.snapshot.sessions(of: p.id))
                            Button { correcting = true } label: {
                                Text("Correct the count")
                                    .foregroundStyle(Theme.accent)
                                    .frame(maxWidth: .infinity, minHeight: Theme.Size.minTap, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Section {
                        if p.practice.isCustom {
                            TextField("Name", text: binding(p, \.practice.name))
                        } else {
                            PracticeName(practice: p.practice)
                        }
                    }
                    if account.status == .ready {
                        Section {
                            Toggle("Friends see this streak", isOn: Binding(
                                get: { model.snapshot.publicPractices.contains(p.id) },
                                set: { on in Task { await account.setPublic(p.id, on) } }))
                        } footer: {
                            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                                Text("Only the number of days practised in the app, never counts or totals.")
                                if let error = account.error { Text(verbatim: error).foregroundStyle(Theme.destructive) }
                            }
                        }
                    }
                    if p.practice.streakOnlyAllowed {
                        Section {
                            Toggle("Streak only, no count", isOn: binding(p, \.streakOnly))
                        } footer: {
                            Text("Counts logged so far are kept.")
                        }
                    }
                    if !p.streakOnly {
                        Section("Counting") {
                            NumberField(title: "Target per round",
                                        value: Binding(get: { p.practice.target ?? 0 },
                                                       set: { binding(p, \.practice.target).wrappedValue = $0 > 0 ? $0 : nil }))
                            // The practice's own size, or the default from General; typing
                            // sets its own, Reset goes back to the default.
                            MalaSizeRows(value: p.practice.effectiveMalaSize(default: model.preferences.malaSize),
                                         resetTo: model.preferences.malaSize, resettable: p.practice.malaSize != nil,
                                         onChange: { v in binding(p, \.practice.malaSize).wrappedValue = v },
                                         onReset: { binding(p, \.practice.malaSize).wrappedValue = nil })
                        }
                    }
                    Section {
                        Button(p.archived ? "Show on Today again" : "Archive") {
                            var q = p
                            q.archived.toggle()
                            model.save(q)
                            if q.archived { dismiss() }
                        }
                    } footer: {
                        Text("Archiving hides the practice from Today and keeps its counts and history.")
                    }
                }
                .themedRows()
            }
            .themedList()
            .numberPadDone()
            .navigationTitle(Text(verbatim: p.practice.shownName))
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $correcting) {
                CorrectCountSheet(practice: p, current: p.lifetime(sessions: model.snapshot.sessions(of: p.id)))
            }
        }
    }

    private func binding<T>(_ p: TrackedPractice, _ path: WritableKeyPath<TrackedPractice, T>) -> Binding<T> {
        Binding(get: { p[keyPath: path] }, set: { v in
            var q = p
            q[keyPath: path] = v
            if let t = q.practice.target, t <= 0 { q.practice.target = nil }
            model.save(TrackedPractice(practice: q.practice, streakOnly: q.streakOnly, openingCount: q.openingCount,
                                       archived: q.archived, sortOrder: q.sortOrder))
        })
    }
}

private struct ArchivedPracticesView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List(model.snapshot.practices.filter(\.archived)) { p in
            NavigationLink { PracticeSettingsView(practiceID: p.id) } label: { PracticeName(practice: p.practice) }
        }
        .navigationTitle("Archived")
    }
}

/// Add any built-in practice the path allows, or a custom one, at any time.
private struct AddPracticeView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var custom = false

    var body: some View {
        let prefs = model.preferences
        let tracked = Set(model.snapshot.practices.map(\.id))
        let options = Catalogue.available(finishedNgondro: prefs.finishedNgondro, finishedShortRefuge: prefs.finishedShortRefuge)
            .filter { !tracked.contains($0.id) }
        NavigationStack {
            List {
                ForEach(options) { p in
                    Button { add(TrackedPractice(practice: p, streakOnly: p.streakOnlyByDefault)) } label: {
                        PracticeName(practice: p)
                    }
                    .foregroundStyle(.primary)
                }
                Button { custom = true } label: { Label("Your own practice", systemImage: "plus") }
            }
            .navigationTitle("Add a practice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(isPresented: $custom) {
                CustomPracticeSheet { p, streakOnly in add(TrackedPractice(practice: p, streakOnly: streakOnly)) }
            }
        }
    }

    private func add(_ p: TrackedPractice) {
        var q = p
        q.sortOrder = (model.snapshot.practices.map(\.sortOrder).max() ?? -1) + 1
        model.save(q)
        dismiss()
    }
}

/// Settings › Language: System, then each language in its own name.
private struct LanguageView: View {
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system

    var body: some View {
        List {
            Section {
                ForEach(AppLanguage.allCases) { option in
                    Button { language = option } label: {
                        HStack {
                            if let name = option.spokenNativeName {
                                Text(name).foregroundStyle(Theme.ink)
                            } else {
                                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                                    Text("System").foregroundStyle(Theme.ink)
                                    Text("Follow the phone's language").font(.footnote).foregroundStyle(Theme.muted)
                                }
                            }
                            Spacer()
                            if option == language {
                                Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(option == language ? .isSelected : [])
                }
            }
            .themedRows()
        }
        .themedList()
        .navigationTitle("Language")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// "A mala counts as": one number field (1…10,000), and "Reset to N" below it
/// while the value can go back (General: anything but 108; a practice: while it
/// has its own size). A keystroke that leaves the range is not taken; an emptied
/// field changes nothing until a number is typed.
private struct MalaSizeRows: View {
    static let bounds = 1...10_000

    /// The number in effect (the practice's own, or the default).
    let value: Int
    /// What Reset goes back to.
    let resetTo: Int
    let resettable: Bool
    let onChange: (Int) -> Void
    let onReset: () -> Void
    @State private var text: String
    /// The last text the field took: a keystroke that leaves the range goes back to it.
    @State private var accepted: String

    init(value: Int, resetTo: Int, resettable: Bool, onChange: @escaping (Int) -> Void, onReset: @escaping () -> Void) {
        self.value = value
        self.resetTo = resetTo
        self.resettable = resettable
        self.onChange = onChange
        self.onReset = onReset
        _text = State(initialValue: String(value))
        _accepted = State(initialValue: String(value))
    }

    var body: some View {
        Group {
            // The field goes under the label when both do not fit on one line
            // ("Un mala compte pour"); it keeps a fixed width, so typing never
            // moves the row between its two layouts.
            FittingRow(spacing: Theme.Space.m) {
                Text("A mala counts as").foregroundStyle(Theme.ink)
            } control: {
                TextField(String(value), text: $text)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(minWidth: Theme.Size.numberField / 2, maxWidth: Theme.Size.numberField)
                    .accessibilityLabel(Text("A mala counts as"))
                    .onChange(of: text) { t in
                        let digits = t.filter { $0.isASCII && $0.isNumber }
                        if digits.isEmpty {
                            accepted = ""
                        } else if let n = Int(digits.prefix(6)), Self.bounds.contains(n) {
                            // Only a new number is saved: Reset sets `accepted` first,
                            // so its own text change saves nothing.
                            if String(n) != accepted {
                                accepted = String(n)
                                onChange(n)
                            }
                        }
                        if text != accepted { text = accepted }
                    }
            }
            .padding(.vertical, Theme.Space.s)
            .frame(minHeight: Theme.Size.minTap)
            if resettable {
                Button {
                    accepted = String(resetTo)
                    text = accepted
                    onReset()
                } label: {
                    Text("Reset to \(resetTo)")
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, minHeight: Theme.Size.minTap, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Settings › a practice › Count: the lifetime total, and with a target "of
/// 111,111 · round 1" beside it and the round's bar under it.
private struct CountSummary: View {
    let practice: TrackedPractice
    let sessions: [Session]

    var body: some View {
        let lifetime = practice.lifetime(sessions: sessions)
        let rounds = practice.rounds(sessions: sessions)
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(lifetime.grouped)
                    .font(Typography.headingBold(34, relativeTo: .largeTitle))
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let rounds, let target = practice.practice.target {
                    Text("of \(target.grouped) · round \(rounds.round)")
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let rounds, let target = practice.practice.target {
                Bar(fraction: Double(rounds.inRound) / Double(target), height: Theme.Size.barThick)
            }
        }
        .padding(.vertical, Theme.Space.s)
        .accessibilityElement(children: .combine)
    }
}

/// Correct the count (design decision 34): the count as it is now, typed as a
/// round and the count in it (or one number without a target). Save writes the
/// difference as a correction session, shown in History; there is no lower limit.
private struct CorrectCountSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let practice: TrackedPractice
    /// The lifetime total now.
    let current: Int
    @State private var round: Int
    @State private var inRound: Int

    init(practice: TrackedPractice, current: Int) {
        self.practice = practice
        self.current = current
        let start = CountCorrection.prefill(lifetime: current, target: practice.practice.target)
        _round = State(initialValue: start.round)
        _inRound = State(initialValue: start.inRound)
    }

    private var target: Int? { practice.practice.target.flatMap { $0 > 0 ? $0 : nil } }
    private var count: Int { CountCorrection.lifetime(round: round, inRound: inRound, target: target) }
    private var change: Int { count - current }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        PracticeName(practice: practice.practice)
                    }
                    Section {
                        if target != nil {
                            Stepper(value: $round, in: 1...9_999) {
                                HStack(spacing: Theme.Space.s) {
                                    Text("Round").foregroundStyle(Theme.ink)
                                    Spacer(minLength: Theme.Space.s)
                                    Text(round.grouped)
                                        .font(.body.weight(.semibold))
                                        .monospacedDigit()
                                }
                            }
                            NumberField(title: "Count in the round", value: $inRound)
                        } else {
                            NumberField(title: "Count now", value: $inRound)
                        }
                    }
                    Section {
                        HStack {
                            Text("Was").foregroundStyle(Theme.ink)
                            Spacer()
                            Text(current.grouped).foregroundStyle(Theme.muted).monospacedDigit()
                        }
                        HStack {
                            Text("Change").foregroundStyle(Theme.ink)
                            Spacer()
                            Text(change.signed).font(.body.weight(.semibold)).monospacedDigit()
                        }
                    } footer: {
                        Text("Saved in History as a correction.")
                    }
                }
                .themedRows()
            }
            .themedList()
            .numberPadDone()
            .navigationTitle("Correct the count")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.correct(practice.id, to: count)
                        dismiss()
                    }
                    .disabled(change == 0)
                }
            }
        }
    }
}

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
        .sheet(isPresented: $adding) { AddPracticeView() }
    }
}

/// A label on the left, an optional muted value and chevron on the right.
struct SettingsRow: View {
    let title: LocalizedStringKey
    var detail: Text?
    var chevron = false

    init(_ title: LocalizedStringKey, detail: Text? = nil, chevron: Bool = false) {
        self.title = title
        self.detail = detail
        self.chevron = chevron
    }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Text(title).foregroundStyle(Theme.ink)
            Spacer(minLength: Theme.Space.s)
            if let detail { detail.foregroundStyle(Theme.muted) }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Theme.muted)
                    .accessibilityHidden(true)
            }
        }
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

    var body: some View {
        CardSection(header: "General") {
            // Picked in the app itself, as in CodeShare, not by a trip to Settings.
            NavigationLink { LanguageView() } label: {
                SettingsRow("Language", detail: language.nativeName.map { Text(verbatim: $0) } ?? Text("System"), chevron: true)
            }
            MalaSizeRows(value: Binding(get: { model.preferences.malaSize },
                                        set: { v in model.update { $0.malaSize = v ?? 108 } }),
                         defaultSize: nil)
            Toggle(isOn: Binding(
                get: { model.preferences.reminderMinutes != nil },
                set: { on in
                    model.update { $0.reminderMinutes = on ? 20 * 60 : nil }
                    if on { Task { await Reminders.requestAndSchedule(model) } }
                })) {
                Text("Evening reminder").foregroundStyle(Theme.ink)
            }
            .tint(Theme.accent)
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

    var body: some View {
        if let p = model.snapshot.practices.first(where: { $0.id == practiceID }) {
            Form {
                Group {
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
                            MalaSizeRows(value: binding(p, \.practice.malaSize), defaultSize: model.preferences.malaSize)
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
            .navigationTitle(Text(verbatim: p.practice.shownName))
            .navigationBarTitleDisplayMode(.inline)
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
            } footer: {
                Text("Translations other than English are drafts awaiting review by practitioners. Practice names follow each country's practice books as they are collected.")
            }
            .themedRows()
        }
        .themedList()
        .navigationTitle("Language")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// "A mala counts as": 108, or a number the user types (Custom). With a
/// `defaultSize` (per practice) there is also "Default (N)", which is `nil`.
/// Any other stored value, such as the 100 an earlier version offered, shows as Custom.
private struct MalaSizeRows: View {
    static let bounds = 1...10_000

    private enum Choice: Hashable { case standard, custom, inherited }

    @Binding var value: Int?
    let defaultSize: Int?
    @State private var custom: Bool
    @State private var text: String
    /// The last text the field took: a keystroke that leaves the range goes back to it.
    @State private var accepted: String

    init(value: Binding<Int?>, defaultSize: Int?) {
        _value = value
        self.defaultSize = defaultSize
        let v = value.wrappedValue
        _custom = State(initialValue: v != nil && v != 108)
        _text = State(initialValue: v.map { String($0) } ?? "")
        _accepted = State(initialValue: v.map { String($0) } ?? "")
    }

    private var choice: Choice {
        if custom { return .custom }
        return value == nil ? .inherited : .standard
    }

    var body: some View {
        Group {
            HStack {
                Text("A mala counts as").foregroundStyle(Theme.ink)
                Spacer(minLength: Theme.Space.s)
                Picker("A mala counts as", selection: Binding(get: { choice }, set: choose)) {
                    if let d = defaultSize { Text("Default (\(d))").tag(Choice.inherited) }
                    Text(verbatim: "108").tag(Choice.standard)
                    Text("Custom…").tag(Choice.custom)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(Theme.accent)
            }
            .frame(minHeight: Theme.Size.minTap)
            if custom {
                HStack(spacing: Theme.Space.m) {
                    Text("Custom value").foregroundStyle(Theme.ink)
                    Spacer(minLength: Theme.Space.s)
                    TextField("108", text: $text)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: Theme.Size.numberField)
                        .accessibilityLabel(Text("Custom value"))
                        .onChange(of: text) { t in
                            // Digits only, and only a number in range is taken; anything
                            // else leaves the field as it was, so no hint is needed.
                            // Emptied, it picks nothing until retyped.
                            let digits = t.filter { $0.isASCII && $0.isNumber }
                            if digits.isEmpty {
                                accepted = ""
                            } else if let n = Int(digits.prefix(6)), Self.bounds.contains(n) {
                                accepted = String(n)
                                value = n
                            }
                            if text != accepted { text = accepted }
                        }
                }
                .frame(minHeight: Theme.Size.minTap)
            }
        }
    }

    private func choose(_ c: Choice) {
        switch c {
        case .inherited: custom = false; value = nil
        case .standard: custom = false; value = 108
        case .custom:
            custom = true
            if value == nil { value = defaultSize ?? 108 }
            text = String(value ?? 108)
            accepted = text
        }
    }
}

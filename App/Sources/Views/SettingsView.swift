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

    static let showsLanguage = false

    var body: some View {
        CardSection(header: "General") {
            // Hidden until the translations exist: only English works so far. When they
            // land, the language is picked in the app itself, as in CodeShare, not by a
            // trip to the system Settings app.
            if Self.showsLanguage {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                } label: {
                    SettingsRow("Language", detail: Text(verbatim: currentLanguage), chevron: true)
                }
            }
            HStack {
                Text("A mala counts as").foregroundStyle(Theme.ink)
                Spacer(minLength: Theme.Space.s)
                Picker("A mala counts as", selection: Binding(get: { model.preferences.malaSize },
                                                               set: { v in model.update { $0.malaSize = v } })) {
                    Text(verbatim: "100").tag(100)
                    Text(verbatim: "108").tag(108)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(Theme.accent)
            }
            .frame(minHeight: Theme.Size.minTap)
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

    /// The language in its own name, from the platform's CLDR data.
    private var currentLanguage: String {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale(identifier: code).localizedString(forLanguageCode: code)?.localizedCapitalized ?? code
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
                            Picker("A mala counts as", selection: binding(p, \.practice.malaSize)) {
                                Text("Default (\(model.preferences.malaSize))").tag(Int?.none)
                                Text(verbatim: "100").tag(Int?.some(100))
                                Text(verbatim: "108").tag(Int?.some(108))
                            }
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
            .navigationTitle(Text(p.practice.name))
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

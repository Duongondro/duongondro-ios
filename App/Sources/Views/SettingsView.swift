import SwiftUI
import DuongondroCore
import DuongondroStore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var adding = false

    var body: some View {
        List {
            Group {
                Section("Practices") {
                    ForEach(model.snapshot.activePractices) { p in
                        NavigationLink { PracticeSettingsView(practiceID: p.id) } label: { PracticeName(practice: p.practice) }
                    }
                    .onMove { from, to in
                        var ids = model.snapshot.activePractices.map(\.id)
                        ids.move(fromOffsets: from, toOffset: to)
                        model.perform { try $0.reorder(ids + model.snapshot.practices.filter(\.archived).map(\.id)) }
                    }
                    Button { adding = true } label: { Label("Add a practice", systemImage: "plus") }
                    let archived = model.snapshot.practices.filter(\.archived)
                    if !archived.isEmpty {
                        NavigationLink("Archived (\(archived.count))") { ArchivedPracticesView() }
                    }
                }
                GeneralSection()
                Section("Your data") {
                    NavigationLink("Export and delete") { YourDataView() }
                }
                AboutSection()
            }
            .themedRows()
        }
        .themedList()
        .navigationTitle("Settings")
        .toolbar { EditButton() }
        .sheet(isPresented: $adding) { AddPracticeView() }
    }
}

private struct GeneralSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section("General") {
            Button {
                // Per-app language lives in the system Settings app on iOS; switching
                // inside a running app is unreliable, so the app does not try.
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            } label: {
                LabeledContent("Language", value: currentLanguage)
            }
            .foregroundStyle(.primary)
            Picker("A mala counts as", selection: Binding(get: { model.preferences.malaSize },
                                                           set: { v in model.update { $0.malaSize = v } })) {
                Text(verbatim: "100").tag(100)
                Text(verbatim: "108").tag(108)
            }
            Toggle("Evening reminder", isOn: Binding(
                get: { model.preferences.reminderMinutes != nil },
                set: { on in
                    model.update { $0.reminderMinutes = on ? 20 * 60 : nil }
                    if on { Task { await Reminders.requestAndSchedule(model) } }
                }))
            if let minutes = model.preferences.reminderMinutes {
                DatePicker("Time", selection: Binding(
                    get: { Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date() },
                    set: { d in
                        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                        model.update { $0.reminderMinutes = (c.hour ?? 20) * 60 + (c.minute ?? 0) }
                    }), displayedComponents: .hourAndMinute)
            }
            Toggle(isOn: Binding(get: { model.preferences.discreetNotifications },
                                 set: { v in model.update { $0.discreetNotifications = v } })) {
                VStack(alignment: .leading) {
                    Text("Discreet notifications")
                    Text("Lock screens say \u{201C}A friend practised\u{201D} instead of the practice.")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                }
            }
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

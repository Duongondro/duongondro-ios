import Foundation
import DuongondroCore
import DuongondroStore

/// What the UI shows, published from the database, plus the in-memory state
/// that must never reach it early: the undo window.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot = Snapshot()
    /// The open undo window, at most one at a time.
    @Published private(set) var pending: PendingLog?
    /// A session just written whose estimated start fell before midnight.
    @Published var afterMidnight: AfterMidnightPrompt?
    /// Set when a read or write failed; shown in a banner.
    @Published private(set) var storageError: String?
    /// False when the file could not be opened and the app runs on an in-memory
    /// database: logging is blocked then, since nothing would survive a relaunch.
    @Published private(set) var persistent = true
    /// Bumped on returning to the foreground and at a new day (significant time
    /// change), so "today" and streaks re-render after a night in the background.
    @Published private(set) var clock = Date()

    /// The selected tab, so a screen can send the person to another.
    enum Tab: Hashable { case today, friends, you }
    @Published var tab = Tab.today

    let database: AppDatabase
    private var observation: SnapshotObservation?
    private var closeTask: Task<Void, Never>?

    init(database: AppDatabase) {
        self.database = database
        observation = database.observe(
            onError: { [weak self] error in self?.storageError = error.localizedDescription },
            onChange: { [weak self] snapshot in self?.snapshot = snapshot })
    }

    /// The app's database, or an in-memory one (and an error shown) if the file cannot be opened.
    static func live() -> AppModel {
        do {
            return AppModel(database: try AppDatabase.openOnDisk())
        } catch {
            let model = AppModel(database: try! AppDatabase.inMemory())
            model.persistent = false
            model.storageError = error.localizedDescription
            return model
        }
    }

    static func preview() -> AppModel {
        let db = try! AppDatabase.inMemory()
        var prefs = Preferences()
        prefs.onboarded = true
        prefs.finishedShortRefuge = true
        let ids = ["dorje-sempa", "mandala", "chenrezig"]
        let practices = ids.enumerated().map { i, id in
            TrackedPractice(practice: Catalogue.builtIn.first { $0.id == id }!, streakOnly: id == "chenrezig",
                            openingCount: id == "dorje-sempa" ? 4 * 111_111 + 35_000 : 0, sortOrder: i)
        }
        try? db.completeOnboarding(practices: practices, seeds: [], preferences: prefs)
        return AppModel(database: db)
    }

    var preferences: Preferences { snapshot.preferences }

    // MARK: - Derived

    func streak(of practiceID: String, now: Date = Date()) -> Streak.Result {
        Streak.of(practiceID: practiceID, sessions: snapshot.sessions(of: practiceID), seed: snapshot.seed(of: practiceID),
                  now: now, timeZone: .current)
    }

    func headline(now: Date = Date()) -> Streak.Result {
        Streak.headline(sessions: snapshot.sessions, seeds: snapshot.seeds, now: now, timeZone: .current)
    }

    func practisedToday(_ practiceID: String, now: Date = Date()) -> Bool {
        let today = CivilDate.of(now, in: .current)
        return snapshot.sessions(of: practiceID).contains { $0.day == today }
    }

    func malaSize(of p: TrackedPractice) -> Int { p.practice.effectiveMalaSize(default: preferences.malaSize) }

    // MARK: - Logging

    /// +mala, +custom amount or "done today" (0). Opens or extends the undo window;
    /// nothing is written until it closes.
    func add(_ amount: Int, to practiceID: String, at now: Date = Date()) {
        guard persistent else { return }
        if var p = pending, p.practiceID == practiceID {
            p.add(amount, at: now)
            pending = p
        } else {
            commitPending()
            pending = PendingLog(practiceID: practiceID, amount: amount, at: now)
        }
        scheduleClose()
    }

    /// Undo: the pending session vanishes without a trace.
    func undo() {
        closeTask?.cancel()
        pending = nil
    }

    /// Writes the pending session now: the window closed, another practice was
    /// logged, or the app is leaving the foreground.
    func commitPending(now: Date = Date()) {
        closeTask?.cancel()
        guard let p = pending else { return }
        pending = nil
        // Always estimated; the after-midnight sheet corrects a wrong day in one tap.
        let startedAt = SessionStart.estimate(loggedAt: p.startedAt, tappedStart: nil,
                                              timedSessionLengths: SessionStart.timedLengths(snapshot.sessions))
        let session = Session(practiceID: p.practiceID, amount: p.amount, startedAt: startedAt,
                              startExact: false, timeZoneID: TimeZone.current.identifier, loggedAt: p.startedAt)
        do {
            try database.insert(session)
            if let sheet = AfterMidnight.check(session) {
                afterMidnight = AfterMidnightPrompt(session: session, sheet: sheet)
            }
        } catch {
            storageError = error.localizedDescription
        }
    }

    func choose(day: CivilDate, for prompt: AfterMidnightPrompt) {
        let startDay = CivilDate.of(prompt.session.startedAt, in: prompt.session.timeZone)
        perform { try $0.choose(day: day == startDay ? nil : day, forSession: prompt.session.id) }
        afterMidnight = nil
    }

    private func scheduleClose() {
        closeTask?.cancel()
        guard let deadline = pending?.deadline else { return }
        closeTask = Task { [weak self] in
            let wait = deadline.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            self?.commitPending()
        }
    }

    /// Drops the undo window without writing anything.
    func discardInFlight() {
        closeTask?.cancel()
        pending = nil
        afterMidnight = nil
    }

    /// Re-renders date-dependent views and reschedules reminders.
    func tick(now: Date = Date()) {
        clock = now
        Reminders.reschedule(self, now: now)
    }

    func dismissStorageError() { storageError = nil }

    // MARK: - Practices and preferences

    func save(_ p: TrackedPractice) { perform { try $0.save(p) } }

    func update(_ change: (inout Preferences) -> Void) {
        var prefs = preferences
        change(&prefs)
        perform { try $0.save(prefs) }
    }

    func perform(_ write: (AppDatabase) throws -> Void) {
        do { try write(database) } catch { storageError = error.localizedDescription }
    }
}

struct AfterMidnightPrompt: Identifiable {
    let session: Session
    let sheet: AfterMidnight
    var id: UUID { session.id }
}

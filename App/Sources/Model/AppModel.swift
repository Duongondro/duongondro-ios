import Foundation
import DuongondroCore
import DuongondroStore
import DuongondroSync

/// What the UI shows, published from the database, plus the undo window. A
/// session in its window is already in the database, pending (counted on
/// screen, never synced); the window itself, its deadline and Undo, lives here.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot = Snapshot()
    /// The open undo window, at most one at a time; its session is in the database, pending.
    @Published private(set) var pending: PendingLog?
    /// A session just made final whose estimated start fell before midnight.
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
        resumeWindows()
    }

    /// The app's database, or an in-memory one (and an error shown) if the file cannot be opened.
    static func live() -> AppModel {
        do {
            let database = try AppDatabase.openOnDisk()
            // A database file made just now means a first launch or a reinstall:
            // the Keychain outlives an uninstall, so a session token in it belongs
            // to an earlier install, and AccountModel must not open that account.
            // Only the token goes; keys stay for the same account to resume with
            // (Account.forgetEarlierInstall). Delete everything clears them itself.
            if database.createdFile { try? Account.forgetEarlierInstall(KeychainStore()) }
            return AppModel(database: database)
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
        return Session.practised(snapshot.sessions(of: practiceID), on: today)
    }

    func malaSize(of p: TrackedPractice) -> Int { p.practice.effectiveMalaSize(default: preferences.malaSize) }

    // MARK: - Logging

    /// +mala, +custom amount or "done today" (0). Opens or extends the undo window.
    /// The session is written at once, pending, so every number includes it and a
    /// crash cannot lose it; it is not synced until the window closes.
    func add(_ amount: Int, to practiceID: String, at now: Date = Date()) {
        guard persistent else { return }
        var next: PendingLog
        if let p = pending, p.practiceID == practiceID {
            next = p
            next.add(amount, at: now)
        } else {
            finalisePending(now: now)
            next = PendingLog(practiceID: practiceID, amount: amount, at: now)
        }
        pending = next
        // Always estimated; the after-midnight sheet corrects a wrong day in one tap.
        let session = next.session(timeZone: .current, timedSessionLengths: SessionStart.timedLengths(snapshot.sessions))
        perform { try $0.savePending(session, until: next.deadline, now: now) }
        scheduleClose()
    }

    /// Correct the count (design decision 34): the person typed the total as it is
    /// now, and the difference is saved as a correction session, final at once (no
    /// undo window) and synced like any other. An open undo window closes first, so
    /// the difference is taken from what stays.
    func correct(_ practiceID: String, to count: Int, at now: Date = Date()) {
        guard persistent else { return }
        finalisePending(now: now)
        guard let practice = snapshot.practices.first(where: { $0.id == practiceID }) else { return }
        let change = practice.correction(to: count, sessions: snapshot.sessions(of: practiceID))
        guard change != 0 else { return }
        perform { try $0.insert(Session.countCorrection(practiceID: practiceID, change: change, at: now, timeZone: .current)) }
    }

    /// Undo: the pending row is deleted outright; it never left the phone.
    func undo() {
        closeTask?.cancel()
        guard let p = pending else { return }
        pending = nil
        perform { try $0.discardPending(p.sessionID) }
    }

    /// Ends the undo window now: it closed, another practice was logged, or the
    /// app is leaving the foreground. The session becomes final and syncs.
    func finalisePending(now: Date = Date()) {
        closeTask?.cancel()
        guard let p = pending else { return }
        pending = nil
        do {
            if let session = try database.finalise(p.sessionID, now: now) { offerAfterMidnight(session) }
        } catch {
            storageError = error.localizedDescription
        }
    }

    /// On launch: a pending row whose window passed while the app was gone (a
    /// crash, or the system ending the process) becomes final now; one still
    /// inside its window gets its Undo back for the seconds left.
    private func resumeWindows(now: Date = Date()) {
        guard persistent else { return }
        do {
            // One sheet at a time: the latest finalised session that asks for one.
            if let s = try database.finaliseDue(at: now).sorted(by: { $0.loggedAt > $1.loggedAt })
                .first(where: { AfterMidnight.check($0) != nil }) { offerAfterMidnight(s) }
            let snap = try database.snapshot()
            let open = snap.sessions.filter { snap.pending[$0.id] != nil }.sorted { $0.loggedAt < $1.loggedAt }
            // At most one window: any older one closes now.
            for s in open.dropLast() { try database.finalise(s.id, now: now) }
            if let s = open.last, let deadline = snap.pending[s.id] {
                pending = PendingLog(practiceID: s.practiceID, amount: s.amount, startedAt: s.loggedAt,
                                     deadline: deadline, sessionID: s.id)
                scheduleClose()
            }
        } catch {
            storageError = error.localizedDescription
        }
    }

    private func offerAfterMidnight(_ session: Session) {
        if let sheet = AfterMidnight.check(session) {
            afterMidnight = AfterMidnightPrompt(session: session, sheet: sheet)
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
            self?.finalisePending()
        }
    }

    /// Drops the undo window without finalising it (the purge erases its row with everything else).
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

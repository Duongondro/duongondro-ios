import Foundation
import GRDB
import DuongondroCore

/// The local SQLite database (GRDB), as in CodeShare: schema migrations and
/// every write. Works fully offline; local mode never needs anything else.
///
/// Holds no state besides the connection; the app observes `snapshotObservation`
/// and publishes what the UI shows.
public final class AppDatabase: @unchecked Sendable {  // the generation counter is lock-protected
    /// A DatabasePool on disk, a DatabaseQueue in tests and previews.
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    // MARK: - Opening

    /// The folder holding the database and its WAL files. Excluded from device
    /// backups: without Advanced Data Protection those are not end-to-end
    /// encrypted, and the file holds plaintext counts (design: Offline mode).
    public static func folderURL(fileManager: FileManager = .default) throws -> URL {
        var folder = try fileManager
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Database", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        return folder
    }

    public static func openOnDisk() throws -> AppDatabase {
        try open(path: folderURL().appendingPathComponent("duongondro.sqlite").path)
    }

    /// A DatabasePool at `path`; tests use it to exercise the on-disk paths.
    public static func open(path: String) throws -> AppDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(2)
        return try AppDatabase(DatabasePool(path: path, configuration: config))
    }

    public static func inMemory() throws -> AppDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try AppDatabase(DatabaseQueue(configuration: config))
    }

    // MARK: - Schema

    /// Plain SQL migrations, applied in order, each once. Never edit a migration
    /// that has shipped to a phone: add a new one.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if targetEnvironment(simulator)
        // Only in the Simulator: a changed schema during development starts over.
        migrator.eraseDatabaseOnSchemaChange = true
        #endif
        migrator.registerMigration("v1") { db in
            // `dirty` marks rows changed here since the server last acknowledged them;
            // every row starts dirty, so a local-mode user who signs up later pushes
            // everything once (the CodeShare rule).
            try db.execute(sql: """
                CREATE TABLE practices (
                    id                  TEXT PRIMARY KEY NOT NULL,
                    name                TEXT NOT NULL,
                    second_name         TEXT,
                    grp                 TEXT NOT NULL,
                    target              INTEGER,
                    streak_only_allowed INTEGER NOT NULL,
                    streak_only         INTEGER NOT NULL DEFAULT 0,
                    mala_size           INTEGER,
                    is_custom           INTEGER NOT NULL DEFAULT 0,
                    opening_count       INTEGER NOT NULL DEFAULT 0,
                    archived            INTEGER NOT NULL DEFAULT 0,
                    sort_order          INTEGER NOT NULL DEFAULT 0,
                    dirty               INTEGER NOT NULL DEFAULT 1
                );
                CREATE TABLE sessions (
                    id          TEXT PRIMARY KEY NOT NULL,
                    practice_id TEXT NOT NULL REFERENCES practices (id) ON DELETE CASCADE,
                    amount      INTEGER NOT NULL CHECK (amount >= 0),
                    started_at  DATETIME NOT NULL,
                    start_exact INTEGER NOT NULL,
                    time_zone   TEXT NOT NULL,
                    chosen_day  TEXT,
                    logged_at   DATETIME NOT NULL,
                    dirty       INTEGER NOT NULL DEFAULT 1
                );
                CREATE INDEX sessions_practice ON sessions (practice_id, started_at);
                -- Private onboarding seeds: never published, never invented sessions.
                CREATE TABLE streak_seeds (
                    practice_id TEXT PRIMARY KEY NOT NULL REFERENCES practices (id) ON DELETE CASCADE,
                    days        INTEGER NOT NULL,
                    longest     INTEGER,
                    last_day    TEXT NOT NULL,
                    time_zone   TEXT NOT NULL,
                    dirty       INTEGER NOT NULL DEFAULT 1
                );
                -- One row: Preferences as JSON.
                CREATE TABLE preferences (
                    id   INTEGER PRIMARY KEY CHECK (id = 1),
                    json TEXT NOT NULL
                );
                """)
        }
        migrator.registerMigration("v2") { db in
            // Sync: last write wins on the client clock, so every session carries
            // when it last changed, and a deletion is a mark (a sealed tombstone on
            // the server), never a missing row. Rows from v1 changed when logged.
            try db.execute(sql: """
                ALTER TABLE sessions ADD COLUMN updated_at DATETIME;
                UPDATE sessions SET updated_at = logged_at;
                ALTER TABLE sessions ADD COLUMN deleted_at DATETIME;
                -- One row once an account exists: who, which practice-key version
                -- this device holds, and how far the last sync read.
                CREATE TABLE sync_state (
                    id          INTEGER PRIMARY KEY CHECK (id = 1),
                    user_id     TEXT NOT NULL,
                    key_version INTEGER NOT NULL,
                    cursor      TEXT
                );
                """)
        }
        migrator.registerMigration("v3") { db in
            // Phase 4. Friends as this phone pinned them: the identity key each
            // friend's streaks must verify against, kept from the first time it was
            // seen (an invite's checked key, or the server's word), so a later key
            // swap by the server shows instead of passing silently.
            try db.execute(sql: """
                CREATE TABLE friends (
                    user_id      TEXT PRIMARY KEY NOT NULL,
                    identity_pk  BLOB NOT NULL,
                    display_name TEXT NOT NULL,
                    pinned_at    DATETIME NOT NULL
                );
                -- Practices whose streak is published to friends, and the last
                -- statement's seq (the server takes only higher ones).
                CREATE TABLE public_streaks (
                    practice_id TEXT PRIMARY KEY NOT NULL REFERENCES practices (id) ON DELETE CASCADE,
                    seq         INTEGER NOT NULL DEFAULT 0
                );
                """)
        }
        migrator.registerMigration("v4") { db in
            // Review of phase 4: a pin outlives the server's list (`listed` 0 once
            // dropped; only the person's own unfriend or block forgets it), so a
            // friend dropped and listed again under another key shows as a changed
            // key; and the highest streak seq seen per friend and practice, so the
            // server cannot replay an older, validly signed statement.
            try db.execute(sql: """
                ALTER TABLE friends ADD COLUMN listed INTEGER NOT NULL DEFAULT 1;
                CREATE TABLE friend_seqs (
                    user_id  TEXT NOT NULL,
                    practice TEXT NOT NULL,
                    seq      INTEGER NOT NULL,
                    PRIMARY KEY (user_id, practice)
                );
                """)
        }
        return migrator
    }

    // MARK: - Reading

    public static func snapshotObservation() -> ValueObservation<ValueReducers.Fetch<Snapshot>> {
        ValueObservation.tracking { try fetchSnapshot($0) }
    }

    public static func fetchSnapshot(_ db: Database) throws -> Snapshot {
        let practices = try Row.fetchAll(db, sql: "SELECT * FROM practices ORDER BY sort_order, id").map(TrackedPractice.init(row:))
        let sessions = try Row.fetchAll(db, sql: "SELECT * FROM sessions WHERE deleted_at IS NULL ORDER BY started_at, id").map(Session.init(row:))
        let seeds = try Row.fetchAll(db, sql: "SELECT * FROM streak_seeds ORDER BY practice_id").map(StreakSeed.init(row:))
        var preferences = Preferences()
        if let json = try String.fetchOne(db, sql: "SELECT json FROM preferences WHERE id = 1"),
           let decoded = try? JSONDecoder().decode(Preferences.self, from: Data(json.utf8)) {
            preferences = decoded
        }
        // Someone with practices has been through onboarding, whatever the preferences
        // row says: an update must never send them back to Welcome, where finishing
        // again would overwrite their opening counts and streak seeds.
        if !practices.isEmpty { preferences.onboarded = true }
        let publicPractices = Set(try String.fetchAll(db, sql: "SELECT practice_id FROM public_streaks"))
        return Snapshot(practices: practices, sessions: sessions, seeds: seeds, preferences: preferences,
                        publicPractices: publicPractices)
    }

    /// Calls `onChange` with a fresh snapshot now and after every write, on the
    /// main queue. Observation stops when the returned handle is released.
    public func observe(onError: @escaping @MainActor (Error) -> Void,
                        onChange: @escaping @MainActor (Snapshot) -> Void) -> SnapshotObservation {
        SnapshotObservation(Self.snapshotObservation().start(
            in: writer, scheduling: .immediate,
            onError: { error in MainActor.assumeIsolated { onError(error) } },
            onChange: { snapshot in MainActor.assumeIsolated { onChange(snapshot) } }))
    }

    public func snapshot() throws -> Snapshot {
        try writer.read { try Self.fetchSnapshot($0) }
    }

    // MARK: - Writing

    /// Inserts or updates a tracked practice.
    public func save(_ p: TrackedPractice) throws {
        try writer.write { db in try Self.upsert(p, db) }
    }

    /// Moves practices into the given order (ids not listed keep theirs).
    public func reorder(_ ids: [String]) throws {
        try writer.write { db in
            for (i, id) in ids.enumerated() {
                try db.execute(sql: "UPDATE practices SET sort_order = ?, dirty = 1 WHERE id = ?", arguments: [i, id])
            }
        }
    }

    /// Writes a session. Called only when the undo window has closed.
    public func insert(_ s: Session) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, practice_id, amount, started_at, start_exact, time_zone, chosen_day, logged_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [s.id.uuidString.lowercased(), s.practiceID, s.amount, s.startedAt, s.startExact,
                                 s.timeZoneID, s.chosenDay?.description, s.loggedAt, s.loggedAt])
        }
    }

    /// The after-midnight switch: count `id` for `day` instead (nil: its start's own date).
    public func choose(day: CivilDate?, forSession id: UUID) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE sessions SET chosen_day = ?, updated_at = ?, dirty = 1 WHERE id = ?",
                           arguments: [day?.description, try Self.nextStamp(for: id, db), id.uuidString.lowercased()])
        }
    }

    public func save(_ seed: StreakSeed) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO streak_seeds (practice_id, days, longest, last_day, time_zone) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (practice_id) DO UPDATE SET
                    days = excluded.days, longest = excluded.longest, last_day = excluded.last_day,
                    time_zone = excluded.time_zone, dirty = 1
                """, arguments: [seed.practiceID, seed.days, seed.longest, seed.lastDay.description, seed.timeZoneID])
        }
    }

    public func save(_ preferences: Preferences) throws {
        let json = String(decoding: try JSONEncoder().encode(preferences), as: UTF8.self)
        try writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO preferences (id, json) VALUES (1, ?)", arguments: [json])
        }
    }

    /// Onboarding's result in one transaction: practices, seeds and preferences.
    public func completeOnboarding(practices: [TrackedPractice], seeds: [StreakSeed], preferences: Preferences) throws {
        let json = String(decoding: try JSONEncoder().encode(preferences), as: UTF8.self)
        try writer.write { db in
            for p in practices { try Self.upsert(p, db) }
            for s in seeds {
                try db.execute(sql: "INSERT OR REPLACE INTO streak_seeds (practice_id, days, longest, last_day, time_zone) VALUES (?, ?, ?, ?, ?)",
                               arguments: [s.practiceID, s.days, s.longest, s.lastDay.description, s.timeZoneID])
            }
            try db.execute(sql: "INSERT OR REPLACE INTO preferences (id, json) VALUES (1, ?)", arguments: [json])
        }
    }

    /// Deletes every row: "Delete everything" and its local half. Then VACUUM
    /// rewrites the file and the WAL is truncated, so deleted rows do not linger
    /// in free pages.
    public func eraseAll() throws {
        generationLock.withLock { generationValue += 1 }
        try writer.write { db in
            try db.execute(sql: "DELETE FROM sessions; DELETE FROM streak_seeds; DELETE FROM practices; DELETE FROM preferences; DELETE FROM sync_state; DELETE FROM friends; DELETE FROM friend_seqs; DELETE FROM public_streaks;")
        }
        try writer.vacuum()
        if let pool = writer as? DatabasePool {
            // The busy timeout lets a reader (the snapshot observation) finish.
            // Should it still be busy, the rows are already deleted and SQLite's
            // automatic checkpoint folds the WAL in later, so the purge goes on.
            _ = try? pool.writeWithoutTransaction { try $0.checkpoint(.truncate) }
        }
    }

    // MARK: - Friends and public streaks

    /// Makes a practice's streak public or private here; publishing is the caller's.
    public func setPublic(_ practiceID: String, _ isPublic: Bool) throws {
        try writer.write { db in
            if isPublic {
                try db.execute(sql: "INSERT OR IGNORE INTO public_streaks (practice_id) VALUES (?)", arguments: [practiceID])
            } else {
                try db.execute(sql: "DELETE FROM public_streaks WHERE practice_id = ?", arguments: [practiceID])
            }
        }
    }

    /// Public practices and the seq of the last statement published for each.
    public func publicStreakSeqs() throws -> [String: Int64] {
        try writer.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT practice_id, seq FROM public_streaks").map {
                ($0["practice_id"] as String, $0["seq"] as Int64)
            })
        }
    }

    public func savePublishedSeq(_ practiceID: String, _ seq: Int64, generation: Int? = nil) throws {
        try write(generation) { db in
            try db.execute(sql: "UPDATE public_streaks SET seq = MAX(seq, ?) WHERE practice_id = ?", arguments: [seq, practiceID])
        }
    }

    public func friends() throws -> [PinnedFriend] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM friends ORDER BY display_name, user_id").map {
                PinnedFriend(userID: UUID(uuidString: $0["user_id"]) ?? UUID(), identityPublicKey: $0["identity_pk"],
                             displayName: $0["display_name"], pinnedAt: $0["pinned_at"], listed: $0["listed"])
            }
        }
    }

    /// Pins a friend's key if none is pinned yet (the first key seen is the one
    /// kept), updates the name, and returns the pinned record.
    @discardableResult
    public func pin(_ userID: UUID, identityPublicKey: Data, displayName: String, at now: Date = Date(),
                    generation: Int? = nil) throws -> PinnedFriend {
        try write(generation) { db in
            let id = userID.uuidString.lowercased()
            try db.execute(sql: """
                INSERT INTO friends (user_id, identity_pk, display_name, pinned_at) VALUES (?, ?, ?, ?)
                ON CONFLICT (user_id) DO UPDATE SET display_name = excluded.display_name, listed = 1
                """, arguments: [id, identityPublicKey, displayName, now])
            let row = try Row.fetchOne(db, sql: "SELECT * FROM friends WHERE user_id = ?", arguments: [id])!
            return PinnedFriend(userID: userID, identityPublicKey: row["identity_pk"], displayName: row["display_name"],
                                pinnedAt: row["pinned_at"], listed: row["listed"])
        }
    }

    /// Pins a key that was verified (an invite's pin MAC checked it): it replaces
    /// whatever was pinned on the server's word, and clears a changed key.
    public func repin(_ userID: UUID, identityPublicKey: Data, displayName: String, at now: Date = Date(),
                      generation: Int? = nil) throws {
        try write(generation) { db in
            try db.execute(sql: """
                INSERT INTO friends (user_id, identity_pk, display_name, pinned_at) VALUES (?, ?, ?, ?)
                ON CONFLICT (user_id) DO UPDATE SET identity_pk = excluded.identity_pk,
                    display_name = CASE WHEN excluded.display_name = '' THEN friends.display_name ELSE excluded.display_name END,
                    pinned_at = excluded.pinned_at, listed = 1
                """, arguments: [userID.uuidString.lowercased(), identityPublicKey, displayName, now])
        }
    }

    /// Forgets a friend for good: only on the person's own unfriend or block.
    public func forgetFriend(_ userID: UUID) throws {
        try writer.write { db in
            let id = userID.uuidString.lowercased()
            try db.execute(sql: "DELETE FROM friends WHERE user_id = ?; DELETE FROM friend_seqs WHERE user_id = ?",
                           arguments: [id, id])
        }
    }

    /// The highest streak seq seen from a friend for a practice (0 if none).
    public func seenSeq(_ userID: UUID, practice: String) throws -> Int64 {
        try writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT seq FROM friend_seqs WHERE user_id = ? AND practice = ?",
                               arguments: [userID.uuidString.lowercased(), practice]) ?? 0
        }
    }

    public func noteSeq(_ userID: UUID, practice: String, seq: Int64, generation: Int? = nil) throws {
        try write(generation) { db in
            try db.execute(sql: """
                INSERT INTO friend_seqs (user_id, practice, seq) VALUES (?, ?, ?)
                ON CONFLICT (user_id, practice) DO UPDATE SET seq = MAX(seq, excluded.seq)
                """, arguments: [userID.uuidString.lowercased(), practice, seq])
        }
    }

    /// Marks pinned friends the server no longer lists as unlisted, keeping the
    /// pin: a server that drops someone and lists them again under another key
    /// must not get that key pinned as a first sight.
    public func keepFriends(_ userIDs: Set<UUID>, generation: Int? = nil) throws {
        try write(generation) { db in
            for f in try String.fetchAll(db, sql: "SELECT user_id FROM friends") {
                let listed = userIDs.contains(UUID(uuidString: f) ?? UUID())
                try db.execute(sql: "UPDATE friends SET listed = ? WHERE user_id = ?", arguments: [listed, f])
            }
        }
    }

    /// Adds practices the server publishes for this account to the public set
    /// (another phone, or a restore, made them public), with the server's seq.
    public func mergePublished(_ seqs: [String: Int64], generation: Int? = nil) throws {
        try write(generation) { db in
            for (practice, seq) in seqs where try Int.fetchOne(db, sql: "SELECT 1 FROM practices WHERE id = ?", arguments: [practice]) != nil {
                try db.execute(sql: """
                    INSERT INTO public_streaks (practice_id, seq) VALUES (?, ?)
                    ON CONFLICT (practice_id) DO UPDATE SET seq = MAX(seq, excluded.seq)
                    """, arguments: [practice, seq])
            }
        }
    }

    public func isPublic(_ practiceID: String) throws -> Bool {
        try writer.read { try Int.fetchOne($0, sql: "SELECT 1 FROM public_streaks WHERE practice_id = ?", arguments: [practiceID]) != nil }
    }

    // MARK: - Sync

    /// The account this phone syncs with, once there is one.
    public func syncState() throws -> SyncState? {
        try writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM sync_state WHERE id = 1").map {
                SyncState(userID: UUID(uuidString: $0["user_id"]) ?? UUID(), keyVersion: $0["key_version"], cursor: $0["cursor"])
            }
        }
    }

    public func saveSyncState(_ state: SyncState, generation: Int? = nil) throws {
        try write(generation) { db in
            try db.execute(sql: "INSERT OR REPLACE INTO sync_state (id, user_id, key_version, cursor) VALUES (1, ?, ?, ?)",
                           arguments: [state.userID.uuidString.lowercased(), state.keyVersion, state.cursor])
        }
    }

    /// Sessions changed here since the server last acknowledged them, deletions included.
    public func dirtySessions() throws -> [SyncRecord] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM sessions WHERE dirty = 1 ORDER BY updated_at, id").map(SyncRecord.init(row:))
        }
    }

    /// Marks a session synced, unless it changed again after `updatedAt` was read.
    public func markSynced(_ id: UUID, updatedAt: Date, generation: Int? = nil) throws {
        try write(generation) { db in
            try db.execute(sql: "UPDATE sessions SET dirty = 0 WHERE id = ? AND updated_at = ?",
                           arguments: [id.uuidString.lowercased(), updatedAt])
        }
    }

    /// Gives every session whose id is not a UUIDv7 (logged by builds before sync,
    /// which used version 4) a new v7 id from its logging time. Safe because such a
    /// session never reached the server, which accepts only v7; nothing else refers
    /// to a session's id. Returns how many were re-keyed.
    @discardableResult
    public func rekeyLegacySessionIDs() throws -> Int {
        try writer.write { db in
            var n = 0
            for row in try Row.fetchAll(db, sql: "SELECT id, logged_at FROM sessions") {
                guard let id = UUID(uuidString: row["id"]), !id.isV7 else { continue }
                let loggedAt: Date = row["logged_at"]
                try db.execute(sql: "UPDATE sessions SET id = ?, dirty = 1 WHERE id = ?",
                               arguments: [UUID.v7(at: loggedAt).uuidString.lowercased(), id.uuidString.lowercased()])
                n += 1
            }
            return n
        }
    }

    /// Marks every session dirty: after a key rotation or a server restore, everything is pushed again.
    public func markAllDirty() throws {
        try writer.write { db in try db.execute(sql: "UPDATE sessions SET dirty = 1") }
    }

    /// Deletes a session as a mark, so the deletion syncs.
    public func delete(session id: UUID, at now: Date = Date()) throws {
        try writer.write { db in
            let stamp = try Self.nextStamp(for: id, db, now: now)
            try db.execute(sql: "UPDATE sessions SET deleted_at = ?, updated_at = ?, dirty = 1 WHERE id = ?",
                           arguments: [stamp, stamp, id.uuidString.lowercased()])
        }
    }

    /// A change's time: now, but always after the row's last change, so a local
    /// edit made after pulling a newer remote one (or after the clock moved back)
    /// still wins under last-write-wins.
    /// Sync compares times to the millisecond, the precision sealed and sent.
    static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    static func nextStamp(for id: UUID, _ db: Database, now: Date = Date()) throws -> Date {
        let last = try Date.fetchOne(db, sql: "SELECT updated_at FROM sessions WHERE id = ?", arguments: [id.uuidString.lowercased()])
        guard let last, last >= now else { return now }
        return last.addingTimeInterval(0.001)
    }

    /// Bumped by `eraseAll`: a sync that started before an erase (or a sign-out)
    /// checks it before every write, so it never writes the old account back.
    public var generation: Int { generationLock.withLock { generationValue } }
    private let generationLock = NSLock()
    private var generationValue = 0

    /// Thrown by a write that names a generation `eraseAll` has since ended.
    public struct Erased: Error { public init() {} }

    /// A write that runs only if no erase happened since `generation` was read.
    /// The check is inside the transaction, so an erase cannot slip in between.
    func write<T>(_ generation: Int?, _ body: (Database) throws -> T) throws -> T {
        try writer.write { db in
            if let generation, generation != self.generation { throw Erased() }
            return try body(db)
        }
    }

    /// Applies a deletion from the server that carries no content (a tombstone
    /// may omit everything but its times): marks the session deleted if the
    /// deletion is newer. Returns whether anything changed.
    @discardableResult
    public func applyRemoteDeletion(_ id: UUID, updatedAt: Date, deletedAt: Date, generation: Int? = nil) throws -> Bool {
        try write(generation) { db in
            let key = id.uuidString.lowercased()
            guard let local = try Date.fetchOne(db, sql: "SELECT updated_at FROM sessions WHERE id = ?", arguments: [key]),
                  Self.millis(local) < Self.millis(updatedAt) else { return false }
            try db.execute(sql: "UPDATE sessions SET deleted_at = ?, updated_at = ?, dirty = 0 WHERE id = ?",
                           arguments: [deletedAt, updatedAt, key])
            return true
        }
    }

    /// Applies a session from the server: the newer write wins (a local change made
    /// later stays and is pushed); a practice this phone does not track yet is
    /// added, from the catalogue or as a custom practice with the session's name.
    /// Returns whether anything changed.
    @discardableResult
    public func applyRemote(_ r: SyncRecord, practiceName: String? = nil, generation: Int? = nil) throws -> Bool {
        try write(generation) { db in
            let id = r.session.id.uuidString.lowercased()
            let local = try Date.fetchOne(db, sql: "SELECT updated_at FROM sessions WHERE id = ?", arguments: [id])
            if let local, Self.millis(local) >= Self.millis(r.updatedAt) { return false }
            // A deletion of a session this phone never had changes nothing here.
            if local == nil, r.deletedAt != nil { return false }
            if try Int.fetchOne(db, sql: "SELECT 1 FROM practices WHERE id = ?", arguments: [r.session.practiceID]) == nil {
                let order = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sort_order) + 1, 0) FROM practices") ?? 0
                let practice = Catalogue.builtIn.first { $0.id == r.session.practiceID }
                    ?? Practice(id: r.session.practiceID, name: practiceName ?? r.session.practiceID, group: .anyTime,
                                target: nil, streakOnlyAllowed: true, isCustom: true)
                try Self.upsert(TrackedPractice(practice: practice, streakOnly: practice.streakOnlyByDefault, sortOrder: order), db)
            }
            let s = r.session
            try db.execute(sql: """
                INSERT INTO sessions (id, practice_id, amount, started_at, start_exact, time_zone, chosen_day,
                                      logged_at, updated_at, deleted_at, dirty)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
                ON CONFLICT (id) DO UPDATE SET
                    practice_id = excluded.practice_id, amount = excluded.amount, started_at = excluded.started_at,
                    start_exact = excluded.start_exact, time_zone = excluded.time_zone, chosen_day = excluded.chosen_day,
                    logged_at = excluded.logged_at, updated_at = excluded.updated_at, deleted_at = excluded.deleted_at,
                    dirty = 0
                """, arguments: [id, s.practiceID, s.amount, s.startedAt, s.startExact, s.timeZoneID,
                                 s.chosenDay?.description, s.loggedAt, r.updatedAt, r.deletedAt])
            return true
        }
    }

    static func upsert(_ p: TrackedPractice, _ db: Database) throws {
        let q = p.practice
        try db.execute(sql: """
            INSERT INTO practices (id, name, second_name, grp, target, streak_only_allowed, streak_only,
                                   mala_size, is_custom, opening_count, archived, sort_order)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (id) DO UPDATE SET
                name = excluded.name, second_name = excluded.second_name, grp = excluded.grp,
                target = excluded.target, streak_only_allowed = excluded.streak_only_allowed,
                streak_only = excluded.streak_only, mala_size = excluded.mala_size,
                is_custom = excluded.is_custom, opening_count = excluded.opening_count,
                archived = excluded.archived, sort_order = excluded.sort_order, dirty = 1
            """, arguments: [q.id, q.name, q.secondName, q.group.rawValue, q.target, q.streakOnlyAllowed, p.streakOnly,
                             q.malaSize, q.isCustom, p.openingCount, p.archived, p.sortOrder])
    }
}

/// Keeps a snapshot observation alive; the app needs no GRDB import to hold it.
public final class SnapshotObservation {
    private let cancellable: AnyDatabaseCancellable
    init(_ cancellable: AnyDatabaseCancellable) { self.cancellable = cancellable }
    public func cancel() { cancellable.cancel() }
}

/// Everything the UI shows, read in one transaction.
public struct Snapshot: Equatable, Sendable {
    public var practices: [TrackedPractice]
    public var sessions: [Session]
    public var seeds: [StreakSeed]
    public var preferences: Preferences
    /// Practices whose streak friends see.
    public var publicPractices: Set<String>

    public init(practices: [TrackedPractice] = [], sessions: [Session] = [], seeds: [StreakSeed] = [],
                preferences: Preferences = Preferences(), publicPractices: Set<String> = []) {
        self.practices = practices
        self.sessions = sessions
        self.seeds = seeds
        self.preferences = preferences
        self.publicPractices = publicPractices
    }

    public var activePractices: [TrackedPractice] { practices.filter { !$0.archived } }

    public func sessions(of practiceID: String) -> [Session] { sessions.filter { $0.practiceID == practiceID } }

    public func seed(of practiceID: String) -> StreakSeed? { seeds.first { $0.practiceID == practiceID } }
}

/// Settings kept on the phone. Never synced as plaintext.
public struct Preferences: Codable, Equatable, Sendable {
    public var onboarded = false
    public var finishedShortRefuge = false
    public var finishedNgondro = false
    /// Whether one mala counts as 100 or 108; each practice can override it.
    public var malaSize = 108
    /// Minutes after local midnight for the streak-at-risk reminder; nil for none.
    public var reminderMinutes: Int?
    /// Lock screens show "A friend practised" instead of practice names.
    public var discreetNotifications = false
    /// "Shouldn't you be meditating?" an hour before the usual time of each practice.
    public var usualTimeNudge = false

    public init() {}

    // Every key is optional when reading, so a preferences row written by an older
    // or newer version still decodes: a missing key keeps its default, an unknown
    // one is ignored. Synthesised decoding would fail on any added field instead.
    enum CodingKeys: String, CodingKey {
        case onboarded, finishedShortRefuge, finishedNgondro, malaSize, reminderMinutes, discreetNotifications
        case usualTimeNudge
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        onboarded = try c.decodeIfPresent(Bool.self, forKey: .onboarded) ?? d.onboarded
        finishedShortRefuge = try c.decodeIfPresent(Bool.self, forKey: .finishedShortRefuge) ?? d.finishedShortRefuge
        finishedNgondro = try c.decodeIfPresent(Bool.self, forKey: .finishedNgondro) ?? d.finishedNgondro
        malaSize = try c.decodeIfPresent(Int.self, forKey: .malaSize) ?? d.malaSize
        reminderMinutes = try c.decodeIfPresent(Int.self, forKey: .reminderMinutes) ?? d.reminderMinutes
        discreetNotifications = try c.decodeIfPresent(Bool.self, forKey: .discreetNotifications) ?? d.discreetNotifications
        usualTimeNudge = try c.decodeIfPresent(Bool.self, forKey: .usualTimeNudge) ?? d.usualTimeNudge
    }
}

// MARK: - Rows

extension TrackedPractice {
    init(row: Row) {
        var practice = Practice(id: row["id"], name: row["name"], secondName: row["second_name"],
                                group: PracticeGroup(rawValue: row["grp"]) ?? .anyTime, target: row["target"],
                                streakOnlyAllowed: row["streak_only_allowed"], malaSize: row["mala_size"],
                                isCustom: row["is_custom"])
        // A built-in practice shows the catalogue's current name, second line, group
        // and whether it may be streak-only, so a change in an update reaches everyone
        // who already tracks it. The target, mala size and streak-only choice stay the
        // user's (a choice the practice no longer allows simply stops applying).
        if !practice.isCustom, let current = Catalogue.builtIn.first(where: { $0.id == practice.id }) {
            practice.name = current.name
            practice.secondName = current.secondName
            practice.group = current.group
            practice.streakOnlyAllowed = current.streakOnlyAllowed
        }
        self.init(practice: practice, streakOnly: row["streak_only"], openingCount: row["opening_count"],
                  archived: row["archived"], sortOrder: row["sort_order"])
    }
}

extension Session {
    init(row: Row) {
        let chosen: String? = row["chosen_day"]
        self.init(id: UUID(uuidString: row["id"]) ?? UUID(), practiceID: row["practice_id"], amount: row["amount"],
                  startedAt: row["started_at"], startExact: row["start_exact"], timeZoneID: row["time_zone"],
                  chosenDay: chosen.flatMap(CivilDate.init), loggedAt: row["logged_at"])
    }
}

extension StreakSeed {
    init(row: Row) {
        let lastDay: String = row["last_day"]
        self.init(practiceID: row["practice_id"], days: row["days"], longest: row["longest"],
                  lastDay: CivilDate(lastDay) ?? CivilDate(year: 1970, month: 1, day: 1), timeZoneID: row["time_zone"])
    }
}

// MARK: - Sync records

/// The account a phone syncs with: the user, the practice-key version it holds,
/// and the cursor of its last read (`<generation>:<xid8>`).
public struct SyncState: Equatable, Sendable {
    public var userID: UUID
    public var keyVersion: Int
    public var cursor: String?

    public init(userID: UUID, keyVersion: Int, cursor: String? = nil) {
        self.userID = userID
        self.keyVersion = keyVersion
        self.cursor = cursor
    }
}

/// A friend as this phone pinned them.
public struct PinnedFriend: Equatable, Sendable {
    public var userID: UUID
    public var identityPublicKey: Data
    public var displayName: String
    public var pinnedAt: Date
    public var listed = true
}

/// A session as sync sees it: its content, when it last changed, and whether it is deleted.
public struct SyncRecord: Equatable, Sendable {
    public var session: Session
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(session: Session, updatedAt: Date, deletedAt: Date? = nil) {
        self.session = session
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    init(row: Row) {
        let session = Session(row: row)
        self.init(session: session, updatedAt: row["updated_at"] ?? session.loggedAt, deletedAt: row["deleted_at"])
    }
}

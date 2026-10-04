import XCTest
import GRDB
import DuongondroCore
@testable import DuongondroStore

/// Data on a phone must survive every update. These tests open a database exactly as
/// the first TestFlight build (schema v1) left it and check that nothing is lost.
///
/// FROZEN: `v1Database` is what version 0.1 writes. Never edit it to make a test
/// pass; a schema change adds a migration, and this file proves it upgrades v1.
final class UpgradeTests: XCTestCase {
    static let v1Database = """
        CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
        INSERT INTO grdb_migrations VALUES ('v1');
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
        CREATE TABLE streak_seeds (
            practice_id TEXT PRIMARY KEY NOT NULL REFERENCES practices (id) ON DELETE CASCADE,
            days        INTEGER NOT NULL,
            longest     INTEGER,
            last_day    TEXT NOT NULL,
            time_zone   TEXT NOT NULL,
            dirty       INTEGER NOT NULL DEFAULT 1
        );
        CREATE TABLE preferences (
            id   INTEGER PRIMARY KEY CHECK (id = 1),
            json TEXT NOT NULL
        );
        INSERT INTO practices (id, name, second_name, grp, target, streak_only_allowed, streak_only, mala_size,
                               is_custom, opening_count, archived, sort_order)
        VALUES ('dorje-sempa', 'Dorje Sempa', 'Diamond Mind', 'ngondro', 111111, 0, 0, NULL, 0, 35556, 0, 0),
               ('8th-karmapa', 'Meditation on the 8th Karmapa', NULL, 'afterNgondro', NULL, 1, 1, NULL, 0, 0, 0, 1),
               ('custom-1', 'Evening Chenrezig', NULL, 'anyTime', 5000, 1, 0, 100, 1, 12, 0, 2),
               ('mandala', 'Mandala offering', NULL, 'ngondro', 100000, 0, 0, 100, 0, 7, 1, 3);
        INSERT INTO sessions (id, practice_id, amount, started_at, start_exact, time_zone, chosen_day, logged_at)
        VALUES ('0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b', 'dorje-sempa', 108, '2026-10-04 19:30:00.000', 0,
                'Europe/Amsterdam', NULL, '2026-10-04 20:30:00.000'),
               ('0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5c', 'dorje-sempa', 216, '2026-10-04 21:50:00.000', 1,
                'Europe/Amsterdam', '2026-10-04', '2026-10-04 22:20:00.000'),
               ('0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5d', '8th-karmapa', 0, '2026-10-04 06:00:00.000', 1,
                'Asia/Tokyo', NULL, '2026-10-04 06:40:00.000');
        INSERT INTO streak_seeds (practice_id, days, longest, last_day, time_zone)
        VALUES ('dorje-sempa', 41, 120, '2026-10-03', 'Europe/Amsterdam');
        INSERT INTO preferences (id, json)
        VALUES (1, '{"onboarded":true,"finishedShortRefuge":true,"finishedNgondro":false,"malaSize":100,"reminderMinutes":1230,"discreetNotifications":false}');
        """

    func openV1(preferencesJSON: String? = nil) throws -> AppDatabase {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("v1-\(UUID().uuidString).sqlite").path
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: Self.v1Database)
            if let preferencesJSON {
                try db.execute(sql: "UPDATE preferences SET json = ?", arguments: [preferencesJSON])
            }
        }
        try queue.close()
        return try AppDatabase.open(path: path)
    }

    func testEveryRowOfAV1DatabaseSurvives() throws {
        let snap = try openV1().snapshot()
        XCTAssertEqual(snap.practices.map(\.id), ["dorje-sempa", "8th-karmapa", "custom-1", "mandala"])
        // Sessions come back in order of their start.
        XCTAssertEqual(snap.sessions.map(\.amount), [0, 108, 216])
        XCTAssertEqual(snap.sessions[0].timeZoneID, "Asia/Tokyo")
        XCTAssertNil(snap.sessions[1].chosenDay)
        XCTAssertEqual(snap.sessions[2].chosenDay, CivilDate("2026-10-04"))
        XCTAssertTrue(snap.sessions[2].startExact)
        XCTAssertEqual(snap.seeds.first?.days, 41)
        XCTAssertEqual(snap.seeds.first?.longest, 120)

        let ds = snap.practices[0]
        XCTAssertEqual(ds.openingCount, 35_556)
        XCTAssertEqual(ds.lifetime(sessions: snap.sessions), 35_556 + 108 + 216)
        let custom = snap.practices[2]
        XCTAssertTrue(custom.practice.isCustom)
        XCTAssertEqual(custom.practice.name, "Evening Chenrezig")
        XCTAssertEqual(custom.practice.target, 5_000)
        XCTAssertEqual(custom.practice.malaSize, 100)
        let mandala = snap.practices[3]
        XCTAssertTrue(mandala.archived)
        XCTAssertEqual(mandala.practice.target, 100_000, "a target the user changed stays theirs")
        XCTAssertEqual(mandala.practice.malaSize, 100)

        XCTAssertTrue(snap.preferences.onboarded)
        XCTAssertTrue(snap.preferences.finishedShortRefuge)
        XCTAssertEqual(snap.preferences.malaSize, 100)
        XCTAssertEqual(snap.preferences.reminderMinutes, 1230)
    }

    func testBuiltInPracticesShowTheirCurrentNames() throws {
        let snap = try openV1().snapshot()
        XCTAssertEqual(snap.practices[1].practice.name, "8th Karmapa Meditation")
        XCTAssertTrue(snap.practices[1].streakOnly, "the user's streak-only choice stays")
    }

    func testPreferencesWithMissingOrUnknownKeysStillDecode() throws {
        let snap = try openV1(preferencesJSON: #"{"onboarded":true,"malaSize":100,"aFieldFromTheFuture":[1,2]}"#).snapshot()
        XCTAssertTrue(snap.preferences.onboarded)
        XCTAssertEqual(snap.preferences.malaSize, 100)
        XCTAssertNil(snap.preferences.reminderMinutes)
    }

    func testUnreadablePreferencesNeverSendSomeoneBackToOnboarding() throws {
        let snap = try openV1(preferencesJSON: "not json").snapshot()
        XCTAssertTrue(snap.preferences.onboarded, "practices exist, so onboarding is done")
        XCTAssertEqual(snap.sessions.count, 3)
    }
}

/// Sync bookkeeping (migration v2) on top of the v1 data.
final class SyncStoreTests: XCTestCase {
    func db() throws -> AppDatabase { try AppDatabase.inMemory() }

    func session(_ practice: String = "dorje-sempa", at t: Date) -> Session {
        Session(practiceID: practice, amount: 108, startedAt: t, startExact: true, timeZoneID: "Europe/Amsterdam", loggedAt: t)
    }

    func testV1RowsGetAnUpdateTimeAndStayDirty() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("v1s-\(UUID().uuidString).sqlite").path
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        let queue = try DatabaseQueue(path: path)
        try queue.write { try $0.execute(sql: UpgradeTests.v1Database) }
        try queue.close()
        let db = try AppDatabase.open(path: path)
        let dirty = try db.dirtySessions()
        XCTAssertEqual(dirty.count, 3, "every v1 session is pushed once an account exists")
        for r in dirty { XCTAssertEqual(r.updatedAt, r.session.loggedAt) }
        XCTAssertNil(try db.syncState())
    }

    func testPushedSessionsAreMarkedSyncedUnlessChangedSince() throws {
        let db = try db()
        try db.save(TrackedPractice(practice: Catalogue.builtIn.first { $0.id == "dorje-sempa" }!, sortOrder: 0))
        let s = session(at: Date(timeIntervalSince1970: 1_790_000_000))
        try db.insert(s)
        let pushed = try XCTUnwrap(db.dirtySessions().first)
        try db.choose(day: CivilDate("2026-01-01"), forSession: s.id)   // changes after the push read it
        try db.markSynced(s.id, updatedAt: pushed.updatedAt)
        XCTAssertEqual(try db.dirtySessions().count, 1, "the later change still has to go")
        let again = try XCTUnwrap(db.dirtySessions().first)
        try db.markSynced(s.id, updatedAt: again.updatedAt)
        XCTAssertTrue(try db.dirtySessions().isEmpty)
    }

    func testRemoteSessionsLastWriteWinsAndAddTheirPractice() throws {
        let db = try db()
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        let remote = SyncRecord(session: session("chenrezig", at: t), updatedAt: t)
        XCTAssertTrue(try db.applyRemote(remote))
        var snap = try db.snapshot()
        XCTAssertEqual(snap.practices.map(\.id), ["chenrezig"], "the practice comes from the catalogue")
        XCTAssertEqual(snap.sessions.count, 1)
        XCTAssertTrue(try db.dirtySessions().isEmpty, "what came from the server is not pushed back")

        // An older write loses; a newer one wins; a deletion is a newer write.
        var older = remote
        older.session.amount = 1
        older.updatedAt = t.addingTimeInterval(-60)
        XCTAssertFalse(try db.applyRemote(older))
        var deleted = remote
        deleted.updatedAt = t.addingTimeInterval(60)
        deleted.deletedAt = deleted.updatedAt
        XCTAssertTrue(try db.applyRemote(deleted))
        snap = try db.snapshot()
        XCTAssertTrue(snap.sessions.isEmpty)

        let custom = SyncRecord(session: session("custom-x", at: t), updatedAt: t)
        try db.applyRemote(custom, practiceName: "Evening Chenrezig")
        let practice = try XCTUnwrap(db.snapshot().practices.first { $0.id == "custom-x" })
        XCTAssertEqual(practice.practice.name, "Evening Chenrezig")
        XCTAssertTrue(practice.practice.isCustom)
    }

    func testLocalDeletionSyncs() throws {
        let db = try db()
        try db.save(TrackedPractice(practice: Catalogue.builtIn.first { $0.id == "dorje-sempa" }!, sortOrder: 0))
        let s = session(at: Date(timeIntervalSince1970: 1_790_000_000))
        try db.insert(s)
        try db.markSynced(s.id, updatedAt: try XCTUnwrap(db.dirtySessions().first).updatedAt)
        try db.delete(session: s.id)
        let tombstone = try XCTUnwrap(db.dirtySessions().first)
        XCTAssertNotNil(tombstone.deletedAt)
        XCTAssertTrue(try db.snapshot().sessions.isEmpty)
    }

    func testALocalEditAfterTheClockWentBackStillWins() throws {
        let db = try db()
        try db.save(TrackedPractice(practice: Catalogue.builtIn.first { $0.id == "dorje-sempa" }!, sortOrder: 0))
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        let s = session(at: t)
        // A newer write from another phone arrives, then this phone's clock is behind it.
        var remote = SyncRecord(session: s, updatedAt: t.addingTimeInterval(3600))
        remote.session.amount = 216
        XCTAssertTrue(try db.applyRemote(remote))
        try db.delete(session: s.id, at: t)
        let local = try XCTUnwrap(db.dirtySessions().first)
        XCTAssertGreaterThan(local.updatedAt, remote.updatedAt, "the later edit must not lose to the earlier one")
    }

    func testTombstonesForUnknownSessionsChangeNothing() throws {
        let db = try db()
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        let gone = SyncRecord(session: session("chenrezig", at: t), updatedAt: t, deletedAt: t)
        XCTAssertFalse(try db.applyRemote(gone))
        XCTAssertFalse(try db.applyRemoteDeletion(UUID.v7(at: t), updatedAt: t, deletedAt: t))
        XCTAssertTrue(try db.snapshot().practices.isEmpty, "a deletion does not add its practice")
    }

    func testBareRemoteDeletionMarksANewerDeletion() throws {
        let db = try db()
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        let s = session("chenrezig", at: t)
        try db.applyRemote(SyncRecord(session: s, updatedAt: t))
        XCTAssertFalse(try db.applyRemoteDeletion(s.id, updatedAt: t, deletedAt: t), "not newer")
        XCTAssertTrue(try db.applyRemoteDeletion(s.id, updatedAt: t.addingTimeInterval(1), deletedAt: t.addingTimeInterval(1)))
        XCTAssertTrue(try db.snapshot().sessions.isEmpty)
        XCTAssertTrue(try db.dirtySessions().isEmpty)
    }

    func testWritesFromBeforeAnEraseAreRefused() throws {
        let db = try db()
        let generation = db.generation
        try db.eraseAll()
        let state = SyncState(userID: UUID(), keyVersion: 1)
        XCTAssertThrowsError(try db.saveSyncState(state, generation: generation))
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertThrowsError(try db.applyRemote(SyncRecord(session: session(at: t), updatedAt: t), generation: generation))
        XCTAssertNil(try db.syncState())
        XCTAssertNoThrow(try db.saveSyncState(state, generation: db.generation))
    }

    func testSyncStateRoundTrips() throws {
        let db = try db()
        let state = SyncState(userID: UUID(), keyVersion: 2, cursor: "abc:123")
        try db.saveSyncState(state)
        XCTAssertEqual(try db.syncState(), state)
        try db.eraseAll()
        XCTAssertNil(try db.syncState())
    }
}

final class SessionIDTests: XCTestCase {
    func testNewSessionsGetV7IdsFromTheirLoggingTime() {
        let t = Date(timeIntervalSince1970: 1_791_180_000.123)
        let s = Session(practiceID: "x", amount: 1, startedAt: t, startExact: true, timeZoneID: "UTC", loggedAt: t)
        XCTAssertTrue(s.id.isV7)
        let ms = s.id.uuid
        let stamp = [ms.0, ms.1, ms.2, ms.3, ms.4, ms.5].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        XCTAssertEqual(stamp, 1_791_180_000_123)
        XCTAssertFalse(UUID().isV7)
    }

    func testLegacyV4SessionsAreRekeyedBeforeTheirFirstPush() throws {
        let db = try AppDatabase.inMemory()
        try db.save(TrackedPractice(practice: Catalogue.builtIn.first { $0.id == "dorje-sempa" }!, sortOrder: 0))
        let t = Date(timeIntervalSince1970: 1_791_180_000)
        let legacy = Session(id: UUID(), practiceID: "dorje-sempa", amount: 108, startedAt: t, startExact: true,
                             timeZoneID: "UTC", loggedAt: t)
        let modern = Session(practiceID: "dorje-sempa", amount: 216, startedAt: t, startExact: true, timeZoneID: "UTC", loggedAt: t)
        try db.insert(legacy)
        try db.insert(modern)
        XCTAssertEqual(try db.rekeyLegacySessionIDs(), 1)
        let ids = try db.snapshot().sessions.map(\.id)
        XCTAssertTrue(ids.allSatisfy(\.isV7))
        XCTAssertTrue(ids.contains(modern.id), "a v7 id is kept")
        XCTAssertEqual(try db.snapshot().sessions.map(\.amount).sorted(), [108, 216])
        XCTAssertEqual(try db.rekeyLegacySessionIDs(), 0)
    }
}

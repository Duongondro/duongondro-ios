import XCTest
import GRDB
import DuongondroCore
@testable import DuongondroStore

/// Duongondro/duongondro-android#5: a session in its undo window is in the
/// database at once, pending; it counts on screen, never syncs, and Undo deletes
/// it. A pending row outlives a crash and becomes final on launch.
final class PendingSessionTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    let zone = TimeZone(identifier: "Europe/Warsaw")!

    func database() throws -> AppDatabase {
        let db = try AppDatabase.inMemory()
        try db.save(TrackedPractice(practice: Catalogue.builtIn.first { $0.id == "dorje-sempa" }!))
        return db
    }

    func window(_ amount: Int = 108, at t: Date? = nil) -> PendingLog {
        PendingLog(practiceID: "dorje-sempa", amount: amount, at: t ?? t0)
    }

    func save(_ w: PendingLog, _ db: AppDatabase) throws {
        try db.savePending(w.session(timeZone: zone, timedSessionLengths: []), until: w.deadline, now: w.startedAt)
    }

    func rows(_ db: AppDatabase) throws -> Int {
        try db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sessions") ?? 0 }
    }

    func testAPendingSessionCountsButNeverSyncsUntilFinal() throws {
        let db = try database()
        let w = window()
        try save(w, db)
        var snap = try db.snapshot()
        XCTAssertEqual(snap.practices[0].lifetime(sessions: snap.sessions), 108, "counted at once")
        XCTAssertEqual(snap.pending.keys.map { $0 }, [w.sessionID])
        XCTAssertEqual(try db.dirtySessions(), [], "never pushed while pending")
        XCTAssertEqual(snap.withoutPending.sessions, [], "never in a public streak or the export while pending")
        try db.markAllDirty()
        XCTAssertEqual(try db.dirtySessions(), [], "not even after a server restore")
        try db.clearSyncState()
        XCTAssertEqual(try db.dirtySessions(), [], "nor after signing out")

        let final = try db.finalise(w.sessionID, now: t0.addingTimeInterval(5))
        XCTAssertEqual(final?.amount, 108)
        snap = try db.snapshot()
        XCTAssertTrue(snap.pending.isEmpty)
        XCTAssertEqual(try db.dirtySessions().map(\.session.id), [w.sessionID])
        XCTAssertEqual(snap.withoutPending.sessions.map(\.id), [w.sessionID])
        XCTAssertNil(try db.finalise(w.sessionID), "finalising twice changes nothing")
    }

    func testExtendingTheWindowUpdatesTheSameRow() throws {
        let db = try database()
        var w = window()
        try save(w, db)
        w.add(108, at: t0.addingTimeInterval(3))
        try save(w, db)
        let snap = try db.snapshot()
        XCTAssertEqual(snap.sessions.map(\.amount), [216])
        XCTAssertEqual(snap.pending[w.sessionID].map(AppDatabase.millis), AppDatabase.millis(w.deadline))
    }

    func testUndoDeletesThePendingRowOutright() throws {
        let db = try database()
        let w = window()
        try save(w, db)
        try db.discardPending(w.sessionID)
        XCTAssertEqual(try db.snapshot().sessions, [])
        XCTAssertEqual(try rows(db), 0, "no tombstone either")
        XCTAssertEqual(try db.dirtySessions(), [])
    }

    func testAFinalSessionIsNeitherUndoneNorReopened() throws {
        let db = try database()
        var w = window()
        try save(w, db)
        try db.finalise(w.sessionID)
        try db.discardPending(w.sessionID)
        w.add(108, at: t0.addingTimeInterval(1))
        try save(w, db)
        let snap = try db.snapshot()
        XCTAssertEqual(snap.sessions.map(\.amount), [108])
        XCTAssertTrue(snap.pending.isEmpty)
    }

    func testARestartFinalisesWhatItsWindowLeftBehind() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("pending-\(UUID()).sqlite").path
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }
        let gone = window(108, at: t0)
        let open = window(216, at: t0.addingTimeInterval(10))
        do {
            let db = try AppDatabase.open(path: path)
            try db.save(TrackedPractice(practice: Catalogue.builtIn.first { $0.id == "dorje-sempa" }!))
            try save(gone, db)
            try save(open, db)
            // The process dies here.
        }
        let db = try AppDatabase.open(path: path)
        XCTAssertEqual(try db.snapshot().pending.count, 2)
        XCTAssertEqual(try db.finaliseDue(at: t0.addingTimeInterval(12)).map(\.id), [gone.sessionID])
        let snap = try db.snapshot()
        XCTAssertEqual(Set(snap.sessions.map(\.amount)), [108, 216], "the tap is kept")
        XCTAssertEqual(try db.dirtySessions().map(\.session.id), [gone.sessionID])
        XCTAssertEqual(Set(snap.pending.keys), [open.sessionID])
        XCTAssertEqual(try db.finaliseDue(at: t0.addingTimeInterval(-3600)).map(\.id), [open.sessionID],
                       "a clock moved back cannot hold it")
        XCTAssertTrue(try db.snapshot().pending.isEmpty)
    }

    func testTheExportHoldsFinalSessionsOnly() throws {
        let db = try database()
        let kept = window(108, at: t0)
        try save(kept, db)
        try db.finalise(kept.sessionID)
        let open = window(1_000, at: t0.addingTimeInterval(60))
        try save(open, db)
        let json = String(decoding: try DataExport.practiceJSON(try db.snapshot(), appVersion: "test", now: t0), as: UTF8.self)
        XCTAssertTrue(json.contains(kept.sessionID.uuidString.lowercased()))
        XCTAssertFalse(json.contains(open.sessionID.uuidString.lowercased()))
    }

    func testARemoteCopyNeverOverwritesAPendingRow() throws {
        let db = try database()
        let w = window()
        try save(w, db)
        var remote = w.session(timeZone: zone, timedSessionLengths: [])
        remote.amount = 999
        XCTAssertFalse(try db.applyRemote(SyncRecord(session: remote, updatedAt: t0.addingTimeInterval(3600))))
        XCTAssertFalse(try db.applyRemoteDeletion(w.sessionID, updatedAt: t0.addingTimeInterval(3600), deletedAt: t0.addingTimeInterval(3600)))
        let snap = try db.snapshot()
        XCTAssertEqual(snap.sessions.map(\.amount), [108])
        XCTAssertEqual(Set(snap.pending.keys), [w.sessionID])
    }

    func testDeletingAPendingSessionLeavesNoMarkToSync() throws {
        let db = try database()
        let w = window()
        try save(w, db)
        try db.delete(session: w.sessionID, at: t0.addingTimeInterval(1))
        XCTAssertEqual(try db.snapshot().sessions.map(\.id), [w.sessionID], "still pending, not marked deleted")
        try db.finalise(w.sessionID)
        XCTAssertEqual(try db.dirtySessions().map(\.deletedAt), [nil])
    }

    /// Migration v5 on a database as v4 left it: every session from before is
    /// final, still pushed when dirty, and untouched by the launch's finalisation.
    func testAV4DatabaseKeepsEverySessionFinal() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v4")
        let synced = UUID.v7(at: t0), dirty = UUID.v7(at: t0.addingTimeInterval(1))
        try queue.write { db in
            try db.execute(sql: "INSERT INTO practices (id, name, grp, target, streak_only_allowed) VALUES ('dorje-sempa', 'Dorje Sempa', 'ngondro', 111111, 0)")
            for (id, flag) in [(synced, 0), (dirty, 1)] {
                try db.execute(sql: """
                    INSERT INTO sessions (id, practice_id, amount, started_at, start_exact, time_zone, logged_at, updated_at, dirty)
                    VALUES (?, 'dorje-sempa', 108, ?, 0, 'Europe/Warsaw', ?, ?, ?)
                    """, arguments: [id.uuidString.lowercased(), t0, t0, t0, flag])
            }
            try db.execute(sql: "INSERT INTO public_streaks VALUES ('dorje-sempa', 4)")
        }
        let db = try AppDatabase(queue)
        let snap = try db.snapshot()
        XCTAssertEqual(Set(snap.sessions.map(\.id)), [synced, dirty])
        XCTAssertTrue(snap.pending.isEmpty)
        XCTAssertEqual(try db.dirtySessions().map(\.session.id), [dirty])
        XCTAssertEqual(try db.publicStreakSeqs(), ["dorje-sempa": 4])
        XCTAssertEqual(try db.finaliseDue(at: t0), [])
    }
}

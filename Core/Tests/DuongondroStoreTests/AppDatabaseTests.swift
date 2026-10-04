import XCTest
import DuongondroCore
@testable import DuongondroStore

final class AppDatabaseTests: XCTestCase {
    let ams = "Europe/Amsterdam"

    func practice(_ id: String) -> Practice { Catalogue.builtIn.first { $0.id == id }! }

    func testRoundTrip() throws {
        let db = try AppDatabase.inMemory()
        var prefs = Preferences()
        prefs.onboarded = true
        prefs.malaSize = 100
        let ds = TrackedPractice(practice: practice("dorje-sempa"), openingCount: 1_000, sortOrder: 0)
        let ch = TrackedPractice(practice: practice("chenrezig"), streakOnly: true, sortOrder: 1)
        let seed = StreakSeed(practiceID: "dorje-sempa", days: 12, longest: 30, lastDay: CivilDate("2026-10-03")!, timeZoneID: ams)
        try db.completeOnboarding(practices: [ch, ds], seeds: [seed], preferences: prefs)

        let t = Date(timeIntervalSince1970: 1_790_000_000)
        let s = Session(practiceID: "dorje-sempa", amount: 108, startedAt: t, startExact: false, timeZoneID: ams, loggedAt: t.addingTimeInterval(3600))
        try db.insert(s)
        try db.choose(day: CivilDate("2026-10-05"), forSession: s.id)

        let snap = try db.snapshot()
        XCTAssertEqual(snap.practices.map(\.id), ["dorje-sempa", "chenrezig"])
        XCTAssertEqual(snap.practices[0].openingCount, 1_000)
        XCTAssertTrue(snap.practices[1].streakOnly)
        XCTAssertEqual(snap.seeds, [seed])
        XCTAssertEqual(snap.preferences, prefs)
        XCTAssertEqual(snap.sessions.count, 1)
        XCTAssertEqual(snap.sessions[0].id, s.id)
        XCTAssertEqual(snap.sessions[0].amount, 108)
        XCTAssertEqual(snap.sessions[0].chosenDay, CivilDate("2026-10-05"))
        XCTAssertEqual(snap.sessions[0].startedAt.timeIntervalSince1970, t.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(snap.practices[0].lifetime(sessions: snap.sessions), 1_108)
    }

    func testArchiveKeepsHistory() throws {
        let db = try AppDatabase.inMemory()
        var ds = TrackedPractice(practice: practice("dorje-sempa"))
        try db.save(ds)
        try db.insert(Session(practiceID: ds.id, amount: 108, startedAt: .now, startExact: true, timeZoneID: ams, loggedAt: .now))
        ds.archived = true
        try db.save(ds)
        let snap = try db.snapshot()
        XCTAssertTrue(snap.activePractices.isEmpty)
        XCTAssertEqual(snap.sessions(of: ds.id).count, 1)
    }

    func testSessionNeedsItsPractice() throws {
        let db = try AppDatabase.inMemory()
        XCTAssertThrowsError(try db.insert(Session(practiceID: "nope", amount: 1, startedAt: .now, startExact: true, timeZoneID: ams, loggedAt: .now)))
    }

    func testEraseAll() throws {
        let db = try AppDatabase.inMemory()
        try db.completeOnboarding(practices: [TrackedPractice(practice: practice("mandala"))],
                                  seeds: [StreakSeed(practiceID: "mandala", days: 1, lastDay: CivilDate("2026-10-03")!, timeZoneID: ams)],
                                  preferences: Preferences())
        try db.insert(Session(practiceID: "mandala", amount: 1, startedAt: .now, startExact: true, timeZoneID: ams, loggedAt: .now))
        try db.eraseAll()
        XCTAssertEqual(try db.snapshot(), Snapshot())
    }

    /// The on-disk pool, with an observation running as in the app: erasing
    /// succeeds and leaves no rows behind in the file or its WAL.
    func testEraseAllOnDiskWithObserver() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("t.sqlite").path
        let db = try AppDatabase.open(path: path)
        try db.save(TrackedPractice(practice: practice("mandala")))
        try db.insert(Session(practiceID: "mandala", amount: 777_001, startedAt: .now, startExact: true, timeZoneID: ams, loggedAt: .now))
        let seen = expectation(description: "observed")
        seen.assertForOverFulfill = false
        let cancellable = AppDatabase.snapshotObservation().start(in: db.writer, onError: { _ in }, onChange: { _ in seen.fulfill() })
        wait(for: [seen], timeout: 2)
        try db.eraseAll()
        XCTAssertEqual(try db.snapshot(), Snapshot())
        cancellable.cancel()
        for suffix in ["", "-wal"] {
            let bytes = (try? Data(contentsOf: URL(fileURLWithPath: path + suffix))) ?? Data()
            XCTAssertNil(bytes.range(of: Data("mandala".utf8)), "no trace in \(suffix.isEmpty ? "file" : suffix)")
        }
    }
}

import XCTest
import GRDB
import DuongondroCore
@testable import DuongondroStore

final class DataExportTests: XCTestCase {
    let ams = "Europe/Amsterdam"

    func sample() throws -> AppDatabase {
        let db = try AppDatabase.inMemory()
        var prefs = Preferences()
        prefs.onboarded = true
        let ds = TrackedPractice(practice: Catalogue.builtIn.first { $0.id == "dorje-sempa" }!, openingCount: 500)
        try db.completeOnboarding(practices: [ds],
                                  seeds: [StreakSeed(practiceID: ds.id, days: 3, lastDay: CivilDate("2026-10-03")!, timeZoneID: ams)],
                                  preferences: prefs)
        try db.insert(Session(practiceID: ds.id, amount: 108, startedAt: Date(timeIntervalSince1970: 1_790_000_000),
                              startExact: true, timeZoneID: ams, loggedAt: Date(timeIntervalSince1970: 1_790_003_600)))
        return db
    }

    func unzip(_ data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zip = dir.appendingPathComponent("export.zip")
        try data.write(to: zip)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-q", zip.path, "-d", dir.appendingPathComponent("out").path]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "unzip accepts the archive")
        return dir.appendingPathComponent("out")
    }

    func testLocalModeExport() throws {
        let snap = try sample().snapshot()
        let out = try unzip(try DataExport.zip(snapshot: snap, server: nil, covers: ["dorje-sempa": Data([0xFF, 0xD8, 0xFF])],
                                               appVersion: "0.1 (1)"))
        let files = try FileManager.default.subpathsOfDirectory(atPath: out.path).sorted()
        XCTAssertEqual(files, ["README.txt", "covers", "covers/dorje-sempa.jpg", "practice.json"])

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: out.appendingPathComponent("practice.json"))) as! [String: Any]
        let practices = json["practices"] as! [[String: Any]]
        XCTAssertEqual(practices.first?["lifetime"] as? Int, 608)
        let sessions = json["sessions"] as! [[String: Any]]
        XCTAssertEqual(sessions.first?["amount"] as? Int, 108)
        XCTAssertEqual(sessions.first?["timeZone"] as? String, ams)
        XCTAssertEqual((json["streakSeeds"] as! [[String: Any]]).count, 1)
        let readme = try String(contentsOf: out.appendingPathComponent("README.txt"), encoding: .utf8)
        XCTAssertTrue(readme.contains("local mode"))
    }

    func testServerPartsPassThrough() throws {
        let server = DataExport.Server(account: Data(#"{"id":"a"}"#.utf8), raw: Data(#"{"blobs":[]}"#.utf8))
        let out = try unzip(try DataExport.zip(snapshot: Snapshot(), server: server, appVersion: "0.1"))
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("account.json")), server.account)
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("server-raw.json")), server.raw)
    }

    func testCRC32() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
    }

    /// Adding a table without deciding how it is exported and erased fails here
    /// (design: Data export and deletion › Testing).
    func testExportAndEraseCoverEveryTable() throws {
        let db = try sample()
        let tables = try db.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%' ORDER BY name")
        }
        // sync_state holds the account id, the key version and a cursor: the account
        // reaches the export through the server's account.json, the rest is bookkeeping.
        XCTAssertEqual(tables, ["practices", "preferences", "sessions", "streak_seeds", "sync_state"],
                       "a new table needs a place in DataExport and in AppDatabase.eraseAll")
        try db.eraseAll()
        for table in tables {
            XCTAssertEqual(try db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") }, 0, table)
        }
    }
}

import CryptoKit
import DuongondroAPI
import DuongondroCore
import DuongondroCrypto
import DuongondroStore
import XCTest
@testable import DuongondroSync

/// GET /api/me/export, canned: sealed logs opened with the practice keys, merged
/// into practice.json without repeating what the phone holds.
final class ServerExportTests: XCTestCase {
    let user = UUID()
    let practiceKey = SymmetricKey(size: .bits256).data
    let t: Int64 = 1_791_180_000_000
    var db: AppDatabase!
    var engine: SyncEngine!

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        let secrets = MemorySecretStore()
        try secrets.write(SecretName.practiceKey(1), practiceKey)
        engine = SyncEngine(account: Account(api: APIClient(baseURL: URL(string: "http://127.0.0.1:9")!), secrets: secrets, database: db))
    }

    func row(_ json: String, id: UUID, version: Int = 1, deleted: Bool = false) throws -> String {
        let sealKey = E2EE.sealKey(practiceKey: practiceKey, user: user)
        let sealed = try E2EE.sealSession(sealKey: sealKey, session: id, user: user, keyVersion: UInt32(version), json: Data(json.utf8))
        return #"{"id":"\#(id.uuidString.lowercased())","userId":"\#(user.uuidString.lowercased())","sealed":"\#(sealed.base64EncodedString())","keyVersion":\#(version),"clientUpdatedAt":"2026-10-04T13:20:00Z","deletedAt":\#(deleted ? #""2026-10-04T14:00:00Z""# : "null")}"#
    }

    func session(_ count: Int, at start: Int64) -> String {
        #"{"count":\#(count),"day":"2026-10-04","practice":"dorje-sempa","start":\#(start),"tz":"Europe/Amsterdam","updatedAt":\#(t)}"#
    }

    func canned() throws -> Data {
        let a = UUID.v7(at: SyncEngine.date(t)), b = UUID.v7(at: SyncEngine.date(t + 1000)), c = UUID.v7(at: SyncEngine.date(t + 2000))
        let d = UUID.v7(at: SyncEngine.date(t + 3000))
        let rows = [try row(session(108, at: t), id: a),
                    try row(session(21, at: t + 1000), id: b),
                    try row(session(7, at: t + 2000), id: c, version: 2),
                    try row(#"{"deletedAt":\#(t),"updatedAt":\#(t)}"#, id: d, deleted: true)]
        let body = #"{"exportedAt":"2026-10-14T20:00:00Z","users":{"id":"\#(user.uuidString.lowercased())","displayName":"Test"},"practice_logs":[\#(rows.joined(separator: ","))],"friendships":[{"displayName":"Friend","gender":"f"}],"database_generation":"g"}"#
        return Data(body.utf8)
    }

    func testOpensSealedLogsAndPassesTheResponseThrough() throws {
        let raw = try canned()
        let server = try Account.serverExport(raw: raw) { log, user in
            try self.engine.open(log.sealed ?? Data(), id: log.id, keyVersion: log.keyVersion, user: user)
        }
        XCTAssertEqual(server.raw, raw)
        XCTAssertEqual(server.account, raw)
        XCTAssertEqual(server.sessions.map(\.amount).sorted(), [21, 108])
        XCTAssertEqual(server.unreadable, 1, "the log sealed under key version 2")
    }

    func testMergeSkipsSessionsThePhoneHolds() throws {
        let server = try Account.serverExport(raw: try canned()) { log, user in
            try self.engine.open(log.sealed ?? Data(), id: log.id, keyVersion: log.keyVersion, user: user)
        }
        var snapshot = Snapshot()
        snapshot.sessions = [server.sessions[0]]
        let merged = DataExport.merged(snapshot, server)
        XCTAssertEqual(merged.sessions.count, 2)
        XCTAssertEqual(Set(merged.sessions.map(\.id)), Set(server.sessions.map(\.id)))
        XCTAssertEqual(DataExport.merged(merged, server).sessions.count, 2)
    }
}

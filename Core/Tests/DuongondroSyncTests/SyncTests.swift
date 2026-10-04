import CryptoKit
import DuongondroAPI
import DuongondroCore
import DuongondroCrypto
import DuongondroStore
import XCTest
@testable import DuongondroSync

final class StatementTests: XCTestCase {
    /// The canonical device list reproduces the vector's payload byte for byte.
    func testDeviceListMatchesTheVector() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "vectors", withExtension: "json", subdirectory: "Resources"))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let statements = json["statements"] as! [[String: Any]]
        let vector = try XCTUnwrap(statements.first { $0["type"] as? String == "device-list" })
        let payload = Data((vector["payload"] as! String).utf8)
        struct Raw: Decodable {
            struct D: Decodable { let id: String; let pk: String; let tier: String }
            let devices: [D]
            let issuedAt: Int64
            let user: String
            let version: Int
        }
        let raw = try JSONDecoder().decode(Raw.self, from: payload)
        let parsed = try XCTUnwrap(Statements.parseDeviceList(payload))
        let rebuilt = Statements.deviceList(devices: parsed.devices,
                                            issuedAt: Date(timeIntervalSince1970: Double(raw.issuedAt) / 1000),
                                            user: try XCTUnwrap(UUID(uuidString: raw.user)), version: raw.version)
        XCTAssertEqual(String(decoding: rebuilt, as: UTF8.self), String(decoding: payload, as: UTF8.self))
    }

    func testRecoveryCodeRoundTripsAndForgivesTyping() throws {
        for _ in 0..<50 {
            let secret = SymmetricKey(size: .bits128).data
            let code = RecoveryCode.encode(secret)
            XCTAssertEqual(code.count, 26 + 6, code)
            XCTAssertEqual(RecoveryCode.decode(code), secret)
            XCTAssertEqual(RecoveryCode.decode(code.lowercased().replacingOccurrences(of: "-", with: " ")), secret)
        }
        XCTAssertNil(RecoveryCode.decode("not a code"))
        XCTAssertNil(RecoveryCode.decode("UUUU-UUUU-UUUU-UUUU-UUUU-UUUU-UU"), "U is not in the alphabet")
    }

    func testSealedSessionRoundTrips() throws {
        let s = Session(practiceID: "dorje-sempa", amount: 108, startedAt: Date(timeIntervalSince1970: 1_791_176_400),
                        startExact: false, timeZoneID: "Europe/Amsterdam", chosenDay: CivilDate("2026-10-04"),
                        loggedAt: Date(timeIntervalSince1970: 1_791_180_000))
        let record = SyncRecord(session: s, updatedAt: Date(timeIntervalSince1970: 1_791_180_001))
        let json = try SealedSession(record, practiceName: nil).encoded()
        let back = try JSONDecoder().decode(SealedSession.self, from: json).record(id: s.id, updatedAt: record.updatedAt)
        XCTAssertEqual(back, record)
    }
}

/// Two phones against a real development server (`make serve` in duongondro-api,
/// which has the DEV-only session route). Skipped unless DUONGONDRO_TEST_API is
/// set, e.g. DUONGONDRO_TEST_API=http://127.0.0.1:8080.
final class LiveSyncTests: XCTestCase {
    func server() throws -> URL {
        guard let s = ProcessInfo.processInfo.environment["DUONGONDRO_TEST_API"], let url = URL(string: s) else {
            throw XCTSkip("set DUONGONDRO_TEST_API to a development server to run")
        }
        return url
    }

    func session(_ practice: String, _ amount: Int, at t: Date) -> Session {
        Session(practiceID: practice, amount: amount, startedAt: t, startExact: true, timeZoneID: "Europe/Amsterdam", loggedAt: t)
    }

    func testSetUpSyncRestoreAndDelete() async throws {
        let base = try server()
        // Phone A: a new account, practice logged before it existed, then set up.
        let devA = try await APIClient(baseURL: base).devSession()
        let dbA = try AppDatabase.inMemory()
        try dbA.save(TrackedPractice(practice: Catalogue.builtIn.first { $0.id == "dorje-sempa" }!, sortOrder: 0))
        let t = Date().addingTimeInterval(-3600)
        let first = session("dorje-sempa", 108, at: t)
        try dbA.insert(first)
        let a = Account(api: APIClient(baseURL: base, token: devA.token), secrets: MemorySecretStore(), database: dbA,
                        preferSoftwareKey: true)
        let code = try await a.setUpFirstDevice()
        var resultA = try await SyncEngine(account: a).sync()
        XCTAssertEqual(resultA.pushed, 1)

        // Setting up twice is refused: the account has keys.
        do {
            _ = try await a.setUpFirstDevice()
            XCTFail("second set-up succeeded")
        } catch Account.Failure.accountHasKeys {}

        // Phone B: same account, nothing local, a wrong code fails, the right one restores.
        let devB = try await APIClient(baseURL: base).devSession(user: devA.userId)
        let dbB = try AppDatabase.inMemory()
        let b = Account(api: APIClient(baseURL: base, token: devB.token), secrets: MemorySecretStore(), database: dbB,
                        preferSoftwareKey: true)
        do {
            try await b.restore(recoveryCode: RecoveryCode.encode(SymmetricKey(size: .bits128).data))
            XCTFail("a wrong code restored")
        } catch Account.Failure.badRecoveryCode {}
        try await b.restore(recoveryCode: code)
        var resultB = try await SyncEngine(account: b).sync()
        XCTAssertEqual(resultB.pulled, 1)
        XCTAssertEqual(try dbB.snapshot().sessions.map(\.amount), [108])
        XCTAssertEqual(try dbB.snapshot().practices.map(\.id), ["dorje-sempa"])

        // B logs and deletes; A sees both.
        let second = session("dorje-sempa", 216, at: t.addingTimeInterval(60))
        try dbB.insert(second)
        try dbB.delete(session: first.id, at: Date())
        resultB = try await SyncEngine(account: b).sync()
        XCTAssertEqual(resultB.pushed, 2)
        resultA = try await SyncEngine(account: a).sync()
        XCTAssertEqual(try dbA.snapshot().sessions.map(\.amount), [216])

        // The server holds only sealed blobs: nothing it stores reads as a count.
        let page = try await APIClient(baseURL: base, token: devA.token).sync(since: nil)
        for log in page.logs {
            let text = String(decoding: log.sealed ?? Data(), as: UTF8.self)
            XCTAssertFalse(text.contains("dorje-sempa"))
        }
    }
}

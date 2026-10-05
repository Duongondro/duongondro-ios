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
        let back = try JSONDecoder().decode(SealedSession.self, from: json).record(id: s.id)
        XCTAssertEqual(back, record)
    }
}

/// Opening what the server sends, without a server: replays, missing keys,
/// bare tombstones, and the shapes other clients may seal.
final class ApplyTests: XCTestCase {
    let user = UUID()
    let practiceKey = SymmetricKey(size: .bits256).data
    var db: AppDatabase!
    var engine: SyncEngine!

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        let secrets = MemorySecretStore()
        try secrets.write(SecretName.practiceKey(1), practiceKey)
        let account = Account(api: APIClient(baseURL: URL(string: "http://127.0.0.1:9")!), secrets: secrets, database: db)
        engine = SyncEngine(account: account)
    }

    func log(_ json: String, id: UUID, version: Int = 1, updatedAt: Int64) throws -> PracticeLog {
        let sealKey = E2EE.sealKey(practiceKey: practiceKey, user: user)
        let sealed = try E2EE.sealSession(sealKey: sealKey, session: id, user: user, keyVersion: UInt32(version), json: Data(json.utf8))
        return PracticeLog(id: id, sealed: sealed, keyVersion: version, updatedAt: SyncEngine.date(updatedAt))
    }

    let t: Int64 = 1_791_180_000_000

    func testTheVectorsSessionJSONApplies() throws {
        // The API's vector carries only the specified fields, as another client would seal them.
        let id = UUID.v7(at: SyncEngine.date(t))
        let json = #"{"count":108,"day":"2026-10-05","practice":"dorje-sempa","start":1791176400000,"tz":"Europe/Amsterdam","updatedAt":1791180000000}"#
        XCTAssertEqual(try engine.apply(log(json, id: id, updatedAt: t), user: user, generation: db.generation), .applied)
        let s = try XCTUnwrap(db.snapshot().sessions.first)
        XCTAssertEqual(s.amount, 108)
        XCTAssertFalse(s.startExact)
        XCTAssertEqual(s.loggedAt, s.startedAt)
    }

    func testAReplayUnderANewerOuterTimeIsRefused() throws {
        let id = UUID.v7(at: SyncEngine.date(t))
        let json = #"{"count":108,"practice":"dorje-sempa","start":1791176400000,"tz":"Europe/Amsterdam","updatedAt":1791180000000}"#
        XCTAssertEqual(try engine.apply(log(json, id: id, updatedAt: t + 60_000), user: user, generation: db.generation), .refused)
        XCTAssertTrue(try db.snapshot().sessions.isEmpty)
    }

    func testAMissingKeyVersionIsUnreadable() throws {
        let id = UUID.v7(at: SyncEngine.date(t))
        let json = #"{"count":1,"practice":"dorje-sempa","start":1791176400000,"tz":"Europe/Amsterdam","updatedAt":1791180000000}"#
        XCTAssertEqual(try engine.apply(log(json, id: id, version: 2, updatedAt: t), user: user, generation: db.generation), .unreadable)
    }

    func testABareTombstoneDeletes() throws {
        let id = UUID.v7(at: SyncEngine.date(t))
        let json = #"{"count":108,"practice":"dorje-sempa","start":1791176400000,"tz":"Europe/Amsterdam","updatedAt":1791180000000}"#
        _ = try engine.apply(log(json, id: id, updatedAt: t), user: user, generation: db.generation)
        let tombstone = #"{"deletedAt":1791183600000,"updatedAt":1791183600000}"#
        XCTAssertEqual(try engine.apply(log(tombstone, id: id, updatedAt: 1_791_183_600_000), user: user, generation: db.generation), .applied)
        XCTAssertTrue(try db.snapshot().sessions.isEmpty)
    }

    /// A session read back from the database, pushed (sealed time and outer time
    /// through JSON), then pulled by another phone: the two times must agree for
    /// every sub-millisecond start, which rounding down got wrong about one in nine.
    func testSealedAndOuterTimesAgreeAfterEveryRoundTrip() throws {
        let other = try AppDatabase.inMemory()
        try db.save(TrackedPractice(practice: Catalogue.builtIn.first { $0.id == "dorje-sempa" }!, sortOrder: 0))
        for i in 0..<500 {
            let t = Date(timeIntervalSince1970: 1_791_180_000 + Double(i) * 0.0137 + Double.random(in: 0..<0.001))
            try db.insert(Session(practiceID: "dorje-sempa", amount: 1, startedAt: t, startExact: true,
                                  timeZoneID: "Europe/Amsterdam", loggedAt: t))
        }
        let sealKey = E2EE.sealKey(practiceKey: practiceKey, user: user)
        let otherEngine = SyncEngine(account: Account(api: APIClient(baseURL: URL(string: "http://127.0.0.1:9")!),
                                                      secrets: engine.account.secrets, database: other))
        for record in try db.dirtySessions() {
            let json = try SealedSession(record, practiceName: nil).encoded()
            let sealed = try E2EE.sealSession(sealKey: sealKey, session: record.session.id, user: user, keyVersion: 1, json: json)
            let outer = PracticeLogInput(sealed: sealed, keyVersion: 1, updatedAt: SyncEngine.outerTime(record.updatedAt), deleted: false)
            struct Wire: Decodable { let updatedAt: Date }
            let wire = try APIClient.decoder.decode(Wire.self, from: APIClient.encoder.encode(outer))
            let log = PracticeLog(id: record.session.id, sealed: sealed, keyVersion: 1, updatedAt: wire.updatedAt)
            XCTAssertEqual(try otherEngine.apply(log, user: user, generation: other.generation), .applied)
            XCTAssertEqual(try otherEngine.apply(log, user: user, generation: other.generation), .unchanged, "applied once, then the same")
            XCTAssertEqual(try engine.apply(log, user: user, generation: db.generation), .unchanged, "the pusher sees its own write")
        }
    }

    func testPaddingHidesTheLengthOfNames() throws {
        let s = Session(practiceID: "custom-a", amount: 1, startedAt: Date(timeIntervalSince1970: 1_791_176_400),
                        startExact: true, timeZoneID: "Europe/Amsterdam", loggedAt: Date(timeIntervalSince1970: 1_791_176_400))
        let r = SyncRecord(session: s, updatedAt: s.loggedAt)
        let sealKey = E2EE.sealKey(practiceKey: practiceKey, user: user)
        let sizes = try ["A", String(repeating: "B", count: 40)].map { name in
            try E2EE.sealSession(sealKey: sealKey, session: s.id, user: user, keyVersion: 1,
                                 json: SealedSession(r, practiceName: name).encoded()).count
        }
        XCTAssertEqual(sizes[0], sizes[1])
        XCTAssertEqual((sizes[0] - 12 - 16) % 256, 0)
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

final class InviteLinkTests: XCTestCase {
    func testLinksRoundTripInAnyCase() throws {
        let link = InviteLink.new(.invite)
        XCTAssertEqual(link.string.count, "HTTPS://DUONGONDRO.APP/I/7K2MQ9XA#H4N8R2CJ6TPW3ZQF".count)
        XCTAssertEqual(InviteLink(link.string), link)
        XCTAssertEqual(InviteLink(link.string.lowercased()), link, "a browser may lower the case")
        XCTAssertEqual(InviteLink("https://duongondro.app/F/\(link.id)#\(Crockford.encode(link.secret))")?.kind, .friend)
        XCTAssertNil(InviteLink("https://example.com/I/\(link.id)#\(Crockford.encode(link.secret))"))
        XCTAssertNil(InviteLink("https://duongondro.app/I/\(link.id)"))
        XCTAssertEqual(Crockford.decode(Crockford.encode(link.secret)), link.secret)
    }
}

/// Two people against a development server: an invite, its redemption, and a
/// public streak verified against the pinned key.
final class LiveSocialTests: XCTestCase {
    func testInviteRedeemAndPublicStreak() async throws {
        guard let s = ProcessInfo.processInfo.environment["DUONGONDRO_TEST_API"], let base = URL(string: s) else {
            throw XCTSkip("set DUONGONDRO_TEST_API to a development server to run")
        }
        func person() async throws -> (Account, AppDatabase) {
            let dev = try await APIClient(baseURL: base).devSession()
            let db = try AppDatabase.inMemory()
            let account = Account(api: APIClient(baseURL: base, token: dev.token), secrets: MemorySecretStore(),
                                  database: db, preferSoftwareKey: true)
            _ = try await account.setUpFirstDevice()
            return (account, db)
        }
        let (a, dbA) = try await person()
        let (b, _) = try await person()
        try await a.api.setDisplayName("Tomasz")
        try await b.api.setDisplayName("Ania")
        try await a.api.setGender("male")

        let (link, _) = try await Social(account: a).createInvite()
        // A link whose secret was changed does not check: the MAC fails.
        var forged = link.secret
        forged[0] ^= 1
        do {
            _ = try await Social(account: b).check(InviteLink(kind: .invite, id: link.id, secret: forged))
            XCTFail("a forged secret checked")
        } catch Social.Failure.notAuthentic {}

        let checked = try await Social(account: b).check(InviteLink(link.string.lowercased())!)
        try await Social(account: b).redeem(checked)

        // A logs Dorje Sempa yesterday and today, and makes it public.
        try dbA.save(TrackedPractice(practice: Catalogue.builtIn.first { $0.id == "dorje-sempa" }!, sortOrder: 0))
        for d in [-86400.0, 0] {
            let t = Date().addingTimeInterval(d - 60)
            try dbA.insert(Session(practiceID: "dorje-sempa", amount: 108, startedAt: t, startExact: true,
                                   timeZoneID: TimeZone.current.identifier, loggedAt: t))
        }
        let socialA = Social(account: a)
        try await socialA.setPublic("dorje-sempa", true)
        let resent = try await socialA.publishStreaks()
        XCTAssertEqual(resent, 0, "nothing changed, nothing sent")

        let friendsOfB = try await Social(account: b).friends()
        XCTAssertEqual(friendsOfB.count, 1)
        XCTAssertEqual(friendsOfB[0].displayName, "Tomasz")
        XCTAssertEqual(friendsOfB[0].gender, .male)
        XCTAssertFalse(friendsOfB[0].keyChanged)
        XCTAssertEqual(friendsOfB[0].streaks.first?.practice, "dorje-sempa")
        XCTAssertEqual(friendsOfB[0].streaks.first?.current, 2)

        let friendsOfA = try await socialA.friends()
        XCTAssertEqual(friendsOfA.map(\.displayName), ["Ania"])
        XCTAssertNil(friendsOfA[0].gender, "a gender nobody gave")
        try await a.api.poke(friendsOfA[0].userID)

        // Private again: B sees no streak.
        try await socialA.setPublic("dorje-sempa", false)
        let after = try await Social(account: b).friends()
        XCTAssertTrue(after[0].streaks.isEmpty)
    }
}

/// Not a test: development data for the Friends screen. With DUONGONDRO_SEED_FRIENDS
/// set to a file path, it makes two accounts on the development server, Ania
/// (Chenrezig done today) and Piotr (Dorje Sempa waiting for today), befriends
/// them, and writes Ania's invite link to that file, to paste into the app:
///   DUONGONDRO_TEST_API=http://127.0.0.1:8080 DUONGONDRO_SEED_FRIENDS=/tmp/link swift test --filter SeedFriends
final class SeedFriends: XCTestCase {
    func testSeed() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let s = env["DUONGONDRO_TEST_API"], let base = URL(string: s), let out = env["DUONGONDRO_SEED_FRIENDS"] else {
            throw XCTSkip("development data only")
        }
        func person(_ name: String, _ practice: String, days: [Double]) async throws -> Account {
            let dev = try await APIClient(baseURL: base).devSession()
            let db = try AppDatabase.inMemory()
            let account = Account(api: APIClient(baseURL: base, token: dev.token), secrets: MemorySecretStore(),
                                  database: db, preferSoftwareKey: true)
            _ = try await account.setUpFirstDevice()
            try await account.api.setDisplayName(name)
            try db.save(TrackedPractice(practice: Catalogue.builtIn.first { $0.id == practice }!, sortOrder: 0))
            for d in days {
                let t = Date().addingTimeInterval(-d * 86400 - 600)
                try db.insert(Session(practiceID: practice, amount: 108, startedAt: t, startExact: true,
                                      timeZoneID: TimeZone.current.identifier, loggedAt: t))
            }
            try await Social(account: account).setPublic(practice, true)
            return account
        }
        let ania = try await person("Ania", "chenrezig", days: Array(0..<9).map(Double.init))
        let piotr = try await person("Piotr", "dorje-sempa", days: Array(1..<24).map(Double.init))
        let (link, _) = try await Social(account: ania).createInvite()
        try await Social(account: piotr).redeem(try await Social(account: piotr).check(link))
        let (piotrLink, _) = try await Social(account: piotr).createInvite()
        try "\(link.string)\n\(piotrLink.string)\n".write(toFile: out, atomically: true, encoding: .utf8)
    }
}

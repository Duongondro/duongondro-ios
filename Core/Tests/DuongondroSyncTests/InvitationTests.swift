import XCTest
import DuongondroAPI
import DuongondroCore
import DuongondroCrypto
import DuongondroStore
@testable import DuongondroSync

final class InvitationTests: XCTestCase {
    let link = InviteLink(kind: .invite, id: "ABCD1234", secret: Data(0..<10))

    func testTwentyFourCharactersAreAnInvite() throws {
        let code = Invitation.code(of: link)
        XCTAssertEqual(code.count, 24)
        XCTAssertEqual(Invitation.parse(code), .invite(link))
        // Typed loosely: lower case, spaces, O for 0.
        let typed = CodeEntry.grouped(code).lowercased().replacingOccurrences(of: "0", with: "o")
        XCTAssertEqual(Invitation.parse(typed), .invite(link))
        guard case .invite(let id, let auth) = Invitation.invite(link).proof else { return XCTFail("not an invite proof") }
        XCTAssertEqual(id, "ABCD1234")
        XCTAssertEqual(auth, E2EE.inviteKeys(secret: link.secret).auth)
    }

    func testAPastedLinkReadsAsItsCode() {
        XCTAssertEqual(Invitation.parse(link.string), .invite(link))
        XCTAssertEqual(Invitation.parse(link.string.lowercased()), .invite(link))
    }

    func testSixteenCharactersAreAnAdmissionCode() {
        XCTAssertEqual(Invitation.parse("abcd-efgh-jkmn-pqrs"), .admission("ABCDEFGHJKMNPQRS"))
        XCTAssertEqual(Invitation.admission("X").proof, .admission("X"))
    }

    func testOtherLengthsAreNothing() {
        XCTAssertNil(Invitation.parse(""))
        XCTAssertNil(Invitation.parse("ABCD1234"))
        XCTAssertNil(Invitation.parse(String(repeating: "A", count: 20)))
        // U is outside Crockford's alphabet.
        XCTAssertNil(Invitation.parse(String(repeating: "U", count: 16)))
    }

    func testCodeEntryForgivesTypingAndStopsAtTheLength() {
        XCTAssertEqual(CodeEntry.normalise(" ab-cd o1l ", maxLength: 8), "ABCD011")
        XCTAssertEqual(CodeEntry.normalise("abcdefghjk", maxLength: 8), "ABCDEFGH")
        XCTAssertEqual(CodeEntry.normalise("https://x/?code=abcd", maxLength: 8), "ABCD")
        XCTAssertEqual(CodeEntry.grouped("ABCDEFGHJK"), "ABCD EFGH JK")
    }
}

final class AppLinkTests: XCTestCase {
    func testMagicLinks() {
        XCTAssertEqual(AppLink(URL(string: "https://duongondro.app/m#tok_en-1")!), .magic(token: "tok_en-1"))
        XCTAssertEqual(AppLink(URL(string: "https://DUONGONDRO.APP/m/#t")!), .magic(token: "t"))
        XCTAssertNil(AppLink(URL(string: "https://duongondro.app/m")!))
        XCTAssertNil(AppLink(URL(string: "https://duongondro.app/m#" + String(repeating: "a", count: 129))!))
        XCTAssertNil(AppLink(URL(string: "https://evil.example/m#t")!))
        XCTAssertNil(AppLink(URL(string: "http://duongondro.app/m#t")!))
    }

    func testInviteLinksInEitherCase() {
        let link = InviteLink(kind: .invite, id: "ABCD1234", secret: Data(0..<10))
        XCTAssertEqual(AppLink(link.url), .invite(link))
        XCTAssertEqual(AppLink(URL(string: link.string.lowercased())!), .invite(link))
        let friend = InviteLink(kind: .friend, id: "ABCD1234", secret: Data(0..<10))
        XCTAssertEqual(AppLink(friend.url), .invite(friend))
        XCTAssertNil(AppLink(URL(string: "https://duongondro.app/privacy/")!))
    }

    func testALinkIsExpectedOnlyWithinFifteenMinutesOfAsking() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        var window = LinkWindow()
        XCTAssertFalse(window.expects(at: t))
        window.requested(at: t)
        XCTAssertTrue(window.expects(at: t))
        XCTAssertTrue(window.expects(at: t.addingTimeInterval(15 * 60)))
        XCTAssertFalse(window.expects(at: t.addingTimeInterval(15 * 60 + 1)))
        // A clock set back is no reason to trust a link.
        XCTAssertFalse(window.expects(at: t.addingTimeInterval(-1)))
        window.close()
        XCTAssertFalse(window.expects(at: t))
    }
}

final class LeavingAccountTests: XCTestCase {
    private func database() throws -> AppDatabase {
        let db = try AppDatabase.inMemory()
        let practice = TrackedPractice(practice: Catalogue.builtIn[0], streakOnly: false, openingCount: 0, sortOrder: 0)
        var prefs = Preferences()
        prefs.onboarded = true
        try db.completeOnboarding(practices: [practice], seeds: [], preferences: prefs)
        try db.insert(Session(practiceID: practice.id, amount: 108, startedAt: Date(), startExact: false,
                              timeZoneID: "UTC", loggedAt: Date()))
        try db.saveSyncState(SyncState(userID: UUID(), keyVersion: 1))
        try db.markSynced(try db.dirtySessions()[0].session.id, updatedAt: try db.dirtySessions()[0].updatedAt)
        return db
    }

    func testSigningOutKeepsThePracticeForLocalMode() throws {
        let db = try database()
        XCTAssertTrue(try db.dirtySessions().isEmpty)
        let generation = db.generation
        try db.clearSyncState()
        XCTAssertNil(try db.syncState())
        XCTAssertEqual(try db.snapshot().sessions.count, 1)
        XCTAssertEqual(try db.dirtySessions().count, 1)
        XCTAssertGreaterThan(db.generation, generation)
    }

    func testErasingAnotherAccountsPracticeKeepsThePreferences() throws {
        let db = try database()
        try db.erasePractice()
        let snapshot = try db.snapshot()
        XCTAssertTrue(snapshot.sessions.isEmpty)
        XCTAssertTrue(snapshot.practices.isEmpty)
        XCTAssertTrue(snapshot.preferences.onboarded)
        XCTAssertNil(try db.syncState())
    }
}

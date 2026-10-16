import XCTest
import DuongondroCore
@testable import DuongondroStore

final class CSVTests: XCTestCase {
    func testRFC4180Quoting() {
        XCTAssertEqual(CSV.field(.text("Dorje Sempa")), "Dorje Sempa")
        XCTAssertEqual(CSV.field(.text("a,b")), "\"a,b\"")
        XCTAssertEqual(CSV.field(.text("say \"hi\"")), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(CSV.field(.text("two\nlines")), "\"two\nlines\"")
        XCTAssertEqual(CSV.field(.text("")), "")
        XCTAssertEqual(CSV.field(.empty), "")
    }

    func testFormulaInjectionGuard() {
        XCTAssertEqual(CSV.field(.text("=HYPERLINK(\"x\")")), "\"'=HYPERLINK(\"\"x\"\")\"")
        XCTAssertEqual(CSV.field(.text("+1")), "'+1")
        XCTAssertEqual(CSV.field(.text("-2")), "'-2")
        XCTAssertEqual(CSV.field(.text("@SUM(A1)")), "'@SUM(A1)")
        XCTAssertEqual(CSV.field(.text("\tx")), "'\tx")
        XCTAssertEqual(CSV.field(.text("\rx")), "\"'\rx\"")
        XCTAssertEqual(CSV.field(.text("\r\nx")), "\"'\r\nx\"")
        XCTAssertEqual(CSV.field(.text("a=b")), "a=b", "only a leading sign is guarded")
    }

    func testNumbersStayPlain() {
        XCTAssertEqual(CSV.field(.int(111_111)), "111111")
        XCTAssertEqual(CSV.field(.int(-5)), "-5", "a number is not text, so it is not guarded")
        XCTAssertEqual(CSV.field(.bool(true)), "true")
    }

    func testTableHasBOMHeaderAndCRLF() {
        let data = CSV.table(header: ["Practice", "Count"], rows: [[.text("Чэнрэзиг"), .int(108)], [.text("x"), .empty]])
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF])
        let text = String(decoding: data.dropFirst(3), as: UTF8.self)
        XCTAssertEqual(text, "Practice,Count\r\nЧэнрэзиг,108\r\nx,\r\n")
    }
}

final class ExportContentTests: XCTestCase {
    let ams = TimeZone(identifier: "Europe/Amsterdam")!
    let ds = Catalogue.builtIn.first { $0.id == "dorje-sempa" }!

    func at(_ s: String) -> Date { ServerTables.date(s)! }

    func snapshot() -> Snapshot {
        var s = Snapshot()
        s.practices = [TrackedPractice(practice: ds, openingCount: 111_000, sortOrder: 0),
                       TrackedPractice(practice: Catalogue.builtIn.first { $0.id == "16th-karmapa" }!, streakOnly: true, sortOrder: 1)]
        // 06:40 and 07:05 on the 13th; 00:20 on the 14th, counted for the 13th by choice.
        s.sessions = [
            Session(practiceID: ds.id, amount: 108, startedAt: at("2026-10-13T04:40:00Z"), startExact: true,
                    timeZoneID: ams.identifier, loggedAt: at("2026-10-13T05:00:00Z")),
            Session(practiceID: ds.id, amount: 3, startedAt: at("2026-10-13T05:05:00Z"), startExact: true,
                    timeZoneID: ams.identifier, loggedAt: at("2026-10-13T05:10:00Z")),
            Session(practiceID: ds.id, amount: 108, startedAt: at("2026-10-13T22:20:00Z"), startExact: false,
                    timeZoneID: ams.identifier, chosenDay: CivilDate("2026-10-13"), loggedAt: at("2026-10-13T22:40:00Z")),
            Session(practiceID: "16th-karmapa", amount: 0, startedAt: at("2026-10-13T18:00:00Z"), startExact: true,
                    timeZoneID: ams.identifier, loggedAt: at("2026-10-13T18:30:00Z")),
        ]
        s.publicPractices = ["16th-karmapa"]
        return s
    }

    func testPracticesSessionsAndRoundsInLocalMode() {
        var s = snapshot()
        let pending = Session(practiceID: ds.id, amount: 108, startedAt: at("2026-10-14T06:00:00Z"), startExact: true,
                              timeZoneID: ams.identifier, loggedAt: at("2026-10-14T06:00:00Z"))
        s.sessions.append(pending)
        s.pending = [pending.id: at("2026-10-14T06:00:05Z")]
        let c = ExportContent.build(snapshot: s, server: nil, local: nil, now: at("2026-10-14T08:00:00Z"), timeZone: ams)
        XCTAssertEqual(c.serverPart, .local)
        XCTAssertNil(c.account)
        XCTAssertEqual(c.practices.map(\.id), ["dorje-sempa", "16th-karmapa"])
        let p = c.practices[0]
        XCTAssertEqual(p.total, 111_219, "the session in its undo window is left out")
        XCTAssertEqual(p.round, 2)
        XCTAssertEqual(p.inRound, 108)
        XCTAssertEqual(p.currentStreak, 1)
        XCTAssertFalse(p.isPublic)
        XCTAssertTrue(c.practices[1].isPublic)
        XCTAssertNil(c.practices[1].round)
        // 111,000 + 108 = 111,108 (round 1); + 3 = 111,111 completes it; + 108 is round 2.
        XCTAssertEqual(c.sessions.filter { $0.practiceID == ds.id }.map(\.round), [1, 1, 2])
        let late = c.sessions[2]
        XCTAssertEqual(late.startDay, CivilDate("2026-10-14"))
        XCTAssertEqual(late.day, CivilDate("2026-10-13"))
        XCTAssertTrue(late.dayChosen)
        XCTAssertEqual(c.sessionDays(of: ds.id).map { $0.sessions.count }, [2, 1])
    }

    func serverRaw() -> Data {
        Data(#"""
        {"users":{"id":"0192a000-0000-7000-8000-000000000001","displayName":"Tomasz","username":"tomasz.k","gender":"male","createdAt":"2026-10-01T10:00:00.123456Z"},
         "auth_identities":[{"provider":"email","subject":"s","email":"t@example.com","createdAt":"2026-10-01T10:00:00Z"}],
         "credentials":[{"id":"AQID","createdAt":"2026-10-01T10:00:00Z","lastUsedAt":null}],
         "devices":[{"id":"0192A000-0000-7000-8000-0000000000D1","tier":"hardware","createdAt":"2026-10-01T10:00:00Z"}],
         "friendships":[{"id":"0192a000-0000-7000-8000-000000000002","displayName":"=Anna","createdAt":"2026-10-05T10:00:00Z"}],
         "invites":[{"id":"abc","createdAt":"2026-10-02T10:00:00Z","expiresAt":"2026-11-02T10:00:00Z","revokedAt":null}],
         "invite_redemptions":[{"inviteId":"abc","inviteeId":"0192a000-0000-7000-8000-000000000002","createdAt":"2026-10-05T10:00:00Z"},
                               {"inviteId":"xyz","inviteeId":"0192a000-0000-7000-8000-000000000001","createdAt":"2026-10-01T11:00:00Z"}],
         "blocks":[{"blockerId":"0192a000-0000-7000-8000-000000000001","blockedId":"0192a000-0000-7000-8000-000000000002","createdAt":"2026-10-06T10:00:00Z"}],
         "reports":[{"id":"r","reportedId":"0192a000-0000-7000-8000-000000000003","reason":"spam","createdAt":"2026-10-06T10:00:00Z"}]}
        """#.utf8)
    }

    func testServerTables() throws {
        let server = DataExport.Server(account: Data(), raw: serverRaw(), unreadable: 1, refused: 1)
        let c = ExportContent.build(snapshot: snapshot(), server: server, local: ExportContent.Local(), timeZone: ams)
        XCTAssertEqual(c.serverPart, .included)
        let a = try XCTUnwrap(c.account)
        XCTAssertEqual(a.displayName, "Tomasz")
        XCTAssertEqual(a.username, "tomasz.k")
        XCTAssertEqual(a.emails, ["t@example.com"])
        XCTAssertNotNil(a.createdAt, "nine fraction digits are read")
        XCTAssertEqual(a.passkeys.count, 1)
        XCTAssertEqual(a.devices.map(\.tier), ["hardware"])
        XCTAssertEqual(c.friends.map(\.displayName), ["=Anna"])
        XCTAssertEqual(c.invites.map(\.id), ["xyz", "abc"])
        XCTAssertEqual(c.invites.map(\.made), [false, true])
        XCTAssertEqual(c.invites[1].redemptions, 1)
        XCTAssertEqual(c.blocks.map(\.who), ["=Anna"], "a blocked friend is named")
        XCTAssertEqual(c.reports.map(\.about), ["0192a000-0000-7000-8000-000000000003"])
        XCTAssertEqual(c.unreadable, 2)
    }

    func testAccountWithoutServerUsesThePhonesProfile() {
        let friend = PinnedFriend(userID: UUID(), identityPublicKey: Data(), displayName: "Anna", pinnedAt: at("2026-10-05T10:00:00Z"))
        var gone = friend
        gone.userID = UUID()
        gone.displayName = "Old"
        gone.listed = false
        let c = ExportContent.build(snapshot: snapshot(), server: nil,
                                    local: ExportContent.Local(displayName: "Tomasz", email: "t@example.com", friends: [friend, gone]),
                                    timeZone: ams)
        XCTAssertEqual(c.serverPart, .missing)
        XCTAssertEqual(c.account?.displayName, "Tomasz")
        XCTAssertEqual(c.friends.map(\.displayName), ["Anna"])
    }

    func testCustomPracticeNamedFromSealedSessions() {
        let remote = Session(practiceID: "custom-1", amount: 7, startedAt: at("2026-10-10T10:00:00Z"), startExact: true,
                             timeZoneID: ams.identifier, loggedAt: at("2026-10-10T10:00:00Z"))
        let server = DataExport.Server(account: Data(), raw: Data("{}".utf8), sessions: [remote], practiceNames: ["custom-1": "Medicine Buddha"])
        let c = ExportContent.build(snapshot: Snapshot(), server: server, local: ExportContent.Local(), timeZone: ams)
        XCTAssertEqual(c.practices.map(\.practice.name), ["Medicine Buddha"])
        XCTAssertEqual(c.sessions.map(\.count), [7])
    }

    func testCSVTables() throws {
        let server = DataExport.Server(account: Data(), raw: serverRaw())
        let c = ExportContent.build(snapshot: snapshot(), server: server, local: ExportContent.Local(), timeZone: ams)
        let tables = CSVExport.tables(c)
        XCTAssertEqual(tables.map(\.name), ["practices", "sessions", "friends", "invites", "blocks", "reports", "devices"])
        let sessions = String(decoding: CSV.table(header: tables[1].columns.map(\.english), rows: tables[1].rows).dropFirst(3), as: UTF8.self)
        let lines = sessions.components(separatedBy: "\r\n")
        XCTAssertEqual(lines[0], "Practice,Day counted,Start,Time zone,Count,Round,Day chosen after midnight")
        XCTAssertEqual(lines[1], "Dorje Sempa,2026-10-13,2026-10-13 06:40:00,Europe/Amsterdam,108,1,")
        XCTAssertEqual(lines[3], "Dorje Sempa,2026-10-13,2026-10-14 00:20:00,Europe/Amsterdam,108,2,2026-10-13")
        let friends = String(decoding: CSV.table(header: ["n", "s"], rows: tables[2].rows).dropFirst(3), as: UTF8.self)
        XCTAssertTrue(friends.contains("'=Anna,2026-10-05T12:00:00+02:00"), friends)

        let local = ExportContent.build(snapshot: snapshot(), server: nil, local: nil, timeZone: ams)
        XCTAssertEqual(CSVExport.tables(local).map(\.name), ["practices", "sessions"])
        let missing = ExportContent.build(snapshot: snapshot(), server: nil, local: ExportContent.Local(), timeZone: ams)
        XCTAssertEqual(CSVExport.tables(missing).map(\.name), ["practices", "sessions", "friends"])

        let out = try DataExportTests().unzip(CSVExport.zip(c))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path).sorted(),
                       ["README.txt", "blocks.csv", "devices.csv", "friends.csv", "invites.csv", "practices.csv", "reports.csv", "sessions.csv"])
        let readme = try String(contentsOf: out.appendingPathComponent("README.txt"), encoding: .utf8)
        XCTAssertTrue(readme.contains("made and redeemed"))
    }

    func testNamelessFriendAndUnreadableNote() throws {
        let raw = Data(#"{"users":{"id":"a"},"friendships":[{"id":"b","displayName":"","createdAt":"2026-10-05T10:00:00Z"}]}"#.utf8)
        let c = ExportContent.build(snapshot: Snapshot(), server: DataExport.Server(account: Data(), raw: raw, unreadable: 3),
                                    local: ExportContent.Local(), timeZone: ams)
        XCTAssertEqual(CSVExport.tables(c, aFriend: "Ein Freund")[2].rows, [[.text("Ein Freund"), .text("2026-10-05T12:00:00+02:00")]])
        XCTAssertTrue(CSVExport.readme(c).contains("3 sealed sessions could not be opened"))
    }
}

final class PageFlowTests: XCTestCase {
    typealias B = PageFlow.Block

    func blocks(_ pages: [[PageFlow.Placement]]) -> [[Int]] {
        pages.map { $0.compactMap { if case .block(let i, _) = $0 { i } else { nil } } }
    }

    func testFlowsOntoNewPages() {
        let p = PageFlow.paginate(Array(repeating: B(height: 40), count: 5), available: 100)
        XCTAssertEqual(blocks(p), [[0, 1], [2, 3], [4]])
    }

    func testHeadingNeverEndsAPage() {
        let p = PageFlow.paginate([B(height: 70), B(height: 20, keepWithNext: true), B(height: 20)], available: 100)
        XCTAssertEqual(blocks(p), [[0], [1, 2]])
    }

    func testTableHeaderRepeatsAfterABreak() {
        let rows = (0..<4).map { _ in B(height: 30, table: 7) }
        let p = PageFlow.paginate([B(height: 10, keepWithNext: true)] + rows, available: 100, headers: [7: 10])
        XCTAssertEqual(blocks(p), [[0, 1, 2, 3], [4]])
        XCTAssertEqual(p[1].first, .header(table: 7, y: 0))
        XCTAssertEqual(p[1].last, .block(4, y: 10))
    }

    func testDayKeptTogetherWhereItFits() {
        let rows = [B(height: 30, table: 1, group: 1), B(height: 30, table: 1, group: 2), B(height: 30, table: 1, group: 2)]
        let p = PageFlow.paginate([B(height: 20)] + rows, available: 100, headers: [1: 10])
        XCTAssertEqual(blocks(p), [[0, 1], [2, 3]], "the second day moves whole")
        XCTAssertEqual(p[1].first, .header(table: 1, y: 0))
    }

    func testADayTallerThanAPageBreaksInside() {
        let rows = (0..<5).map { _ in B(height: 30, table: 1, group: 1) }
        let p = PageFlow.paginate([B(height: 50)] + rows, available: 100, headers: [1: 10])
        XCTAssertEqual(blocks(p), [[0, 1], [2, 3, 4], [5]])
    }

    func testGapsCollapseAtBreaksAndAtTheEnd() {
        let p = PageFlow.paginate([B(height: 90), B(height: 20, collapsible: true), B(height: 40),
                                   B(height: 50), B(height: 30, collapsible: true)], available: 100)
        XCTAssertEqual(blocks(p), [[0], [2, 3]], "the gap at the break and the trailing one are dropped, no blank page")
        let q = PageFlow.paginate([B(height: 95), B(height: 20, collapsible: true)], available: 100)
        XCTAssertEqual(q.count, 1)
    }
}

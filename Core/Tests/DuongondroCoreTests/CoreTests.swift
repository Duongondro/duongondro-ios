import XCTest
@testable import DuongondroCore

final class CoreTests: XCTestCase {
    func testCatalogueGates() {
        let beginner = Catalogue.available(finishedNgondro: false, finishedShortRefuge: false).map(\.id)
        XCTAssertTrue(beginner.contains("short-refuge"))
        XCTAssertFalse(beginner.contains("dorje-sempa"))
        XCTAssertFalse(beginner.contains("8th-karmapa"))
        XCTAssertTrue(beginner.contains("16th-karmapa"), "open from the first day")

        let inNgondro = Catalogue.available(finishedNgondro: false, finishedShortRefuge: true).map(\.id)
        XCTAssertTrue(inNgondro.contains("dorje-sempa"))
        XCTAssertTrue(inNgondro.contains("mandala"))
        XCTAssertFalse(inNgondro.contains("8th-karmapa"))

        let done = Catalogue.available(finishedNgondro: true, finishedShortRefuge: true).map(\.id)
        XCTAssertTrue(done.contains("8th-karmapa"))
        XCTAssertTrue(done.contains("dorje-sempa"), "repeat rounds stay available")
    }

    func testKarmapaMeditationsStartStreakOnly() {
        let byID = Dictionary(uniqueKeysWithValues: Catalogue.builtIn.map { ($0.id, $0) })
        XCTAssertTrue(byID["16th-karmapa"]!.streakOnlyByDefault)
        XCTAssertNil(byID["16th-karmapa"]!.target)
        XCTAssertTrue(byID["8th-karmapa"]!.streakOnlyByDefault)
        XCTAssertFalse(byID["chenrezig"]!.streakOnlyByDefault)
        XCTAssertFalse(byID["dorje-sempa"]!.streakOnlyByDefault)
    }

    func testNgondroIsNeverStreakOnly() {
        let p = Practice(id: "x", name: "X", group: .ngondro, target: 111_111, streakOnlyAllowed: true)
        XCTAssertFalse(p.streakOnlyAllowed)
    }

    func testRounds() {
        let r = RoundProgress(lifetime: 4 * 111_111 + 35_556, target: 111_111)
        XCTAssertEqual(r.round, 5)
        XCTAssertEqual(r.inRound, 35_556)
    }

    func testMalaOverride() {
        let p = Practice(id: "x", name: "X", group: .anyTime, target: nil, streakOnlyAllowed: true, malaSize: 100)
        XCTAssertEqual(p.effectiveMalaSize(default: 108), 100)
    }

    func testPendingLogWindow() {
        let t0 = Date(timeIntervalSince1970: 0)
        var p = PendingLog(practiceID: "dorje-sempa", amount: 108, at: t0)
        XCTAssertFalse(p.isDue(at: t0.addingTimeInterval(4)))
        p.add(108, at: t0.addingTimeInterval(4))
        XCTAssertEqual(p.amount, 216)
        XCTAssertFalse(p.isDue(at: t0.addingTimeInterval(8)))
        XCTAssertTrue(p.isDue(at: t0.addingTimeInterval(9)))
    }

    func testStartEstimate() {
        let logged = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(SessionStart.estimate(loggedAt: logged, tappedStart: nil, timedSessionLengths: []),
                       logged.addingTimeInterval(-3600))
        XCTAssertEqual(SessionStart.estimate(loggedAt: logged, tappedStart: nil, timedSessionLengths: [600, 1800, 1200]),
                       logged.addingTimeInterval(-1200))
    }

    func testCivilDateParsing() {
        XCTAssertEqual(CivilDate("2026-10-05")?.description, "2026-10-05")
        XCTAssertNil(CivilDate("2026-13-05"))
        XCTAssertNil(CivilDate("26-10-05"))
    }
}

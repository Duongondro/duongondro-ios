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
        XCTAssertTrue(inNgondro.contains("short-refuge"), "short refuge stays open: we don't judge")

        let done = Catalogue.available(finishedNgondro: true, finishedShortRefuge: true).map(\.id)
        XCTAssertTrue(done.contains("8th-karmapa"))
        XCTAssertTrue(done.contains("dorje-sempa"), "repeat rounds stay available")
        XCTAssertTrue(done.contains("short-refuge"))
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

final class UsualTimeTests: XCTestCase {
    let tz = "Europe/Amsterdam"

    func session(day: Int, hour: Int, minute: Int) -> Session {
        var c = DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute)
        c.timeZone = TimeZone(identifier: tz)
        let t = Calendar(identifier: .gregorian).date(from: c)!
        return Session(practiceID: "dorje-sempa", amount: 108, startedAt: t, startExact: false, timeZoneID: tz, loggedAt: t)
    }

    var now: Date { session(day: 20, hour: 12, minute: 0).loggedAt }

    func testMedianOfTheLastTwoWeeks() {
        let s = [session(day: 15, hour: 7, minute: 0), session(day: 16, hour: 7, minute: 30),
                 session(day: 17, hour: 8, minute: 0), session(day: 1, hour: 22, minute: 0)]
        XCTAssertEqual(UsualTime.minutes(of: s, now: now), 7 * 60 + 30, "the session three weeks ago does not count")
    }

    func testTooFewSessionsAreNoHabit() {
        XCTAssertNil(UsualTime.minutes(of: [session(day: 18, hour: 7, minute: 0), session(day: 19, hour: 7, minute: 0)], now: now))
    }

    func testTimesAroundMidnightWrap() {
        let s = [session(day: 15, hour: 23, minute: 50), session(day: 16, hour: 0, minute: 10),
                 session(day: 17, hour: 23, minute: 40), session(day: 18, hour: 0, minute: 20)]
        let m = UsualTime.minutes(of: s, now: now)!
        XCTAssertTrue(m >= 23 * 60 + 45 || m <= 15, "\(m) is not near midnight")
    }
}

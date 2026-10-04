import XCTest
@testable import DuongondroCore

final class SessionTests: XCTestCase {
    let ams = "Europe/Amsterdam"

    func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    func testDayIsTheStartsLocalDate() {
        // 23:30 in Amsterdam on Sunday is Sunday, though it is Monday in Tokyo.
        let s = Session(practiceID: "dorje-sempa", amount: 108, startedAt: date("2026-10-04T21:30:00Z"),
                        startExact: true, timeZoneID: ams, loggedAt: date("2026-10-04T22:30:00Z"))
        XCTAssertEqual(s.day, CivilDate("2026-10-04"))
    }

    func testAfterMidnightOffersTheOtherDay() {
        var s = Session(practiceID: "dorje-sempa", amount: 108, startedAt: date("2026-10-04T21:30:00Z"),
                        startExact: false, timeZoneID: ams, loggedAt: date("2026-10-04T22:30:00Z"))
        let sheet = AfterMidnight.check(s)
        XCTAssertEqual(sheet?.countedFor, CivilDate("2026-10-04"))
        XCTAssertEqual(sheet?.alternative, CivilDate("2026-10-05"))

        s.chosenDay = sheet?.alternative
        XCTAssertEqual(s.day, CivilDate("2026-10-05"))
        XCTAssertEqual(AfterMidnight.check(s)?.alternative, CivilDate("2026-10-04"), "the switch goes both ways")
    }

    func testNoSheetForExactStartsOrSameDay() {
        let exact = Session(practiceID: "x", amount: 1, startedAt: date("2026-10-04T21:30:00Z"),
                            startExact: true, timeZoneID: ams, loggedAt: date("2026-10-04T22:30:00Z"))
        XCTAssertNil(AfterMidnight.check(exact))
        let sameDay = Session(practiceID: "x", amount: 1, startedAt: date("2026-10-04T10:00:00Z"),
                              startExact: false, timeZoneID: ams, loggedAt: date("2026-10-04T11:00:00Z"))
        XCTAssertNil(AfterMidnight.check(sameDay))
    }

    func testLifetimeAndRoundsIncludeOpeningCount() {
        let ds = Catalogue.builtIn.first { $0.id == "dorje-sempa" }!
        let opening = TrackedPractice.openingCount(round: 5, inRound: 35_000, target: ds.target)
        let tracked = TrackedPractice(practice: ds, openingCount: opening)
        let sessions = [
            Session(practiceID: "dorje-sempa", amount: 556, startedAt: .now, startExact: true, timeZoneID: ams, loggedAt: .now),
            Session(practiceID: "mandala", amount: 999, startedAt: .now, startExact: true, timeZoneID: ams, loggedAt: .now),
        ]
        let r = tracked.rounds(sessions: sessions)
        XCTAssertEqual(r?.round, 5)
        XCTAssertEqual(r?.inRound, 35_556)
        XCTAssertEqual(r?.lifetime, 4 * 111_111 + 35_556)
    }

    func testOpeningCountClampsWithinALaterRound() {
        XCTAssertEqual(TrackedPractice.openingCount(round: 1, inRound: 350_000, target: 111_111), 350_000)
        XCTAssertEqual(TrackedPractice.openingCount(round: 2, inRound: 350_000, target: 111_111), 2 * 111_111 - 1)
        XCTAssertEqual(TrackedPractice.openingCount(round: 0, inRound: 5, target: 111_111), 5)
        XCTAssertEqual(TrackedPractice.openingCount(round: 3, inRound: 5, target: nil), 5)
    }

    func testStreakOnlyNeverForNgondro() {
        let ds = Catalogue.builtIn.first { $0.id == "dorje-sempa" }!
        XCTAssertFalse(TrackedPractice(practice: ds, streakOnly: true).streakOnly)
        let ch = Catalogue.builtIn.first { $0.id == "chenrezig" }!
        XCTAssertTrue(TrackedPractice(practice: ch, streakOnly: true).streakOnly)
        XCTAssertNil(TrackedPractice(practice: ch, streakOnly: true).rounds(sessions: []))
    }

    func testHeadlineCountsAnyPractice() {
        let tz = TimeZone(identifier: ams)!
        let day1 = Session(practiceID: "a", amount: 1, startedAt: date("2026-10-02T08:00:00Z"), startExact: true, timeZoneID: ams, loggedAt: date("2026-10-02T09:00:00Z"))
        let day2 = Session(practiceID: "b", amount: 1, startedAt: date("2026-10-03T08:00:00Z"), startExact: true, timeZoneID: ams, loggedAt: date("2026-10-03T09:00:00Z"))
        let now = date("2026-10-03T12:00:00Z")
        XCTAssertEqual(Streak.headline(sessions: [day1, day2], seeds: [], now: now, timeZone: tz).current, 2)
        XCTAssertEqual(Streak.of(practiceID: "a", sessions: [day1, day2], seed: nil, now: now, timeZone: tz).current, 1)
    }

    func testSeedCountsPrivatelyAndKeepsLongest() {
        let tz = TimeZone(identifier: ams)!
        let seed = StreakSeed(practiceID: "a", days: 40, longest: 100, lastDay: CivilDate("2026-10-02")!, timeZoneID: ams)
        let s = Session(practiceID: "a", amount: 1, startedAt: date("2026-10-03T08:00:00Z"), startExact: true, timeZoneID: ams, loggedAt: date("2026-10-03T09:00:00Z"))
        let r = Streak.of(practiceID: "a", sessions: [s], seed: seed, now: date("2026-10-03T12:00:00Z"), timeZone: tz)
        XCTAssertEqual(r.current, 41)
        XCTAssertEqual(r.currentTracked, 1, "public streaks count tracked days only")
        XCTAssertEqual(r.longest, 100)
    }

    func testTimedLengths() {
        let t = date("2026-10-03T08:00:00Z")
        let timed = Session(practiceID: "a", amount: 1, startedAt: t, startExact: true, timeZoneID: ams, loggedAt: t.addingTimeInterval(1200))
        let estimated = Session(practiceID: "a", amount: 1, startedAt: t, startExact: false, timeZoneID: ams, loggedAt: t.addingTimeInterval(3600))
        XCTAssertEqual(SessionStart.timedLengths([timed, estimated]), [1200])
    }
}

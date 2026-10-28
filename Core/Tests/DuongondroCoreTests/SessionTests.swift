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

    // MARK: Corrections (design decision 34)

    func testACorrectionChangesTheTotalAndRoundsButNoDay() {
        let tz = TimeZone(identifier: ams)!
        let ds = Catalogue.builtIn.first { $0.id == "dorje-sempa" }!
        let tracked = TrackedPractice(practice: ds, openingCount: 111_000)
        let now = date("2026-10-03T12:00:00Z")
        let logged = Session(practiceID: ds.id, amount: 108, startedAt: date("2026-10-03T08:00:00Z"), startExact: true,
                             timeZoneID: ams, loggedAt: date("2026-10-03T08:20:00Z"))
        let up = Session.countCorrection(practiceID: ds.id, change: 1_200, at: now, timeZone: tz)
        XCTAssertTrue(up.correction)
        XCTAssertTrue(up.startExact)
        XCTAssertEqual(up.startedAt, now)
        XCTAssertEqual(up.loggedAt, now)
        XCTAssertEqual(up.timeZoneID, ams)
        XCTAssertFalse(up.countsForDay)

        let sessions = [logged, up]
        XCTAssertEqual(tracked.lifetime(sessions: sessions), 112_308)
        XCTAssertEqual(tracked.rounds(sessions: sessions)?.round, 2)
        XCTAssertEqual(tracked.rounds(sessions: sessions)?.inRound, 1_197)
        let today = CivilDate("2026-10-03")!
        XCTAssertEqual(Session.dayTotal(sessions, on: today), 108, "a correction is not part of a day's total")
        XCTAssertTrue(Session.practised(sessions, on: today))
        XCTAssertFalse(Session.practised([up], on: today), "a correction alone is no practice that day")
    }

    func testACorrectionAloneMakesNoStreak() {
        let tz = TimeZone(identifier: ams)!
        let now = date("2026-10-03T12:00:00Z")
        let c = Session.countCorrection(practiceID: "a", change: 500, at: now, timeZone: tz)
        XCTAssertEqual(Streak.of(practiceID: "a", sessions: [c], seed: nil, now: now, timeZone: tz).current, 0)
        XCTAssertEqual(Streak.headline(sessions: [c], seeds: [], now: now, timeZone: tz).current, 0)
        XCTAssertNil(UsualTime.minutes(of: [c, c, c, c], now: now))
        XCTAssertEqual(SessionStart.timedLengths([c]), [])
    }

    func testANegativeCorrectionNeverTakesTheTotalBelowZero() {
        let tz = TimeZone(identifier: ams)!
        let ds = Catalogue.builtIn.first { $0.id == "dorje-sempa" }!
        let tracked = TrackedPractice(practice: ds, openingCount: 100)
        let down = Session.countCorrection(practiceID: ds.id, change: -300, at: date("2026-10-03T12:00:00Z"), timeZone: tz)
        XCTAssertEqual(tracked.lifetime(sessions: [down]), 0)
        XCTAssertEqual(tracked.rounds(sessions: [down])?.round, 1)
        // Typing 50 now saves +250, from the unclamped −200, so the total is 50.
        XCTAssertEqual(tracked.correction(to: 50, sessions: [down]), 250)
        let up = Session.countCorrection(practiceID: ds.id, change: 250, at: date("2026-10-03T12:01:00Z"), timeZone: tz)
        XCTAssertEqual(tracked.lifetime(sessions: [down, up]), 50)
        XCTAssertEqual(tracked.correction(to: 50, sessions: [down, up]), 0, "nothing to save")
    }

    func testCountCorrectionLifetimeAndPrefill() {
        XCTAssertEqual(CountCorrection.lifetime(round: 3, inRound: 500, target: 111_111), 222_722)
        XCTAssertEqual(CountCorrection.lifetime(round: 0, inRound: 500, target: 111_111), 500, "round 1 at least")
        XCTAssertEqual(CountCorrection.lifetime(round: 4, inRound: 7, target: nil), 7, "without a target the field is the count")
        XCTAssertEqual(CountCorrection.lifetime(round: 1, inRound: 200_000, target: 111_111), 200_000,
                       "a count past the target in round 1 is a lifetime total")
        let p = CountCorrection.prefill(lifetime: 222_722, target: 111_111)
        XCTAssertEqual(p.round, 3)
        XCTAssertEqual(p.inRound, 500)
        let open = CountCorrection.prefill(lifetime: 4_321, target: nil)
        XCTAssertEqual(open.round, 1)
        XCTAssertEqual(open.inRound, 4_321)
    }
}

import XCTest
@testable import DuongondroCore

/// Runs the shared streak cases from duongondro-api/testdata/streak-cases.json,
/// copied unchanged into Resources. Go, Swift and Kotlin must all agree.
final class StreakConformanceTests: XCTestCase {
    private struct Case: Decodable {
        struct SeedJSON: Decodable { let days: Int; let lastDay: String; let tz: String }
        struct EventJSON: Decodable { let kind: String; let start: String?; let tz: String; let day: String? }
        struct Expect: Decodable {
            let current: Int
            let currentTracked: Int
            let longest: Int
            let longestTracked: Int
            let lastDay: String?
            let deadline: String?
        }
        let name: String
        let seed: SeedJSON?
        let events: [EventJSON]
        let now: String
        let nowTz: String
        let expect: Expect
    }

    private func date(_ s: String) throws -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return try XCTUnwrap(f.date(from: s), "bad timestamp \(s)")
    }

    private func zone(_ id: String) throws -> TimeZone {
        try XCTUnwrap(TimeZone(identifier: id), "unknown zone \(id)")
    }

    func testSharedCases() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "streak-cases", withExtension: "json", subdirectory: "Resources"))
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(cases.count, 15)

        for c in cases {
            var events: [Streak.Event] = []
            for e in c.events {
                let tz = try zone(e.tz)
                switch e.kind {
                case "session":
                    events.append(.session(start: try date(XCTUnwrap(e.start)), timeZone: tz,
                                           day: e.day.flatMap(CivilDate.init)))
                case "bardo":
                    events.append(.bardo(day: try XCTUnwrap(e.day.flatMap(CivilDate.init)), timeZone: tz))
                default:
                    XCTFail("\(c.name): unknown kind \(e.kind)")
                }
            }
            let seed = try c.seed.map {
                Streak.Seed(days: $0.days, lastDay: try XCTUnwrap(CivilDate($0.lastDay)), timeZone: try zone($0.tz))
            }
            let r = Streak.compute(events: events, seed: seed, now: try date(c.now), nowTimeZone: try zone(c.nowTz))

            XCTAssertEqual(r.current, c.expect.current, "\(c.name): current")
            XCTAssertEqual(r.currentTracked, c.expect.currentTracked, "\(c.name): currentTracked")
            XCTAssertEqual(r.longest, c.expect.longest, "\(c.name): longest")
            XCTAssertEqual(r.longestTracked, c.expect.longestTracked, "\(c.name): longestTracked")
            XCTAssertEqual(r.lastDay?.description, c.expect.lastDay, "\(c.name): lastDay")
            XCTAssertEqual(r.deadline, try c.expect.deadline.map(date), "\(c.name): deadline")
        }
    }

    func testWeekYearTrap() {
        let warsaw = TimeZone(identifier: "Europe/Warsaw")!
        let d = CivilDate.of(Date(timeIntervalSince1970: 1_766_991_600), in: warsaw) // 2025-12-29 08:00 +01:00
        XCTAssertEqual(d.description, "2025-12-29")
    }
}

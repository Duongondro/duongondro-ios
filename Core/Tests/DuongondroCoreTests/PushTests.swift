import XCTest
@testable import DuongondroCore

final class PushTests: XCTestCase {
    // MARK: Token and platform

    func testTokenIsLowerCaseHex() {
        XCTAssertEqual(PushToken.hex(Data([0x00, 0x0f, 0xa0, 0xff, 0x12])), "000fa0ff12")
        XCTAssertEqual(PushToken.hex(Data()), "")
        // A real token is 32 bytes: 64 characters, which the server's ^[0-9a-fA-F]{32,200}$ takes.
        XCTAssertEqual(PushToken.hex(Data(repeating: 0xab, count: 32)).count, 64)
    }

    private func profile(aps: String?) -> Data {
        let entitlements = aps.map { "<key>aps-environment</key><string>\($0)</string>" } ?? ""
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Name</key><string>Team</string>
        <key>Entitlements</key><dict>\(entitlements)<key>get-task-allow</key><true/></dict></dict></plist>
        """
        // The plist sits inside a binary CMS envelope.
        return Data([0x30, 0x82, 0x2a, 0x00, 0x06, 0x09]) + Data(plist.utf8) + Data([0xa0, 0x82, 0x0d, 0x00])
    }

    func testPlatformFollowsTheSigningProfile() {
        XCTAssertEqual(PushPlatform.apsEnvironment(inProfile: profile(aps: "development")), "development")
        XCTAssertEqual(PushPlatform.of(profile: profile(aps: "development"), simulator: false), "apns-sandbox")
        XCTAssertEqual(PushPlatform.of(profile: profile(aps: "production"), simulator: false), "apns")
        // App Store and TestFlight builds carry no profile.
        XCTAssertEqual(PushPlatform.of(profile: nil, simulator: false), "apns")
        XCTAssertEqual(PushPlatform.of(profile: nil, simulator: true), "apns-sandbox")
        XCTAssertEqual(PushPlatform.of(profile: profile(aps: "production"), simulator: true), "apns-sandbox")
        // A profile without push, or unreadable: the sandbox, as development builds use.
        XCTAssertNil(PushPlatform.apsEnvironment(inProfile: profile(aps: nil)))
        XCTAssertEqual(PushPlatform.of(profile: Data("junk".utf8), simulator: false), "apns-sandbox")
    }

    // MARK: Rendering

    private func render(_ key: String, _ args: [String], discreet: Bool = false) -> PushText? {
        PushText.render(locKey: key, args: args, discreet: discreet,
                        practiceName: { ["dorje-sempa": "Dorje Sempa", "chenrezig": "Chenrezig"][$0] },
                        number: { "#\($0)" })
    }

    func testFriendDoneNamesThePracticeAndFormatsTheDay() {
        XCTAssertEqual(render("FRIEND_DONE_MALE", ["Tomasz", "dorje-sempa", "42"]),
                       PushText(key: .friendDoneNamedMale, arguments: ["Tomasz", "Dorje Sempa", "#42"]))
        let text = render("FRIEND_DONE_FEMALE", ["Anna", "chenrezig", "1043"])!
        XCTAssertEqual(text.string(format: "%1$@ just did her %2$@ · day %3$@", locale: Locale(identifier: "en")),
                       "Anna just did her Chenrezig · day #1043")
    }

    func testFriendDoneOfAnUnknownPracticeLeavesItOut() {
        // The server's key, whose strings leave the practice id unused.
        let text = render("FRIEND_DONE", ["Ana", "a1b2c3", "7"])
        XCTAssertEqual(text, PushText(key: .friendDone, arguments: ["Ana", "a1b2c3", "#7"]))
        XCTAssertEqual(text?.string(format: "%1$@ just practised · day %3$@", locale: Locale(identifier: "en")), "Ana just practised · day #7")
        XCTAssertEqual(render("FRIEND_DONE_FEMALE", ["Ana", "a1b2c3", "7"])?.key, .friendDoneFemale)
        XCTAssertEqual(render("FRIEND_DONE_MALE", ["Jan", "a1b2c3", "7"])?.key, .friendDoneMale)
    }

    func testFailuresFallBackToTheDiscreetText() {
        for key in ["FRIEND_DONE", "FRIEND_DONE_MALE", "FRIEND_DONE_FEMALE"] {
            XCTAssertEqual(PushKey(rawValue: key)?.failSafe, .friendDoneDiscreet)
        }
        XCTAssertEqual(PushKey.streakAtRisk.failSafe, .streakAtRiskDiscreet)
        XCTAssertNil(PushKey.poke.failSafe)
    }

    func testDiscreetHidesPracticesAndNames() {
        XCTAssertEqual(render("FRIEND_DONE_MALE", ["Tomasz", "dorje-sempa", "42"], discreet: true),
                       PushText(key: .friendDoneDiscreet, arguments: []))
        XCTAssertEqual(render("STREAK_AT_RISK", ["dorje-sempa", "42"], discreet: true),
                       PushText(key: .streakAtRiskDiscreet, arguments: []))
        // A poke names no practice.
        XCTAssertEqual(render("POKE_FEMALE", ["Ana"], discreet: true), PushText(key: .pokeFemale, arguments: ["Ana"]))
        XCTAssertEqual(PushText(key: .friendDoneDiscreet, arguments: []).string(format: "A friend practised", locale: Locale(identifier: "en")),
                       "A friend practised")
    }

    func testStreakAtRisk() {
        XCTAssertEqual(render("STREAK_AT_RISK", ["dorje-sempa", "42"]),
                       PushText(key: .streakAtRiskNamed, arguments: ["Dorje Sempa", "#42"]))
        XCTAssertEqual(render("STREAK_AT_RISK", ["custom", "42"]), PushText(key: .streakAtRisk, arguments: ["custom", "#42"]))
        XCTAssertEqual(PushText(key: .streakAtRisk, arguments: ["custom", "42"]).string(format: "Your streak ends · day %2$@", locale: Locale(identifier: "en")),
                       "Your streak ends · day 42")
    }

    func testUnknownKeysAndShapesAreLeftToTheSystem() {
        XCTAssertNil(render("SOMETHING_NEW", ["x"]))
        XCTAssertNil(render("POKE", []))
        XCTAssertNil(render("FRIEND_DONE", ["Tomasz", "dorje-sempa"]))
        // The phone's own keys never come from the server.
        XCTAssertNil(render("FRIEND_DONE_DISCREET", []))
        // A day that is not a number is shown as it came.
        XCTAssertEqual(render("POKE", ["Ana"])?.arguments, ["Ana"])
        XCTAssertEqual(render("STREAK_AT_RISK", ["chenrezig", "many"])?.arguments, ["Chenrezig", "many"])
    }

    // MARK: Routes

    func testRoutes() {
        let id = UUID()
        func info(_ key: String, thread: String?) -> [AnyHashable: Any] {
            var aps: [String: Any] = ["alert": ["loc-key": key, "loc-args": ["x"]]]
            if let thread { aps["thread-id"] = thread }
            return ["aps": aps]
        }
        XCTAssertEqual(PushRoute(userInfo: info("POKE_MALE", thread: id.uuidString.lowercased())), .friend(id))
        XCTAssertEqual(PushRoute(userInfo: info("FRIEND_DONE", thread: id.uuidString)), .friend(id))
        XCTAssertEqual(PushRoute(userInfo: info("STREAK_AT_RISK", thread: "streak-dorje-sempa")), .today)
        XCTAssertNil(PushRoute(userInfo: info("POKE", thread: nil)))
        XCTAssertNil(PushRoute(userInfo: info("UNKNOWN", thread: id.uuidString)))
        XCTAssertNil(PushRoute(userInfo: [:]))
    }

    // MARK: Coverage

    /// The repository root, from this file's place in Core/Tests/DuongondroCoreTests.
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    static let languages = ["en", "de", "ru", "uk", "pl", "cs", "sk", "hu", "es"]

    /// Every key, the server's and the phone's own, has a string in every language
    /// with exactly the arguments it uses, positional (%1$@ …), as the system formats
    /// loc-args; the server's keys never name the practice.
    func testEveryKeyIsInTheCatalogInEveryLanguage() throws {
        let url = repository.appendingPathComponent("App/Resources/Localizable.xcstrings")
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let strings = catalog["strings"] as! [String: Any]
        for key in PushKey.allCases {
            let entry = try XCTUnwrap(strings[key.rawValue] as? [String: Any], "\(key.rawValue) missing")
            XCTAssertEqual(entry["extractionState"] as? String, "manual", key.rawValue)
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            for language in Self.languages {
                let unit = (localizations[language] as? [String: Any])?["stringUnit"] as? [String: Any]
                let value = try XCTUnwrap(unit?["value"] as? String, "\(key.rawValue) has no \(language)")
                let specifiers = value.matches(of: #/%(\d)\$@/#).map { Int($0.1)! }
                XCTAssertEqual(Set(specifiers), key.usedArguments, "\(key.rawValue) \(language): \(value)")
                // No other conversions: the system passes every loc-arg as a string.
                XCTAssertEqual(value.matches(of: #/%/#).count, specifiers.count, "\(key.rawValue) \(language): \(value)")
            }
        }
    }

    /// The server's keys, read from duongondro-api's source when it is checked out
    /// beside this repository: its loc-key constants (with their argument comments),
    /// and the gendered variants of the ones passed through genderedKey.
    func testServerKeysMatchTheAPISource() throws {
        var dir = repository
        var source: URL?
        for _ in 0..<3 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent("duongondro-api/internal/service/nudges.go")
            if FileManager.default.fileExists(atPath: candidate.path) { source = candidate; break }
        }
        guard let source else { throw XCTSkip("duongondro-api is not checked out beside this repository") }
        let go = try String(contentsOf: source, encoding: .utf8)
        var keys: [String: Int] = [:]
        var constants: [String: String] = [:]
        for m in go.matches(of: #/(Loc\w+)\s*=\s*"([A-Z_]+)"\s*//\s*args:\s*([^\n]+)/#) {
            constants[String(m.1)] = String(m.2)
            keys[String(m.2)] = m.3.split(separator: ",").count
        }
        XCTAssertFalse(keys.isEmpty, "no loc-key constants found in \(source.path)")
        for m in go.matches(of: #/genderedKey\((Loc\w+)/#) {
            let base = try XCTUnwrap(constants[String(m.1)])
            for suffix in ["_MALE", "_FEMALE"] { keys[base + suffix] = keys[base] }
        }
        XCTAssertEqual(Set(keys.keys), Set(PushKey.server.map(\.rawValue)))
        for (key, count) in keys {
            XCTAssertEqual(PushKey(rawValue: key)?.argumentCount, count, key)
        }
    }
}

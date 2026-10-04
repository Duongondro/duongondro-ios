import Foundation
import DuongondroCore

/// Settings › Your data › Export (GDPR Articles 15 and 20): one ZIP with
/// everything, machine-readable. Local-mode users get it from the local
/// database alone; with an account, `GET /api/me/export` supplies
/// `account.json` and `server-raw.json`, and the phone decrypts the sealed
/// sessions itself, so the export holds counts the server never saw.
public enum DataExport {
    /// What the server returned from `GET /api/me/export`, passed through as is.
    public struct Server: Sendable {
        public var account: Data
        public var raw: Data

        public init(account: Data, raw: Data) {
            self.account = account
            self.raw = raw
        }
    }

    public static func zip(snapshot: Snapshot, server: Server?, covers: [String: Data] = [:],
                           appVersion: String, now: Date = Date()) throws -> Data {
        var zip = ZipWriter()
        zip.add("README.txt", Data(readme(hasServer: server != nil, hasCovers: !covers.isEmpty).utf8), modified: now)
        zip.add("practice.json", try practiceJSON(snapshot, appVersion: appVersion, now: now), modified: now)
        if let server {
            zip.add("account.json", server.account, modified: now)
            zip.add("server-raw.json", server.raw, modified: now)
        }
        for (practiceID, image) in covers.sorted(by: { $0.key < $1.key }) {
            zip.add("covers/\(practiceID).jpg", image, modified: now)
        }
        return zip.finish()
    }

    public static func fileName(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        "duongondro-export-\(CivilDate.of(now, in: timeZone)).zip"
    }

    // MARK: - practice.json

    struct PracticeFile: Encodable {
        let format = "duongondro/practice-export/v1"
        let exportedAt: Date
        let appVersion: String
        let preferences: PreferencesOut
        let practices: [PracticeOut]
        let sessions: [SessionOut]
        let streakSeeds: [SeedOut]
    }

    struct PreferencesOut: Encodable {
        let malaSize: Int
        let finishedShortRefuge: Bool
        let finishedNgondro: Bool
        let reminderMinutesAfterMidnight: Int?
        let discreetNotifications: Bool
        let usualTimeNudge: Bool
    }

    struct PracticeOut: Encodable {
        let id: String
        let name: String
        let secondName: String?
        let group: String
        let custom: Bool
        let target: Int?
        let streakOnly: Bool
        let malaSize: Int?
        let archived: Bool
        let openingCount: Int
        let lifetime: Int
        let round: Int?
        let countInRound: Int?
    }

    struct SessionOut: Encodable {
        let id: String
        let practiceId: String
        let amount: Int
        let startedAt: Date
        let startExact: Bool
        let timeZone: String
        let day: String
        let dayChosenByUser: Bool
        let loggedAt: Date
    }

    struct SeedOut: Encodable {
        let practiceId: String
        let days: Int
        let longest: Int?
        let lastDay: String
        let timeZone: String
    }

    static func practiceJSON(_ s: Snapshot, appVersion: String, now: Date) throws -> Data {
        let p = s.preferences
        let file = PracticeFile(
            exportedAt: now, appVersion: appVersion,
            preferences: PreferencesOut(malaSize: p.malaSize, finishedShortRefuge: p.finishedShortRefuge,
                                        finishedNgondro: p.finishedNgondro, reminderMinutesAfterMidnight: p.reminderMinutes,
                                        discreetNotifications: p.discreetNotifications,
                                        usualTimeNudge: p.usualTimeNudge),
            practices: s.practices.map { t in
                let rounds = t.rounds(sessions: s.sessions)
                return PracticeOut(id: t.id, name: t.practice.name, secondName: t.practice.secondName,
                                   group: t.practice.group.rawValue, custom: t.practice.isCustom, target: t.practice.target,
                                   streakOnly: t.streakOnly, malaSize: t.practice.malaSize, archived: t.archived,
                                   openingCount: t.openingCount, lifetime: t.lifetime(sessions: s.sessions),
                                   round: rounds?.round, countInRound: rounds?.inRound)
            },
            sessions: s.sessions.map { x in
                SessionOut(id: x.id.uuidString.lowercased(), practiceId: x.practiceID, amount: x.amount,
                           startedAt: x.startedAt, startExact: x.startExact, timeZone: x.timeZoneID,
                           day: x.day.description, dayChosenByUser: x.chosenDay != nil, loggedAt: x.loggedAt)
            },
            streakSeeds: s.seeds.map { SeedOut(practiceId: $0.practiceID, days: $0.days, longest: $0.longest,
                                               lastDay: $0.lastDay.description, timeZone: $0.timeZoneID) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(file)
    }

    static func readme(hasServer: Bool, hasCovers: Bool) -> String {
        var lines = [
            "Duongöndro: all of your data",
            "",
            "practice.json",
            "  Your practices, every session and your private streak seeds, decrypted on",
            "  your phone. Times are ISO 8601 in UTC; each session also has the time zone",
            "  it started in and the day it counts for (YYYY-MM-DD). openingCount is what",
            "  you entered at onboarding; lifetime adds every session to it.",
        ]
        if hasServer {
            lines += [
                "",
                "account.json",
                "  Your account, linked sign-ins, devices, friendships, invites, blocks,",
                "  reports and public streak statements, as the server holds them.",
                "",
                "server-raw.json",
                "  Exactly what the server stores, sealed blobs as base64. The server cannot",
                "  read them; practice.json is the same data decrypted.",
            ]
        } else {
            lines += [
                "",
                "This phone is in local mode: no account exists, so nothing about you is on",
                "any server, and there is no account.json or server-raw.json.",
            ]
        }
        if hasCovers {
            lines += ["", "covers/", "  Your own cover photos, which never left the phone."]
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

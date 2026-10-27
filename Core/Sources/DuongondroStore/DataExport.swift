import Foundation
import DuongondroCore

/// Settings › Your data › Export (GDPR Articles 15 and 20): one ZIP with
/// everything, machine-readable. Local-mode users get it from the local
/// database alone; with an account, `GET /api/me/export` supplies
/// `account.json` and `server-raw.json`, and the phone decrypts the sealed
/// sessions itself, so the export holds counts the server never saw.
public enum DataExport {
    /// What the server returned from `GET /api/me/export`: `raw` as is, `account` the account's part of it.
    public struct Server: Sendable {
        public var account: Data
        public var raw: Data
        /// The sealed practice sessions, opened on this phone; merged into
        /// practice.json unless the phone already holds them.
        public var sessions: [Session]
        /// Names of custom practices, as sealed with their sessions, for practices this phone does not track.
        public var practiceNames: [String: String]
        /// Sealed logs this phone holds no key for (written by a newer key).
        public var unreadable: Int
        /// Sealed logs that opened but are unusable or whose sealed time disagrees with the server's.
        public var refused: Int

        public init(account: Data, raw: Data, sessions: [Session] = [], practiceNames: [String: String] = [:],
                    unreadable: Int = 0, refused: Int = 0) {
            self.account = account
            self.raw = raw
            self.sessions = sessions
            self.practiceNames = practiceNames
            self.unreadable = unreadable
            self.refused = refused
        }
    }

    /// `knownSessionIDs` are all of this phone's session ids, deleted ones too (the
    /// snapshot lacks those). `accountWithoutServer` is a signed-in account whose
    /// server part is missing, which the README says rather than "local mode".
    /// No cover photos, in any format (design decision of 15 October 2026): they
    /// never reach the server, so they are not data the service processes.
    public static func zip(snapshot: Snapshot, server: Server?,
                           knownSessionIDs: Set<UUID> = [], accountWithoutServer: Bool = false,
                           appVersion: String, now: Date = Date()) throws -> Data {
        var zip = ZipWriter()
        let state: ReadmeState = server != nil ? .included : (accountWithoutServer ? .missing : .local)
        zip.add("README.txt", Data(readme(state, unreadable: server?.unreadable ?? 0, refused: server?.refused ?? 0).utf8), modified: now)
        zip.add("practice.json", try practiceJSON(merged(snapshot, server, known: knownSessionIDs), appVersion: appVersion, now: now), modified: now)
        if let server {
            zip.add("account.json", server.account, modified: now)
            zip.add("server-raw.json", server.raw, modified: now)
        }
        return zip.finish()
    }

    /// The phone's snapshot plus the server's sessions it does not hold yet, so a
    /// session synced from another phone appears once. A session deleted here but
    /// not yet pushed is in `known` and stays gone. A practice only the server's
    /// sessions mention gets a minimal entry, as sync adds one.
    public static func merged(_ snapshot: Snapshot, _ server: Server?, known extra: Set<UUID> = []) -> Snapshot {
        guard let server, !server.sessions.isEmpty else { return snapshot }
        var known = extra.union(snapshot.sessions.map(\.id))
        var out = snapshot
        for session in server.sessions where known.insert(session.id).inserted {
            out.sessions.append(session)
        }
        out.sessions.sort { ($0.startedAt, $0.id.uuidString) < ($1.startedAt, $1.id.uuidString) }
        var tracked = Set(out.practices.map(\.id))
        for id in out.sessions.map(\.practiceID) where tracked.insert(id).inserted {
            let practice = Catalogue.builtIn.first { $0.id == id }
                ?? Practice(id: id, name: server.practiceNames[id] ?? id, group: .anyTime,
                            target: nil, streakOnlyAllowed: true, isCustom: true)
            out.practices.append(TrackedPractice(practice: practice, streakOnly: practice.streakOnlyByDefault,
                                                 sortOrder: (out.practices.map(\.sortOrder).max() ?? -1) + 1))
        }
        return out
    }

    public static func fileName(now: Date = Date(), timeZone: TimeZone = .current, suffix: String = "", ext: String = "zip") -> String {
        "duongondro-export-\(CivilDate.of(now, in: timeZone))\(suffix).\(ext)"
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
        /// A correction of the count (design decision 34): `amount` is the change, and
        /// it is in the lifetime total but in no day's.
        let correction: Bool
    }

    struct SeedOut: Encodable {
        let practiceId: String
        let days: Int
        let longest: Int?
        let lastDay: String
        let timeZone: String
    }

    /// Final sessions only: one still in its undo window has not happened yet, as
    /// far as anything off the phone knows.
    static func practiceJSON(_ snapshot: Snapshot, appVersion: String, now: Date) throws -> Data {
        let s = snapshot.withoutPending
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
                           day: x.day.description, dayChosenByUser: x.chosenDay != nil, loggedAt: x.loggedAt,
                           correction: x.correction)
            },
            streakSeeds: s.seeds.map { SeedOut(practiceId: $0.practiceID, days: $0.days, longest: $0.longest,
                                               lastDay: $0.lastDay.description, timeZone: $0.timeZoneID) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(file)
    }

    enum ReadmeState { case local, included, missing }

    static func readme(_ state: ReadmeState, unreadable: Int = 0, refused: Int = 0) -> String {
        let hasServer = state == .included
        var lines = [
            "Duongöndro: all of your data",
            "",
            "practice.json",
            "  Your practices, every session and your private streak seeds, decrypted on",
            "  your phone. Times are ISO 8601 in UTC; each session also has the time zone",
            "  it started in and the day it counts for (YYYY-MM-DD). openingCount is what",
            "  you entered at onboarding; lifetime adds every session to it. A session",
            "  with correction true is a correction of the count: its amount is the",
            "  change (it may be negative), counted in lifetime but in no day's total.",
        ]
        if hasServer {
            lines += [
                "  Sessions that came from your other phones through sync are included once.",
            ]
        }
        if hasServer {
            lines += [
                "",
                "account.json",
                "  Your account, linked sign-ins, devices, friendships, invites, blocks,",
                "  reports and public streak statements, as the server holds them (the",
                "  sealed logs and keys are only in server-raw.json). Friends",
                "  appear with the display name and gender the app shows you.",
                "",
                "server-raw.json",
                "  Exactly what the server stores, sealed blobs as base64. The server cannot",
                "  read them; practice.json is the same data decrypted.",
            ]
            if unreadable > 0 {
                lines += [
                    "",
                    "\(unreadable) sealed sessions could not be opened on this phone (they were sealed",
                    "with a key it does not hold yet), so they are only in server-raw.json.",
                ]
            }
            if refused > 0 {
                lines += [
                    "",
                    "\(refused) sealed sessions were opened but left out of practice.json: their content",
                    "was unusable, or its sealed time did not match the server's. They are in",
                    "server-raw.json.",
                ]
            }
        } else if state == .missing {
            lines += [
                "",
                "This phone has an account, but the server's part of the export could not be",
                "fetched (offline, signed out or the server was away), so there is no",
                "account.json or server-raw.json, and practice.json holds only what is on this",
                "phone. Export again when you are connected to include them.",
            ]
        } else {
            lines += [
                "",
                "This phone is in local mode: no account exists, so nothing about you is on",
                "any server, and there is no account.json or server-raw.json.",
            ]
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

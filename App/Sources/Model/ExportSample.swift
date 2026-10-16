#if DEBUG
import Foundation
import DuongondroCore
import DuongondroStore

/// Debug builds only: the launch argument `-ExportSample YES` writes a PDF, a CSV ZIP
/// and a JSON ZIP built from invented data (an account with friends, six weeks of
/// sessions) to the app's tmp/ExportSample, in the app's language, so the layouts
/// can be checked without touching the phone's own data. Nothing here is real.
enum ExportSample {
    @MainActor
    static func writeIfAsked() {
        guard UserDefaults.standard.bool(forKey: "ExportSample") else { return }
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ExportSample", isDirectory: true)
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let (snapshot, server) = sample()
            let content = ExportContent.build(snapshot: snapshot, server: server, local: ExportContent.Local())
            let identity = BuildIdentity.current
            let language = AppLanguage.stored().localization()
            try ExportPDF(content: content, build: "\(identity.version) · \(identity.shortRevision)").data()
                .write(to: folder.appendingPathComponent("sample-\(language).pdf"))
            try CSVExport.zip(content, header: ExportBuilder.header, aFriend: ExportBuilder.string("A friend")) { ($0.shownName, $0.shownSecondName) }
                .write(to: folder.appendingPathComponent("sample-\(language)-csv.zip"))
            try DataExport.zip(snapshot: snapshot, server: server, appVersion: identity.version)
                .write(to: folder.appendingPathComponent("sample-\(language).zip"))
        } catch {
            print("ExportSample:", error)
        }
    }

    static func sample(now: Date = Date()) -> (Snapshot, DataExport.Server) {
        let zone = TimeZone(identifier: "Europe/Warsaw")!
        let builtIn = { (id: String) in Catalogue.builtIn.first { $0.id == id }! }
        var s = Snapshot()
        s.practices = [
            TrackedPractice(practice: builtIn("dorje-sempa"), openingCount: 104_000, sortOrder: 0),
            TrackedPractice(practice: builtIn("chenrezig"), sortOrder: 1),
            TrackedPractice(practice: builtIn("16th-karmapa"), streakOnly: true, sortOrder: 2),
            TrackedPractice(practice: builtIn("mandala"), archived: true, sortOrder: 3),
        ]
        s.publicPractices = ["dorje-sempa", "16th-karmapa"]
        let today = CivilDate.of(now, in: zone)
        for back in (0..<42).reversed() {
            let day = today.adding(days: -back).startOfDay(in: zone)
            func add(_ practice: String, _ amount: Int, hour: Double, chosen: CivilDate? = nil, exact: Bool = true) {
                let start = day.addingTimeInterval(hour * 3600)
                s.sessions.append(Session(practiceID: practice, amount: amount, startedAt: start, startExact: exact,
                                          timeZoneID: zone.identifier, chosenDay: chosen, loggedAt: start.addingTimeInterval(1500)))
            }
            add("dorje-sempa", 108 * (1 + back % 3), hour: 6.5)
            if back % 2 == 0 { add("dorje-sempa", 216, hour: 19.25) }
            if back % 7 == 3 { add("dorje-sempa", 108, hour: 0.4, chosen: today.adding(days: -back - 1), exact: false) }
            if back % 3 != 1 { add("chenrezig", 1_000 + 37 * back, hour: 21) }
            add("16th-karmapa", 0, hour: 7.5)
        }
        s.sessions.sort { $0.startedAt < $1.startedAt }
        s.seeds = [StreakSeed(practiceID: "chenrezig", days: 12, longest: 60, lastDay: today.adding(days: -42), timeZoneID: zone.identifier)]
        let raw = #"""
        {"users":{"id":"0192a000-0000-7000-8000-000000000001","displayName":"Ola","username":"ola.sample","gender":"female","createdAt":"2026-09-01T08:00:00Z"},
         "auth_identities":[{"provider":"email","subject":"x","email":"ola@example.com","createdAt":"2026-09-01T08:00:00Z"}],
         "credentials":[{"id":"AQID","createdAt":"2026-09-01T08:00:00Z","lastUsedAt":"2026-10-15T07:00:00Z"},{"id":"BAUG","createdAt":"2026-09-20T08:00:00Z","lastUsedAt":null}],
         "devices":[{"id":"0192a000-0000-7000-8000-0000000000d1","tier":"hardware","createdAt":"2026-09-01T08:00:00Z"},{"id":"0192a000-0000-7000-8000-0000000000d2","tier":"software","createdAt":"2026-09-20T08:00:00Z"}],
         "friendships":[{"id":"0192a000-0000-7000-8000-000000000002","displayName":"Anna","createdAt":"2026-09-05T10:00:00Z"},{"id":"0192a000-0000-7000-8000-000000000003","displayName":"=Tomasz","createdAt":"2026-09-12T10:00:00Z"},{"id":"0192a000-0000-7000-8000-000000000004","displayName":"","createdAt":"2026-10-02T10:00:00Z"}],
         "invites":[{"id":"K7QX2M","createdAt":"2026-09-04T10:00:00Z","expiresAt":"2026-10-04T10:00:00Z","revokedAt":null}],
         "invite_redemptions":[{"inviteId":"K7QX2M","inviteeId":"0192a000-0000-7000-8000-000000000002","createdAt":"2026-09-05T10:00:00Z"}],
         "blocks":[{"blockerId":"0192a000-0000-7000-8000-000000000001","blockedId":"0192a000-0000-7000-8000-000000000009","createdAt":"2026-10-01T10:00:00Z"}],
         "reports":[{"id":"0192a000-0000-7000-8000-0000000000f1","reportedId":"0192a000-0000-7000-8000-000000000009","reason":"spam, \"ads\"","createdAt":"2026-10-01T10:00:00Z"}]}
        """#
        return (s, DataExport.Server(account: Data(raw.utf8), raw: Data(raw.utf8), unreadable: 1))
    }
}
#endif

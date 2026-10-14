import DuongondroAPI
import DuongondroCore
import DuongondroStore
import Foundation

/// The server half of Settings › Your data › Export: `GET /api/me/export`, with
/// the sealed practice logs opened on this phone under the practice keys.
extension Account {
    public func serverExport() async throws -> DataExport.Server {
        let raw = try await api.exportMe()
        // A key another phone rotated to may be waiting in this device's wraps;
        // failing to fetch it only leaves those logs unreadable.
        if let user = try? JSONDecoder().decode(ExportBody.self, from: raw).users.id {
            _ = try? await receiveNewerKeys(user: user)
        }
        return try Self.serverExport(raw: raw) { log, user in
            try SyncEngine(account: self).open(log.sealed ?? Data(), id: log.id, keyVersion: log.keyVersion, user: user)
        }
    }

    /// The tables of the export that are the account's own (design: Data export
    /// and deletion): everything but the sealed logs, key wraps and recovery boxes.
    static let accountKeys: Set<String> = [
        "exportedAt", "users", "auth_identities", "credentials", "devices", "device_lists", "sessions",
        "friendships", "invites", "invite_redemptions", "invite_tree", "admission_codes", "blocks",
        "reports", "streaks", "push_tokens",
    ]

    /// Opens the export's `practice_logs`. A log that does not open (a key this
    /// phone lacks) is counted unreadable; one that opens but is unusable, or whose
    /// sealed time disagrees with the server's (a replay), is counted refused.
    /// Tombstones add no session.
    static func serverExport(raw: Data, open: (ExportedLog, UUID) throws -> SealedSession) throws -> DataExport.Server {
        let export = try JSONDecoder().decode(ExportBody.self, from: raw)
        var sessions: [Session] = []
        var names: [String: String] = [:]
        var unreadable = 0, refused = 0
        for log in export.practiceLogs ?? [] {
            guard log.sealed != nil, log.deletedAt == nil else { continue }
            let sealed: SealedSession
            do { sealed = try open(log, export.users.id) } catch { unreadable += 1; continue }
            guard let outer = log.clientUpdatedAt.flatMap(RFC3339.date),
                  Statements.millis(outer) == sealed.updatedAt else { refused += 1; continue }
            if sealed.deletedAt != nil { continue }
            guard let record = sealed.record(id: log.id) else { refused += 1; continue }
            sessions.append(record.session)
            if let name = sealed.practiceName { names[record.session.practiceID] = name }
        }
        guard var object = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else { throw CocoaError(.coderReadCorrupt) }
        object = object.filter { accountKeys.contains($0.key) }
        let account = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return DataExport.Server(account: account, raw: raw, sessions: sessions, practiceNames: names,
                                 unreadable: unreadable, refused: refused)
    }

    struct ExportBody: Decodable {
        struct User: Decodable { let id: UUID }
        let users: User
        let practiceLogs: [ExportedLog]?

        enum CodingKeys: String, CodingKey { case users, practiceLogs = "practice_logs" }
    }

    /// One row of the export's practice_logs: the sealed blob as base64.
    struct ExportedLog: Decodable {
        let id: UUID
        let sealed: Data?
        let keyVersion: Int
        let clientUpdatedAt: String?
        let deletedAt: String?
    }
}

import DuongondroAPI
import DuongondroCore
import DuongondroStore
import Foundation

/// The server half of Settings › Your data › Export: `GET /api/me/export`, with
/// the sealed practice logs opened on this phone under the practice keys.
extension Account {
    public func serverExport() async throws -> DataExport.Server {
        try Self.serverExport(raw: try await api.exportMe()) { log, user in
            try SyncEngine(account: self).open(log.sealed ?? Data(), id: log.id, keyVersion: log.keyVersion, user: user)
        }
    }

    /// Opens the export's `practice_logs`. A log that does not open (a key this
    /// phone lacks) is counted, not fatal; tombstones add no session.
    static func serverExport(raw: Data, open: (ExportedLog, UUID) throws -> SealedSession) throws -> DataExport.Server {
        let export = try JSONDecoder().decode(ExportBody.self, from: raw)
        var sessions: [Session] = []
        var unreadable = 0
        for log in export.practiceLogs ?? [] {
            guard log.sealed != nil, log.deletedAt == nil else { continue }
            do {
                let sealed = try open(log, export.users.id)
                if sealed.deletedAt == nil, let record = sealed.record(id: log.id) { sessions.append(record.session) }
            } catch {
                unreadable += 1
            }
        }
        return DataExport.Server(account: raw, raw: raw, sessions: sessions, unreadable: unreadable)
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
        let deletedAt: String?
    }
}

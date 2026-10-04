import DuongondroAPI
import DuongondroCore
import DuongondroCrypto
import DuongondroStore
import Foundation

/// Push, then pull (CodeShare's order): every session changed here goes up sealed
/// under the practice key, then everything changed elsewhere since the cursor
/// comes down and is opened here. Last write wins on the client clock.
public struct SyncEngine: Sendable {
    let account: Account

    public init(account: Account) { self.account = account }

    public struct Result: Equatable, Sendable {
        public var pushed = 0
        public var pulled = 0
        public var unreadable = 0
    }

    public func sync() async throws -> Result {
        let db = account.database
        guard var state = try db.syncState() else { throw Account.Failure.accountHasNoKeys }
        var result = Result()

        // Push. Sessions from builds before sync have version-4 ids, which the
        // server refuses: they get v7 ids first (they never left the phone).
        try db.rekeyLegacySessionIDs()
        for record in try db.dirtySessions() {
            do {
                try await push(record, state: state)
            } catch APIError.oldKey(let current) {
                // Another phone rotated the key: take the new one from our wraps,
                // then send this session again under it.
                state.keyVersion = try await account.receiveNewerKeys(user: state.userID)
                guard state.keyVersion >= current else { throw Account.Failure.missingSecret }
                try db.saveSyncState(state)
                try await push(record, state: state)
            }
            try db.markSynced(record.session.id, updatedAt: record.updatedAt)
            result.pushed += 1
        }

        // Pull.
        let page = try await account.api.sync(since: state.cursor)
        for log in page.logs {
            guard let sealed = log.sealed else { continue }
            guard let record = try? open(sealed, log: log, user: state.userID) else {
                // A version this phone lacks: fetch it once, then try again.
                if (try? await account.receiveNewerKeys(user: state.userID)) != nil,
                   let record = try? open(sealed, log: log, user: state.userID) {
                    if try db.applyRemote(record.0, practiceName: record.1) { result.pulled += 1 }
                } else {
                    result.unreadable += 1
                }
                continue
            }
            if try db.applyRemote(record.0, practiceName: record.1) { result.pulled += 1 }
        }
        state.cursor = page.cursor
        try db.saveSyncState(state)
        return result
    }

    func push(_ record: SyncRecord, state: SyncState) async throws {
        let practiceKey = try account.practiceKey(state.keyVersion)
        let sealKey = E2EE.sealKey(practiceKey: practiceKey, user: state.userID)
        let name = try account.database.snapshot().practices.first { $0.id == record.session.practiceID && $0.practice.isCustom }?.practice.name
        let json = try SealedSession(record, practiceName: name).encoded()
        let sealed = try E2EE.sealSession(sealKey: sealKey, session: record.session.id, user: state.userID,
                                          keyVersion: UInt32(state.keyVersion), json: json)
        _ = try await account.api.putLog(id: record.session.id, PracticeLogInput(
            sealed: sealed, keyVersion: state.keyVersion, updatedAt: record.updatedAt, deleted: record.deletedAt != nil))
    }

    func open(_ sealed: Data, log: PracticeLog, user: UUID) throws -> (SyncRecord, String?) {
        let practiceKey = try account.practiceKey(log.keyVersion)
        let sealKey = E2EE.sealKey(practiceKey: practiceKey, user: user)
        let json = try E2EE.openSession(sealKey: sealKey, session: log.id, user: user, keyVersion: UInt32(log.keyVersion), sealed: sealed)
        let s = try JSONDecoder().decode(SealedSession.self, from: json)
        return (s.record(id: log.id, updatedAt: log.updatedAt), s.practiceName)
    }
}

/// The session as sealed (docs/crypto.md: practice id, count, day, start, time
/// zone, updatedAt, deletedAt), plus what this app needs to rebuild it: whether
/// the start was exact, when it was logged, the explicit day choice and a custom
/// practice's name. Times are Unix milliseconds.
struct SealedSession: Codable {
    var practice: String
    var count: Int
    var day: String
    var chosenDay: String?
    var start: Int64
    var exact: Bool
    var tz: String
    var loggedAt: Int64
    var updatedAt: Int64
    var deletedAt: Int64?
    var practiceName: String?

    init(_ r: SyncRecord, practiceName: String?) {
        let s = r.session
        practice = s.practiceID
        count = s.amount
        day = s.day.description
        chosenDay = s.chosenDay?.description
        start = Statements.millis(s.startedAt)
        exact = s.startExact
        tz = s.timeZoneID
        loggedAt = Statements.millis(s.loggedAt)
        updatedAt = Statements.millis(r.updatedAt)
        deletedAt = r.deletedAt.map(Statements.millis)
        self.practiceName = practiceName
    }

    func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }

    func record(id: UUID, updatedAt serverUpdatedAt: Date) -> SyncRecord {
        let session = Session(id: id, practiceID: practice, amount: count,
                              startedAt: Date(timeIntervalSince1970: Double(start) / 1000), startExact: exact,
                              timeZoneID: tz, chosenDay: chosenDay.flatMap(CivilDate.init),
                              loggedAt: Date(timeIntervalSince1970: Double(loggedAt) / 1000))
        return SyncRecord(session: session, updatedAt: serverUpdatedAt,
                          deletedAt: deletedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) })
    }
}

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
        /// Logs this phone holds no key for; the cursor stays put until they open.
        public var unreadable = 0
        /// Sessions the server refused, and logs whose sealed time disagreed with
        /// the server's (a replay); both are skipped and the rest goes on.
        public var refused = 0
    }

    public func sync() async throws -> Result {
        let db = account.database
        // Every write names this generation, so a sync running across an erase
        // or a sign-out never writes the old account back.
        let generation = db.generation
        guard var state = try db.syncState() else { throw Account.Failure.accountHasNoKeys }
        var result = Result()

        // Keys first: a version another phone rotated to is needed both to open
        // what it sealed and to seal what goes up.
        let newest = try await account.receiveNewerKeys(user: state.userID)
        if newest > state.keyVersion {
            state.keyVersion = newest
            try db.saveSyncState(state, generation: generation)
        }
        let names = try customNames()

        // Sessions from builds before sync have version-4 ids, which the server
        // refuses: they get v7 ids first (they never left the phone).
        try db.rekeyLegacySessionIDs()
        try await push(&state, &result, names: names, generation: generation)

        let hadCursor = state.cursor != nil
        let page = try await account.api.sync(since: state.cursor)
        for log in page.logs {
            switch try apply(log, user: state.userID, generation: generation) {
            case .applied: result.pulled += 1
            case .unchanged: break
            case .unreadable: result.unreadable += 1
            case .refused: result.refused += 1
            }
        }
        // A log that would not open is asked for again next time, by not moving past it.
        if result.unreadable == 0 {
            state.cursor = page.cursor
            try db.saveSyncState(state, generation: generation)
        }
        // A full answer to a sync that had a cursor means the server lost history
        // (a restore from backup): what it lost may live only here, so send it all.
        if page.full && hadCursor {
            try db.markAllDirty()
            try await push(&state, &result, names: names, generation: generation)
        }
        return result
    }

    /// Custom practices' names, sealed with their sessions so another phone can show them.
    func customNames() throws -> [String: String] {
        let practices = try account.database.snapshot().practices.filter(\.practice.isCustom)
        return Dictionary(practices.map { ($0.id, $0.practice.name) }, uniquingKeysWith: { a, _ in a })
    }

    func push(_ state: inout SyncState, _ result: inout Result, names: [String: String], generation: Int) async throws {
        let db = account.database
        for record in try db.dirtySessions() {
            let stored: PracticeLog
            do {
                do {
                    stored = try await put(record, state: state, names: names)
                } catch APIError.oldKey(let current) {
                    // Another phone rotated the key since the check above: take
                    // the new one from our wraps and send this session again.
                    state.keyVersion = try await account.receiveNewerKeys(user: state.userID)
                    guard state.keyVersion >= current else { throw Account.Failure.missingSecret }
                    try db.saveSyncState(state, generation: generation)
                    stored = try await put(record, state: state, names: names)
                }
            } catch let error as APIError where Self.isPerRecord(error) {
                // This one session was refused; it stays dirty and the rest goes on.
                result.refused += 1
                continue
            }
            if Statements.millis(stored.updatedAt) > Statements.millis(record.updatedAt) {
                // The server kept a newer write from another phone: take that one.
                if case .applied = try apply(stored, user: state.userID, generation: generation) { result.pulled += 1 }
                continue
            }
            try db.markSynced(record.session.id, updatedAt: record.updatedAt, generation: generation)
            result.pushed += 1
        }
    }

    static func isPerRecord(_ error: APIError) -> Bool {
        switch error {
        case .conflict, .notFound: return true
        case .status(let code, _): return (400..<500).contains(code) && code != 429
        case .unauthorized, .oldKey: return false
        }
    }

    func put(_ record: SyncRecord, state: SyncState, names: [String: String]) async throws -> PracticeLog {
        let practiceKey = try account.practiceKey(state.keyVersion)
        let sealKey = E2EE.sealKey(practiceKey: practiceKey, user: state.userID)
        let json = try SealedSession(record, practiceName: names[record.session.practiceID]).encoded()
        let sealed = try E2EE.sealSession(sealKey: sealKey, session: record.session.id, user: state.userID,
                                          keyVersion: UInt32(state.keyVersion), json: json)
        return try await account.api.putLog(id: record.session.id, PracticeLogInput(
            sealed: sealed, keyVersion: state.keyVersion, updatedAt: record.updatedAt, deleted: record.deletedAt != nil))
    }

    enum Applied { case applied, unchanged, unreadable, refused }

    func apply(_ log: PracticeLog, user: UUID, generation: Int) throws -> Applied {
        guard let sealed = log.sealed else { return .unchanged }
        let session: SealedSession
        do {
            session = try open(sealed, log: log, user: user)
        } catch {
            return .unreadable
        }
        // The server orders writes by the outer time, which it could forge; the
        // sealed one it cannot. They must agree, or this is an old blob replayed.
        guard session.updatedAt == Statements.millis(log.updatedAt) else { return .refused }
        let db = account.database
        if let record = session.record(id: log.id) {
            return try db.applyRemote(record, practiceName: session.practiceName, generation: generation) ? .applied : .unchanged
        }
        if let deletedAt = session.deletedAt {
            return try db.applyRemoteDeletion(log.id, updatedAt: Self.date(session.updatedAt), deletedAt: Self.date(deletedAt),
                                              generation: generation) ? .applied : .unchanged
        }
        return .refused
    }

    func open(_ sealed: Data, log: PracticeLog, user: UUID) throws -> SealedSession {
        let practiceKey = try account.practiceKey(log.keyVersion)
        let sealKey = E2EE.sealKey(practiceKey: practiceKey, user: user)
        let json = try E2EE.openSession(sealKey: sealKey, session: log.id, user: user, keyVersion: UInt32(log.keyVersion), sealed: sealed)
        return try JSONDecoder().decode(SealedSession.self, from: json)
    }

    static func date(_ millis: Int64) -> Date { Date(timeIntervalSince1970: Double(millis) / 1000) }
}

/// The session as sealed (docs/crypto.md in the API repository). A tombstone
/// may carry only its times, so everything else is optional on the way in.
/// Times are Unix milliseconds.
struct SealedSession: Codable {
    var practice: String?
    var count: Int?
    var day: String?
    var chosenDay: String?
    var start: Int64?
    var exact: Bool?
    var tz: String?
    var loggedAt: Int64?
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

    /// The whole session, or nil when the content is missing (a bare tombstone).
    func record(id: UUID) -> SyncRecord? {
        guard let practice, let count, let start, let tz else { return nil }
        let session = Session(id: id, practiceID: practice, amount: count,
                              startedAt: SyncEngine.date(start), startExact: exact ?? false,
                              timeZoneID: tz, chosenDay: chosenDay.flatMap(CivilDate.init),
                              loggedAt: SyncEngine.date(loggedAt ?? start))
        return SyncRecord(session: session, updatedAt: SyncEngine.date(updatedAt), deletedAt: deletedAt.map(SyncEngine.date))
    }
}

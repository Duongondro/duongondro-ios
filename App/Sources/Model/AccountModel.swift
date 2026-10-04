import DuongondroAPI
import DuongondroCore
import DuongondroStore
import DuongondroSync
import Foundation

/// The account side of the app: signing in, setting up keys or restoring them
/// from the recovery code, and syncing. Practice data never waits for it: the app
/// works fully offline, and sync catches up.
@MainActor
final class AccountModel: ObservableObject {
    enum Status: Equatable {
        /// No account on this phone: local mode.
        case none
        /// Signed in, but this phone holds no keys yet: set up, or restore.
        case needsKeys
        case ready
    }

    @Published private(set) var status: Status = .none
    @Published private(set) var lastSync: Date?
    @Published private(set) var syncing = false
    @Published var error: String?
    /// A set-up, restore or new code is under way.
    @Published private(set) var busy = false
    /// The code to show once, right after set-up or after making a new one.
    @Published var recoveryCode: String?

    let database: AppDatabase
    let secrets = KeychainStore()
    private var account: Account?
    private var pendingSync: Task<Void, Never>?

    /// Where the API lives: this Mac's development server in debug builds
    /// (`make serve` in duongondro-api), the real one otherwise.
    static var serverURL: URL {
        #if DEBUG
        URL(string: "http://127.0.0.1:8080")!
        #else
        URL(string: "https://api.duongondro.app")!
        #endif
    }

    private static let tokenName = "session-token"

    init(database: AppDatabase) {
        self.database = database
        if let token = try? secrets.read(Self.tokenName).map({ String(decoding: $0, as: UTF8.self) }) {
            open(token: token)
        }
    }

    private func open(token: String) {
        let account = Account(api: APIClient(baseURL: Self.serverURL, token: token), secrets: secrets, database: database)
        self.account = account
        status = account.hasKeys ? .ready : .needsKeys
    }

    var userID: UUID? { (try? database.syncState())?.userID }

    var deviceTier: Tier? { (try? DeviceKeys(store: secrets).current())?.tier }

    // MARK: Signing in

    #if DEBUG
    /// Development only: a session from the local server's DEV route, for a new
    /// account or, with `user`, an existing one (a second simulator).
    func signInForDevelopment(user: UUID? = nil) async {
        await run {
            let session = try await APIClient(baseURL: Self.serverURL).devSession(user: user)
            try self.secrets.write(Self.tokenName, Data(session.token.utf8))
            self.open(token: session.token)
        }
    }
    #endif

    // MARK: Keys

    func setUp() async {
        guard let account else { return }
        await run {
            self.recoveryCode = try await account.setUpFirstDevice()
            self.status = .ready
            await self.syncNow()
        }
    }

    func restore(code: String) async -> Bool {
        guard let account else { return false }
        var ok = false
        await run {
            try await account.restore(recoveryCode: code)
            self.status = .ready
            ok = true
            await self.syncNow()
        }
        return ok
    }

    func newRecoveryCode() async {
        guard let account else { return }
        await run { self.recoveryCode = try await account.newRecoveryCode() }
    }

    // MARK: Sync

    /// Syncs a moment after the last change, so a burst of malas is one round trip.
    func scheduleSync() {
        guard status == .ready, !((try? database.dirtySessions().isEmpty) ?? true) else { return }
        pendingSync?.cancel()
        pendingSync = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    func syncNow() async {
        guard status == .ready, let account, !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            _ = try await SyncEngine(account: account).sync()
            lastSync = Date()
            error = nil
        } catch APIError.unauthorized {
            // The session ended (removed elsewhere): keys stay, sign in again.
            try? secrets.delete(Self.tokenName)
            self.account = nil
            status = .none
            error = String(localized: "Signed out. Sign in again to keep syncing.")
        } catch {
            // Offline or the server is away: the data is safe here and syncs later.
            self.error = error.localizedDescription
        }
    }

    // MARK: Deleting

    /// The server half of "Delete everything": it must succeed before the phone
    /// wipes itself, or the server would keep data the person believes gone.
    /// Without an account there is nothing to delete there.
    func deleteOnServer() async throws {
        guard let account else { return }
        pendingSync?.cancel()
        try await account.api.deleteMe()
    }

    /// After the local purge (which removed every Keychain item): back to local mode.
    func forget() {
        pendingSync?.cancel()
        account = nil
        status = .none
        lastSync = nil
        recoveryCode = nil
        error = nil
    }

    private func run(_ work: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await work()
            error = nil
        } catch Account.Failure.badRecoveryCode {
            error = String(localized: "That recovery code does not open this account.")
        } catch Account.Failure.accountHasKeys {
            error = String(localized: "This account already has keys: restore it with its recovery code instead.")
            status = .needsKeys
        } catch {
            self.error = error.localizedDescription
        }
    }
}

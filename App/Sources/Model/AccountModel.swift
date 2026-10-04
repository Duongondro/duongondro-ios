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
    @Published var recoveryCode: String? {
        didSet { if recoveryCode != nil { recoveryUnconfirmed = true } }
    }
    /// A code was made but never confirmed (the app was closed before "Done"):
    /// Settings asks for a new one.
    @Published var recoveryUnconfirmed = UserDefaults.standard.bool(forKey: "recoveryUnconfirmed") {
        didSet { UserDefaults.standard.set(recoveryUnconfirmed, forKey: "recoveryUnconfirmed") }
    }

    /// The code was written down and checked.
    func confirmRecoveryCode() {
        recoveryCode = nil
        recoveryUnconfirmed = false
    }

    /// Friends as last fetched, each streak verified against the pinned key.
    @Published private(set) var friends: [Social.FriendView] = []
    @Published private(set) var friendsLoaded = false
    /// Friends poked from this phone, by the UTC day the server counts pokes in
    /// (one per friend per day); kept across launches.
    @Published private var pokedOn: [String: String] = (UserDefaults.standard.dictionary(forKey: "pokedOn") as? [String: String]) ?? [:] {
        didSet { UserDefaults.standard.set(pokedOn, forKey: "pokedOn") }
    }

    static func utcDay(_ date: Date = Date()) -> String {
        CivilDate.of(date, in: TimeZone(identifier: "UTC")!).description
    }

    func isPoked(_ friend: UUID) -> Bool { pokedOn[friend.uuidString] == Self.utcDay() }

    /// Live invites made on this phone, reused until shortly before they expire,
    /// so opening the Invite screen does not mint a new one each time.
    private var invites: [InviteLink.Kind: (link: InviteLink, expiresAt: Date)] = [:]
    /// The name friends see, as the server has it.
    @Published private(set) var displayName = ""
    /// The account's registered devices, for Settings' "Your devices".
    @Published private(set) var deviceCount: Int?
    /// The server's build, for Settings' About.
    @Published private(set) var serverVersion: ServerVersion?
    /// An invite opened from a link or pasted, waiting to be accepted.
    @Published var pendingInvite: InviteLink?

    let database: AppDatabase
    let secrets = KeychainStore()
    private var account: Account?
    private var social: Social?
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
        social = Social(account: account)
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
            // The account this phone already holds keys for, if any: a new one
            // would not match the keys and sync state kept here.
            let session = try await APIClient(baseURL: Self.serverURL).devSession(user: user ?? self.userID)
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
            let result = try await SyncEngine(account: account).sync()
            // Public streaks follow the sessions just synced; a failure here
            // leaves the counts synced and tries again next time.
            _ = try? await social?.publishStreaks()
            lastSync = Date()
            if result.refused > 0 {
                error = String(localized: "\(result.refused) changes could not be synced. Check that the phone's clock is right.")
            } else if result.unreadable > 0 {
                error = String(localized: "\(result.unreadable) sessions from another phone cannot be opened here yet.")
            } else {
                error = nil
            }
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

    func loadServerVersion() async {
        serverVersion = try? await APIClient(baseURL: Self.serverURL).version()
    }

    // MARK: Friends

    func refreshFriends() async {
        guard status == .ready, let social else { return }
        do {
            friends = try await social.friends()
            friendsLoaded = true
            if let me = try? await social.account.api.me() {
                displayName = me.displayName
                deviceCount = me.devices.count
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// One poke per friend per day; a second is answered "already" by the server.
    func poke(_ friend: UUID) async {
        guard let social else { return }
        do {
            try await social.account.api.poke(friend)
            pokedOn[friend.uuidString] = Self.utcDay()
        } catch APIError.conflict {
            pokedOn[friend.uuidString] = Self.utcDay()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func createInvite(_ kind: InviteLink.Kind) async -> (link: InviteLink, expiresAt: Date)? {
        guard let social else { return nil }
        if let live = invites[kind], live.expiresAt.timeIntervalSinceNow > (kind == .invite ? 86400 : 60) { return live }
        do {
            let made = try await social.createInvite(kind)
            invites[kind] = made
            return made
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// Checks an invite; needs no account (the invite record is public by id).
    func check(_ link: InviteLink) async throws -> Social.CheckedInvite {
        let api = APIClient(baseURL: Self.serverURL)
        let anonymous = Account(api: api, secrets: MemorySecretStore(), database: database)
        return try await Social(account: social?.account ?? anonymous).check(link)
    }

    func accept(_ invite: Social.CheckedInvite) async throws {
        guard status == .ready, let social else { throw Account.Failure.accountHasNoKeys }
        try await social.redeem(invite)
        pendingInvite = nil
        await refreshFriends()
    }

    func setNotifyDone(_ on: Bool, for friend: UUID) async {
        guard let social else { return }
        await run { try await social.account.api.setNotifyDone(on, for: friend) }
        await refreshFriends()
    }

    func unfriend(_ friend: UUID) async {
        guard let social else { return }
        await run { try await social.unfriend(friend) }
        await refreshFriends()
    }

    func block(_ friend: UUID) async {
        guard let social else { return }
        await run { try await social.block(friend) }
        await refreshFriends()
    }

    func report(_ friend: UUID, reason: String) async {
        guard let social else { return }
        await run { try await social.account.api.report(friend, reason: String(reason.prefix(1000))) }
    }

    func setPublic(_ practice: String, _ isPublic: Bool) async {
        guard let social else { return }
        await run { try await social.setPublic(practice, isPublic) }
    }

    func setDisplayName(_ name: String) async {
        guard let social else { return }
        // The server counts code points (runes), not characters.
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: name.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.prefix(64))
        let trimmed = String(scalars)
        await run {
            try await social.account.api.setDisplayName(trimmed)
            self.displayName = trimmed
        }
    }

    // MARK: Deleting

    /// The server half of "Delete everything": it must succeed before the phone
    /// wipes itself, or the server would keep data the person believes gone.
    /// Without an account there is nothing to delete there.
    struct SignInToDelete: LocalizedError {
        var errorDescription: String? {
            String(localized: "This phone belongs to an account, but is signed out. Sign in again first, so the server's copy is deleted too.")
        }
    }

    func deleteOnServer() async throws {
        guard let account else {
            // No session, but an account: wiping only the phone would leave the
            // server's copy behind with no way to reach it.
            if case .some(.some) = try? database.syncState() { throw SignInToDelete() }
            return
        }
        pendingSync?.cancel()
        try await account.api.deleteMe()
    }

    /// After the local purge (which removed every Keychain item): back to local mode.
    func forget() {
        pendingSync?.cancel()
        account = nil
        social = nil
        friends = []
        pokedOn = [:]
        invites = [:]
        pendingInvite = nil
        friendsLoaded = false
        displayName = ""
        status = .none
        lastSync = nil
        recoveryCode = nil
        recoveryUnconfirmed = false
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

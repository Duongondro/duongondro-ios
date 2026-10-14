import DuongondroAPI
import DuongondroCore
import DuongondroStore
import DuongondroSync
import Foundation
import UIKit

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
        /// The server ended the session (signed out elsewhere, or expired): keys and
        /// data stay, and signing in again picks up where it left off.
        case signedOut
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
        shownCode = nil
        recoveryUnconfirmed = false
    }

    /// The recovery code the onboarding is showing, until it is confirmed: a
    /// step shown again (Back, then forward) gets this one rather than a second.
    @Published private(set) var shownCode: String?

    /// A set-up, restore or new code is running: the onboarding's Back waits.
    @Published private(set) var keyWorkRunning = false
    /// The key operation last started; the next one waits for it, so two never
    /// run at once (a second set-up would replace the first one's recovery code).
    private var keyWork: Task<Void, Never>?
    private var keyWorkCount = 0 {
        didSet { keyWorkRunning = keyWorkCount > 0 }
    }

    /// Runs key work after any already under way, one at a time, in this model
    /// rather than the screen that asked: a screen that goes away cancels only its wait.
    private func keyed<T>(_ work: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = keyWork
        keyWorkCount += 1
        let task = Task { @MainActor () -> Result<T, Error> in
            await previous?.value
            defer { self.keyWorkCount -= 1 }
            do { return .success(try await work()) } catch { return .failure(error) }
        }
        keyWork = Task { _ = await task.value }
        return try await task.value.get()
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
    @Published private(set) var displayName = UserDefaults.standard.string(forKey: Keys.displayName) ?? "" {
        didSet { UserDefaults.standard.set(displayName, forKey: Keys.displayName) }
    }
    /// The address magic links go to, when the account has one.
    @Published private(set) var email = UserDefaults.standard.string(forKey: Keys.email) {
        didSet { UserDefaults.standard.set(email, forKey: Keys.email) }
    }
    /// Names the account's passkeys; never shown to friends.
    @Published private(set) var username = UserDefaults.standard.string(forKey: Keys.username) {
        didSet { UserDefaults.standard.set(username, forKey: Keys.username) }
    }
    /// The last sync did not finish: offline, or the server away.
    @Published private(set) var offline = false
    /// A sign-up holds a checked invitation not yet redeemed: an opened link
    /// belongs to it, not to accepting.
    @Published private(set) var signingUpWithInvite = false
    /// A magic link's token, opened while this phone expects one (it asked in the
    /// last 15 minutes); only Check your email redeems it.
    @Published var magicToken: String?
    /// Where the account steps open over the app (Settings, Friends): a new
    /// account, or signing in.
    @Published var accountFlow: AccountFlow?
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
        // Another development server, for a second one on this Mac:
        // `-DebugAPI http://127.0.0.1:8081` as a launch argument.
        UserDefaults.standard.string(forKey: "DebugAPI").flatMap(URL.init(string:)) ?? URL(string: "http://127.0.0.1:8080")!
        #else
        URL(string: "https://api.duongondro.app")!
        #endif
    }

    private static let tokenName = "session-token"

    /// UserDefaults keys for the account's profile, cleared when it leaves this phone.
    enum Keys {
        static let email = "account.email"
        static let username = "account.username"
        static let displayName = "account.displayName"
        static let lastSync = "account.lastSync"
        /// The last account signed out here: signing in to another asks before
        /// mixing this phone's practice into it.
        static let lastUser = "account.lastUser"
        /// The push token last sent, with its device and APNs environment (PushModel).
        static let pushSent = "account.pushSent"
        static let pushSentAt = "account.pushSentAt"
        static let all = [email, username, displayName, lastSync, "recoveryUnconfirmed", "pokedOn", pushSent, pushSentAt]
    }

    init(database: AppDatabase) {
        self.database = database
        lastSync = UserDefaults.standard.object(forKey: Keys.lastSync) as? Date
        if let token = try? secrets.read(Self.tokenName).map({ String(decoding: $0, as: UTF8.self) }) {
            open(token: token)
        } else if (try? database.syncState()) != nil {
            status = .signedOut
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

    /// A recovery code was made but its boxes are not all on the server yet.
    var recoveryPending: Bool { ((try? secrets.read("recovery-pending")) ?? nil) != nil }

    /// Signing out here forgets the keys, so it is allowed only when they can come
    /// back: keys set up, the recovery code stored on the server and confirmed.
    var canSignOut: Bool { status == .ready && !recoveryUnconfirmed && !recoveryPending }

    private var anonymous: APIClient { APIClient(baseURL: Self.serverURL) }

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

    /// A sign-in held back because this phone holds another account's practice.
    private var heldSignIn: SignInResult?

    /// Keeps the session, unless this phone holds practice from another account
    /// (the one it syncs with, or the last one signed out here): then nothing is
    /// kept or uploaded until the person chooses, and this returns false.
    private func signedIn(_ result: SignInResult) -> Bool {
        let owner = (try? database.syncState())?.userID ?? account?.setUpUser ?? Account(
            api: anonymous, secrets: secrets, database: database).setUpUser
        let other = owner ?? UserDefaults.standard.string(forKey: Keys.lastUser).flatMap(UUID.init(uuidString:))
        let snapshot = try? database.snapshot()
        let holdsPractice = !(snapshot?.sessions.isEmpty ?? true) || !(snapshot?.practices.isEmpty ?? true)
        if let other, other != result.userId, holdsPractice {
            heldSignIn = result
            return false
        }
        // Another account's keys, sync state and device key never carry over; with
        // no practice here there is nothing to ask about.
        if let owner, owner != result.userId {
            try? database.clearSyncState()
            forgetOtherAccount()
        }
        keep(result)
        return true
    }

    private func keep(_ result: SignInResult) {
        try? secrets.write(Self.tokenName, Data(result.token.utf8))
        open(token: result.token)
    }

    /// Forgets what this phone kept for the account it is switching away from:
    /// its keys and device key, its profile and gender (all but the email this
    /// sign-in was asked for), the last user, what was last synced, friends and
    /// pokes, and a recovery code on show.
    private func forgetOtherAccount() {
        Purge.deleteKeychainItems()
        let kept = email
        username = nil
        displayName = ""
        recoveryCode = nil
        shownCode = nil
        recoveryUnconfirmed = false
        friends = []
        friendsLoaded = false
        pokedOn = [:]
        invites = [:]
        lastSync = nil
        deviceCount = nil
        // The other account's gender would otherwise go up to this one.
        for key in Keys.all + [Keys.lastUser, Gender.storageKey] { UserDefaults.standard.removeObject(forKey: key) }
        email = kept
    }

    /// "Erase and continue": the other account's practice and keys leave this
    /// phone (its server copy stays), then the held sign-in goes on. Returns
    /// whether the held sign-in made its account.
    func eraseOtherAccountAndContinue() throws -> Bool {
        guard let result = heldSignIn else { return false }
        heldSignIn = nil
        try database.erasePractice()
        forgetOtherAccount()
        keep(result)
        return result.created
    }

    /// "Cancel": the held session ends on the server, and nothing was uploaded.
    func abandonHeldSignIn() async {
        guard let result = heldSignIn else { return }
        heldSignIn = nil
        try? await APIClient(baseURL: Self.serverURL, token: result.token).signOut()
    }

    // MARK: Invitation

    enum InviteCheck { case valid, unknown, notAuthentic }

    /// The invitation a sign-up started from, checked; kept until the account
    /// exists and has keys, then redeemed.
    private var invitation: Invitation?
    private var checkedInvite: Social.CheckedInvite? {
        didSet { signingUpWithInvite = checkedInvite != nil }
    }

    /// Checks a typed or opened code: an invite against the server (signature,
    /// then the link's MAC), an admission code by its shape only.
    func checkInvite(_ code: String) async throws -> InviteCheck {
        clearInvitation()
        switch Invitation.parse(code) {
        case nil:
            return .unknown
        case .admission(let c):
            invitation = .admission(c)
            return .valid
        case .invite(let link):
            do {
                let checked = try await check(link)
                invitation = .invite(link)
                checkedInvite = checked
                return .valid
            } catch APIError.notFound {
                return .unknown
            } catch Social.Failure.expired {
                return .unknown
            } catch Social.Failure.notAuthentic {
                return .notAuthentic
            }
        }
    }

    /// Forgets an invitation from an abandoned sign-up, so a later sign-in does not carry it.
    func clearInvitation() {
        invitation = nil
        checkedInvite = nil
    }

    // MARK: Email

    enum LinkRequest { case sent, unknownInvite, tooMany }

    enum Redeem: Equatable {
        /// Signed in; `created` when the link or passkey made the account.
        case signedIn(created: Bool)
        /// A wrong, expired, used or replaced code: the server does not say which.
        case wrong
        /// No account uses this address, and the link carried no invitation.
        case noAccount
        /// The invitation stopped being valid since the link was sent.
        case inviteGone
        case tooMany
        /// A passkey sign-in the server no longer knows (the ceremony expired, or
        /// the passkey's account is gone): try again, or use the email.
        case passkeyFailed
        /// Signed in, but this phone holds another account's practice: erase it, or cancel.
        case otherAccountData
    }

    private var linkWindow = LinkWindow()

    /// Whether an opened magic link may be redeemed now.
    func expectsLink(now: Date = Date()) -> Bool { linkWindow.expects(at: now) }

    func requestMagicLink(email address: String, signUp: Bool) async throws -> LinkRequest {
        do {
            try await anonymous.requestMagicLink(email: address, proof: signUp ? invitation?.proof : nil)
            linkWindow.requested()
            email = address
            return .sent
        } catch APIError.notFound {
            return .unknownInvite
        } catch APIError.tooManyRequests {
            return .tooMany
        }
    }

    func redeemCode(email address: String, code: String) async throws -> Redeem {
        try await redeem { try await self.anonymous.redeemMagicLink(email: address, code: code) }
    }

    /// Redeems an opened link's token, only while this phone expects one; nil otherwise.
    func redeemLink(token: String) async throws -> Redeem? {
        guard expectsLink() else { return nil }
        return try await redeem { try await self.anonymous.redeemMagicLink(token: token) }
    }

    /// An opened magic link: kept for Check your email only while expected.
    func opened(magicToken token: String) {
        magicToken = expectsLink() ? token : nil
    }

    /// `signIn`: a passkey sign-in, whose 404 is no invitation's but the ceremony's.
    private func redeem(signIn: Bool = false, _ call: () async throws -> SignInResult) async throws -> Redeem {
        do {
            let result = try await call()
            // Signed in, by code, link or passkey: a link opened after this is not redeemed.
            linkWindow.close()
            return signedIn(result) ? .signedIn(created: result.created) : .otherAccountData
        } catch APIError.badRequest {
            return signIn ? .passkeyFailed : .wrong
        } catch APIError.forbidden {
            return .noAccount
        } catch APIError.notFound {
            return signIn ? .passkeyFailed : .inviteGone
        } catch APIError.tooManyRequests {
            return .tooMany
        }
    }

    // MARK: Profile

    enum ProfileResult { case saved, usernameTaken }

    /// After a sign-up by email: the name is required, username and gender optional.
    func setProfile(name: String, username newUsername: String?, gender: Gender?) async throws -> ProfileResult {
        guard let account else { throw Account.Failure.missingSecret }
        let name = Self.trimmedName(name)
        do {
            try await account.api.updateMe(displayName: name, username: newUsername.map { .set($0.lowercased()) } ?? .keep,
                                           gender: gender.map { .set($0.rawValue) } ?? .keep)
        } catch APIError.conflict {
            return .usernameTaken
        }
        displayName = name
        if let newUsername { username = newUsername.lowercased() }
        if let gender { UserDefaults.standard.set(gender.rawValue, forKey: Gender.storageKey) }
        return .saved
    }

    /// Sets or clears the username; false when another account has it.
    func setUsername(_ value: String?) async -> Bool {
        guard let account else { return false }
        var taken = false
        await run {
            do {
                try await account.api.updateMe(username: Patch(value?.lowercased()))
                self.username = value?.lowercased()
            } catch APIError.conflict {
                taken = true
            }
        }
        return !taken
    }

    /// The server counts code points (runes), not characters: at most 64.
    static func trimmedName(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: name.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.prefix(64))
        return String(scalars)
    }

    // MARK: Passkeys

    enum PasskeyResult { case saved, cancelled, usernameTaken, inviteGone, otherAccountData }

    /// Without a session, makes the account with a passkey and the profile (the
    /// no-email path); signed in, adds a passkey to the account.
    func createPasskey(profile: Profile?) async throws -> PasskeyResult {
        if let account {
            let ceremony = try await account.api.beginPasskeyAdd()
            guard let credential = try await Passkeys.create(ceremony) else { return .cancelled }
            try await account.api.finishPasskeyAdd(ceremony: ceremony.sessionId, credential: credential)
            return .saved
        }
        guard let proof = invitation?.proof else { throw Account.Failure.accountHasNoKeys }
        let result: SignInResult
        do {
            let ceremony = try await anonymous.beginPasskeySignUp(proof: proof, profile: profile ?? Profile())
            guard let credential = try await Passkeys.create(ceremony) else { return .cancelled }
            result = try await anonymous.finishPasskey(ceremony: ceremony.sessionId, credential: credential)
        } catch APIError.conflict {
            return .usernameTaken
        } catch APIError.notFound {
            return .inviteGone
        }
        guard signedIn(result) else { return .otherAccountData }
        if let profile {
            if let n = profile.displayName { displayName = n }
            username = profile.username
            if let g = profile.gender { UserDefaults.standard.set(g, forKey: Gender.storageKey) }
        }
        return .saved
    }

    /// Offers this app's passkeys; nil when there is none or the person backed out.
    func signInWithPasskey() async throws -> Redeem? {
        let ceremony: Ceremony
        do {
            ceremony = try await anonymous.beginPasskeySignIn()
        } catch APIError.tooManyRequests {
            return .tooMany
        }
        guard let credential = try await Passkeys.assert(ceremony) else { return nil }
        return try await redeem(signIn: true) {
            try await self.anonymous.finishPasskey(ceremony: ceremony.sessionId, credential: credential)
        }
    }

    // MARK: Keys

    /// Whether the signed-in account needs setting up here, restoring, or nothing;
    /// also takes the profile as the server has it, for a sign-in on a new phone.
    func standing() async throws -> Account.Standing {
        guard let account else { throw Account.Failure.missingSecret }
        let standing = try await account.standing()
        if standing == .ready { status = .ready }
        if let me = try? await account.api.me() {
            if !me.displayName.isEmpty { displayName = me.displayName }
            username = me.username
            if let g = me.gender { UserDefaults.standard.set(g, forKey: Gender.storageKey) }
        }
        return standing
    }

    /// Sets up keys during onboarding (or finishes an interrupted set-up, with the
    /// same code) and returns the recovery code, which the onboarding shows itself.
    /// Asked again while it runs or after, it returns the same code.
    func setUpKeys() async throws -> String {
        try await keyed {
            if let code = self.shownCode { return code }
            guard let account = self.account else { throw Account.Failure.missingSecret }
            let code = account.hasKeys ? try await account.newRecoveryCode() : try await account.setUpFirstDevice()
            self.shownCode = code
            self.recoveryUnconfirmed = true
            self.status = .ready
            self.afterKeysInBackground(account)
            return code
        }
    }

    /// What follows new keys, without holding up the code or the restore that
    /// made them: the person sees the recovery code at once.
    private func afterKeysInBackground(_ account: Account) {
        Task { await self.afterKeys(account) }
    }

    /// The fallback report, then the invitation's friendship, once keys exist,
    /// then the first sync. Failures here never fail the set-up.
    private func afterKeys(_ account: Account) async {
        await reportFallback(account)
        if let checked = checkedInvite, let social {
            if let me = userID, checked.inviter != me {
                try? await social.redeem(checked)
            }
            // The link that started this sign-up is used: never offer it for accepting.
            if pendingInvite?.id == checked.link.id { pendingInvite = nil }
        }
        clearInvitation()
        await syncNow()
    }

    // MARK: Keys

    func setUp() async {
        await run {
            try await self.keyed {
                // A second tap, or one after the first finished: nothing more to do.
                guard self.recoveryCode == nil, let account = self.account, !account.hasKeys else { return }
                self.recoveryCode = try await account.setUpFirstDevice()
                self.status = .ready
                self.afterKeysInBackground(account)
            }
        }
    }

    func restore(code: String) async -> Bool {
        var ok = false
        await run { ok = try await self.restoreKeys(code: code) }
        if !ok, error == nil {
            error = String(localized: "That recovery code does not open this account.", bundle: .appLanguage, locale: .appLanguage)
        }
        return ok
    }

    /// The onboarding's restore: false when the code does not open this
    /// account's recovery boxes; other failures throw.
    func restoreKeys(code: String) async throws -> Bool {
        try await keyed {
            guard let account = self.account else { throw Account.Failure.missingSecret }
            if !account.hasKeys {
                do {
                    try await account.restore(recoveryCode: code)
                } catch Account.Failure.badRecoveryCode {
                    return false
                }
            }
            self.status = .ready
            self.afterKeysInBackground(account)
            return true
        }
    }

    func newRecoveryCode() async {
        await run {
            try await self.keyed {
                guard self.recoveryCode == nil, let account = self.account else { return }
                self.recoveryCode = try await account.newRecoveryCode()
            }
        }
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
            UserDefaults.standard.set(lastSync, forKey: Keys.lastSync)
            offline = false
            if result.refused > 0 {
                error = String(localized: "\(result.refused) changes could not be synced. Check that the phone's clock is right.", bundle: .appLanguage, locale: .appLanguage)
            } else if result.unreadable > 0 {
                error = String(localized: "\(result.unreadable) sessions from another phone cannot be opened here yet.", bundle: .appLanguage, locale: .appLanguage)
            } else {
                error = nil
            }
        } catch APIError.unauthorized {
            // The session ended (removed elsewhere): keys stay, sign in again. The
            // server dropped the push token with the session.
            try? secrets.delete(Self.tokenName)
            UserDefaults.standard.removeObject(forKey: Keys.pushSent)
        UserDefaults.standard.removeObject(forKey: Keys.pushSentAt)
            self.account = nil
            social = nil
            status = .signedOut
            error = nil
        } catch {
            // Offline or the server is away: the data is safe here and syncs later.
            offline = true
            self.error = nil
        }
    }

    /// Only with an account: local mode makes no network call at all.
    func loadServerVersion() async {
        guard status != .none else { return serverVersion = nil }
        serverVersion = try? await APIClient(baseURL: Self.serverURL).version()
    }

    /// A Secure Enclave that refused to make a key is reported (design: Keys),
    /// so a pattern across devices shows; the key then lives in the Keychain.
    private func reportFallback(_ account: Account) async {
        guard account.deviceKeyFellBack else { return }
        let info = Bundle.main.infoDictionary ?? [:]
        try? await account.api.reportClientError(
            message: "secure enclave key creation failed; software key used",
            appVersion: info["CFBundleShortVersionString"] as? String ?? "?",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString)
    }

    // MARK: Friends

    func refreshFriends() async {
        guard status == .ready, let social else { return }
        do {
            friends = try await social.friends()
            friendsLoaded = true
            if let me = try? await social.account.api.me() {
                displayName = me.displayName
                username = me.username
                deviceCount = me.devices.count
                await reconcileGender(server: me.gender.flatMap(Gender.init(rawValue:)), social: social)
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
        let trimmed = Self.trimmedName(name)
        await run {
            try await social.account.api.setDisplayName(trimmed)
            self.displayName = trimmed
        }
    }

    /// This person's grammatical gender: kept on the phone, so the app conjugates
    /// without an account, and on the server, so friends' phones can too.
    func setGender(_ gender: Gender?) async {
        UserDefaults.standard.set(gender?.rawValue ?? "", forKey: Gender.storageKey)
        guard status == .ready, let social else { return }
        await run { try await social.account.api.setGender(gender?.rawValue) }
    }

    /// The server's value wins once there is one (another phone may have changed
    /// it); a value given before the account existed goes up.
    private func reconcileGender(server: Gender?, social: Social) async {
        if let server {
            if server != Gender.stored() { UserDefaults.standard.set(server.rawValue, forKey: Gender.storageKey) }
        } else if let mine = Gender.stored() {
            try? await social.account.api.setGender(mine.rawValue)
        }
    }

    // MARK: Push

    /// This phone's device id, for its push token: only an account with keys here.
    var pushDevice: UUID? { status == .ready ? account?.deviceID : nil }

    func putPushToken(_ token: String, platform: String) async throws {
        guard let account, let device = pushDevice else { return }
        try await account.api.putPushToken(device: device, platform: platform, token: token)
    }

    /// No more pushes to this phone for the account it is leaving, even when the
    /// server cannot be reached: the token is deleted there if it can be, this app
    /// stops receiving remote notifications, and the extension's settings go.
    private func dropPushToken(_ account: Account) async {
        if let device = account.deviceID { try? await account.api.deletePushToken(device: device) }
        UIApplication.shared.unregisterForRemoteNotifications()
        UserDefaults(suiteName: PushShared.appGroup)?.removePersistentDomain(forName: PushShared.appGroup)
        UserDefaults.standard.removeObject(forKey: Keys.pushSent)
        UserDefaults.standard.removeObject(forKey: Keys.pushSentAt)
    }

    // MARK: Signing out

    /// Ends the session here and forgets the account on this phone: the token,
    /// the account's keys, the device key and the sync state. The practice stays,
    /// as in local mode. Allowed only once the recovery code is safe.
    func signOut() async {
        guard canSignOut, let account else { return }
        pendingSync?.cancel()
        let user = userID
        await run {
            await self.dropPushToken(account)
            try? await account.api.signOut()
            try self.database.clearSyncState()
            Purge.deleteKeychainItems()
            self.forget()
            // After forget(), which clears it: signing in to another account later
            // asks before mixing this phone's practice into it.
            if let user { UserDefaults.standard.set(user.uuidString, forKey: Keys.lastUser) }
        }
    }

    // MARK: Deleting

    /// The server half of "Delete everything": it must succeed before the phone
    /// wipes itself, or the server would keep data the person believes gone.
    /// Without an account there is nothing to delete there.
    struct SignInToDelete: LocalizedError {
        var errorDescription: String? {
            String(localized: "This phone belongs to an account, but is signed out. Sign in again first, so the server's copy is deleted too.", bundle: .appLanguage, locale: .appLanguage)
        }
    }

    /// The server half of Your data › Export, with its sealed sessions opened on
    /// this phone. Nil without a ready account (local mode needs no network).
    func serverExport() async throws -> DataExport.Server? {
        guard status == .ready, let account else { return nil }
        return try await account.serverExport()
    }

    func deleteOnServer() async throws {
        guard let account else {
            // No session, but an account: wiping only the phone would leave the
            // server's copy behind with no way to reach it.
            if case .some(.some) = try? database.syncState() { throw SignInToDelete() }
            return
        }
        pendingSync?.cancel()
        // The server drops it with the account anyway; first, so this phone gets no
        // push between the deletion and the purge.
        await dropPushToken(account)
        try await account.api.deleteMe()
    }

    /// After the local purge (which removed every Keychain item): back to local mode.
    func forget() {
        pendingSync?.cancel()
        // A finished export holds the account's data: it goes with the account.
        try? FileManager.default.removeItem(at: ExportFile.folderURL())
        account = nil
        social = nil
        friends = []
        pokedOn = [:]
        invites = [:]
        pendingInvite = nil
        friendsLoaded = false
        displayName = ""
        username = nil
        email = nil
        offline = false
        clearInvitation()
        heldSignIn = nil
        magicToken = nil
        linkWindow.close()
        status = .none
        lastSync = nil
        recoveryCode = nil
        shownCode = nil
        recoveryUnconfirmed = false
        deviceCount = nil
        serverVersion = nil
        error = nil
        // Last, as the properties above write some of these back: nothing of the
        // account stays, the last user included, so a later sign-up on this phone
        // is not taken for another account's.
        for key in Keys.all + [Keys.lastUser] { UserDefaults.standard.removeObject(forKey: key) }
    }

    private func run(_ work: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await work()
            error = nil
        } catch Account.Failure.badRecoveryCode {
            error = String(localized: "That recovery code does not open this account.", bundle: .appLanguage, locale: .appLanguage)
        } catch Account.Failure.accountHasKeys {
            error = String(localized: "This account already has keys: restore it with its recovery code instead.", bundle: .appLanguage, locale: .appLanguage)
            status = .needsKeys
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The account steps opened over the app, outside onboarding.
enum AccountFlow: String, Identifiable {
    /// "Make an online account": from the invitation on.
    case newAccount
    /// "I already have an account", "Sign in again".
    case signIn

    var id: String { rawValue }
}

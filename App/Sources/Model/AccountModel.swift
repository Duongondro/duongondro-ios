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
    /// The code on screen outside the onboarding, right after set-up or after
    /// making a new one, or shown again from Settings; nil once confirmed or left.
    @Published var recoveryCode: String? {
        didSet { if recoveryCode != nil { recoveryUnconfirmed = true } }
    }
    /// A code was made but never confirmed (left with "Not now", or the app was
    /// closed): Settings shows it again while this launch keeps it, otherwise
    /// asks for a new one.
    @Published var recoveryUnconfirmed = UserDefaults.standard.bool(forKey: "recoveryUnconfirmed") {
        didSet { UserDefaults.standard.set(recoveryUnconfirmed, forKey: "recoveryUnconfirmed") }
    }

    /// The code was written down and checked.
    func confirmRecoveryCode() {
        recoveryCode = nil
        onShow.forget()
        recoveryUnconfirmed = false
    }

    /// Leaves the code unconfirmed ("Not now"): it is kept, as on Android, in
    /// memory for this launch, so Settings can show the same one again.
    func leaveRecoveryCode() {
        recoveryCode = nil
    }

    /// The code made this launch and left unconfirmed, on screen again. The
    /// server's boxes are sealed under it, so it is the same code, not a new one.
    func showRecoveryCodeAgain() {
        if let code = codeToShowAgain { recoveryCode = code }
    }

    /// The code left with "Not now" this launch, while Settings may still offer it.
    var codeToShowAgain: String? {
        onShow.codeToShowAgain(for: userID, unconfirmed: recoveryUnconfirmed, pending: recoveryPending)
    }

    /// The recovery code made this launch, until it is confirmed: a step shown
    /// again (Back, then forward), or Settings after "Not now", gets this one
    /// rather than a second. Only for the account it was made for: another one
    /// signed in during the same onboarding gets nil, and sets up its own keys.
    var shownCode: String? { onShow.code(for: userID) }
    @Published private var onShow = RecoveryCodeOnShow()

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

    private static let tokenName = Account.sessionTokenSecret

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
        /// An account made here whose Name, Gender and recovery code steps are not done yet.
        static let stepsPending = "account.stepsPending"
        static let all = [email, username, displayName, lastSync, "recoveryUnconfirmed", "pokedOn", pushSent, pushSentAt, stepsPending]
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
        signedInUser = result.userId
        let syncUser = (try? database.syncState())?.userID
        let setUpUser = account?.setUpUser ?? Account(api: anonymous, secrets: secrets, database: database).setUpUser
        let lastUser = UserDefaults.standard.string(forKey: Keys.lastUser).flatMap(UUID.init(uuidString:))
        let snapshot = try? database.snapshot()
        let holdsPractice = !(snapshot?.sessions.isEmpty ?? true) || !(snapshot?.practices.isEmpty ?? true)
        switch Account.plan(signingIn: result.userId, syncUser: syncUser, setUpUser: setUpUser, lastUser: lastUser,
                            holdsPractice: holdsPractice) {
        case .askAboutPractice:
            heldSignIn = result
            return false
        case .forgetOtherAccount:
            // Another account's keys, sync state and device key never carry over.
            try? database.clearSyncState()
            forgetOtherAccount()
        case .keep:
            break
        }
        keep(result)
        return true
    }

    private func keep(_ result: SignInResult) {
        email = sessionAddress
        sessionAddress = nil
        try? secrets.write(Self.tokenName, Data(result.token.utf8))
        open(token: result.token)
    }

    /// Forgets what this phone kept for the account it is switching away from:
    /// its keys and device key, its profile and gender (all but the email this
    /// sign-in was asked for), the last user, what was last synced, friends and
    /// pokes, and a recovery code on show.
    private func forgetOtherAccount() {
        Purge.deleteKeychainItems()
        passkeys = []
        passkeysLoaded = false
        userKeyKept = false
        let kept = email
        username = nil
        displayName = ""
        stepsPending = false
        recoveryCode = nil
        onShow.forget()
        recoveryUnconfirmed = false
        friends = []
        friendsLoaded = false
        pokedOn = [:]
        invites = [:]
        lastSync = nil
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
        sessionAddress = nil
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

    /// The friendship link checked by holdPendingInvite, so it is checked once.
    private var heldLink: String?

    /// A friendship link opened before sign-up goes with the sign-up as its proof,
    /// and makes the friendship once keys exist (design: Social › Open sign-up). One
    /// that no longer checks out is dropped quietly: no code is needed for an account.
    /// A link opened after the last check (on Consent, say) replaces the one held.
    func holdPendingInvite() async {
        guard let link = pendingInvite, heldLink != link.string else { return }
        if (try? await checkInvite(Invitation.code(of: link))) != nil { heldLink = link.string }
    }

    /// The held link's code is gone (expired, withdrawn): the sign-up goes on
    /// without it, and it is not offered for accepting later.
    func dropHeldInvite() {
        clearInvitation()
        if pendingInvite?.string == heldLink { pendingInvite = nil }
    }

    /// Leaving the sign-up ("Only on this phone", closing it, or signing in
    /// instead): nothing held goes with a later sign-up or sign-in.
    func forgetHeldInvite() {
        clearInvitation()
        heldLink = nil
    }

    /// Forgets an invitation from an abandoned sign-up, so a later sign-in does not carry it.
    func clearInvitation() {
        invitation = nil
        checkedInvite = nil
    }

    // MARK: Email

    enum LinkRequest {
        case sent, unknownInvite, tooMany
        /// The server makes accounts only with an invitation: back to its step.
        case invitationNeeded
        /// Too many accounts made from this network in the last hour; a code still works.
        case tooManyAccounts
    }

    enum Redeem: Equatable {
        /// Signed in; `created` when the link or passkey made the account.
        case signedIn(created: Bool)
        /// A wrong, expired, used or replaced code: the server does not say which.
        case wrong
        /// No account uses this address and the link was no sign-up; or, for a
        /// sign-up, the server stopped making accounts without an invitation.
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
    /// The address the last magic link went to, and the one the session being
    /// kept signed in with (nil for a passkey): `email` is only ever an address
    /// that signs in to this account.
    private var requestedAddress: String?
    private var sessionAddress: String?

    /// Whether an opened magic link may be redeemed now.
    func expectsLink(now: Date = Date()) -> Bool { linkWindow.expects(at: now) }

    /// `consent`: the onboarding's, which every sign-up carries; nil signs in.
    func requestMagicLink(email address: String, signUpWithConsent consent: Bool?) async throws -> LinkRequest {
        do {
            try await anonymous.requestMagicLink(email: address,
                                                 signUp: consent.map { SignUp(proof: invitation?.proof, consent: $0) })
            linkWindow.requested()
            // Kept as the account's address only once a link or code signs in.
            requestedAddress = address
            return .sent
        } catch SignUpFailure.unknownInvitation {
            return .unknownInvite
        } catch SignUpFailure.invitationNeeded {
            return .invitationNeeded
        } catch SignUpFailure.tooManyAccounts {
            return .tooManyAccounts
        } catch SignUpFailure.tooManyRequests, APIError.tooManyRequests {
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
            sessionAddress = signIn ? nil : requestedAddress
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

    /// An account made by this phone's sign-up whose Name, Gender and recovery code
    /// steps are not done: a relaunch resumes there, never at Consent or Passkey.
    @Published private(set) var stepsPending = UserDefaults.standard.bool(forKey: Keys.stepsPending) {
        didSet { UserDefaults.standard.set(stepsPending, forKey: Keys.stepsPending) }
    }

    /// The account was just made: keys are made at once, silently (design:
    /// onboarding), so the held friendship link is redeemed and the recovery code
    /// is ready by the time its step shows; that step waits for the same work.
    func accountCreated() {
        stepsPending = true
        Task { _ = try? await setUpKeys() }
    }

    /// The account steps are done: Not now, or the recovery code confirmed.
    func accountStepsDone() { stepsPending = false }

    /// Into the app without a recovery code (a new one could not be made): Settings
    /// keeps asking for one, and signing out waits for it.
    func leaveWithoutCode() { recoveryUnconfirmed = true }


    /// The display name the server holds, read after a sign-up: an account made
    /// without one is given a random "Adjective Animal" there, which the Name step
    /// offers to keep. Nil when it cannot be read.
    func serverDisplayName() async -> String? {
        guard let account, let me = try? await account.api.me() else { return nil }
        displayName = me.displayName
        email = me.email
        return me.displayName
    }

    /// After a sign-up: the name only when it was edited (nil keeps the server's,
    /// empty clears it), the gender only when given. Nothing to send, nothing sent.
    func setProfile(name: String?, gender: Gender?) async throws {
        guard let account else { throw Account.Failure.missingSecret }
        let name = name.map(Self.trimmedName)
        guard name != nil || gender != nil else { return }
        try await account.api.updateMe(displayName: name, gender: gender.map { .set($0.rawValue) } ?? .keep)
        if let name { displayName = name }
        if let gender { UserDefaults.standard.set(gender.rawValue, forKey: Gender.storageKey) }
    }

    // MARK: Email after sign-up

    enum EmailRequest { case sent, invalid, tooMany }

    /// Mails a code that adds `address` to the account as a second way to sign in.
    func requestEmail(_ address: String) async throws -> EmailRequest {
        guard let account else { throw Account.Failure.missingSecret }
        do {
            try await account.api.requestEmailConfirmation(email: address)
            return .sent
        } catch APIError.badRequest {
            return .invalid
        } catch APIError.tooManyRequests {
            return .tooMany
        }
    }

    enum EmailConfirm { case added, wrong, taken, tooMany }

    /// The typed code from that mail; `address` is kept once it signs in here.
    func confirmEmail(_ address: String, code: String) async throws -> EmailConfirm {
        guard let account else { throw Account.Failure.missingSecret }
        do {
            try await account.api.confirmEmail(code: code)
            email = address
            return .added
        } catch APIError.badRequest {
            return .wrong
        } catch APIError.conflict {
            return .taken
        } catch APIError.tooManyRequests {
            return .tooMany
        }
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
        scalars.append(contentsOf: DisplayName.clean(name).unicodeScalars.prefix(64))
        return String(scalars)
    }

    // MARK: Passkeys

    enum PasskeyResult {
        case saved, cancelled, usernameTaken, inviteGone, otherAccountData
        case invitationNeeded, tooManyAccounts, tooMany
    }

    /// Without a session, makes the account with a passkey and the profile (the
    /// no-email path), with the onboarding's consent; signed in, adds a passkey
    /// to the account.
    func createPasskey(profile: Profile?, consent: Bool) async throws -> PasskeyResult {
        if let account {
            let ceremony = try await account.api.beginPasskeyAdd()
            guard let created = try await Passkeys.create(ceremony) else { return .cancelled }
            try await account.api.finishPasskeyAdd(ceremony: ceremony.sessionId, credential: created.json)
            await coverNewPasskey(created, account: account)
            return .saved
        }
        let result: SignInResult
        do {
            let ceremony = try await anonymous.beginPasskeySignUp(SignUp(proof: invitation?.proof, consent: consent),
                                                                  profile: profile ?? Profile())
            guard let created = try await Passkeys.create(ceremony) else { return .cancelled }
            result = try await anonymous.finishPasskeySignUp(ceremony: ceremony.sessionId, credential: created.json)
            // Its box goes up once the keys exist; a passkey that gave no output at
            // creation is offered later, by the card in Settings.
            heldPRF = created.prf.map { (result.userId, PasskeyPRF(credentialID: created.credentialID, output: $0)) }
        } catch APIError.conflict {
            return .usernameTaken
        } catch SignUpFailure.unknownInvitation {
            return .inviteGone
        } catch SignUpFailure.invitationNeeded {
            return .invitationNeeded
        } catch SignUpFailure.tooManyAccounts {
            return .tooManyAccounts
        } catch SignUpFailure.tooManyRequests {
            return .tooMany
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
        guard let asserted = try await Passkeys.assert(ceremony) else { return nil }
        let redeemed = try await redeem(signIn: true) {
            try await self.anonymous.finishPasskey(ceremony: ceremony.sessionId, credential: asserted.json)
        }
        if let output = asserted.prf, let user = signedInUser {
            heldPRF = (user, PasskeyPRF(credentialID: asserted.credentialID, output: output))
        }
        return redeemed
    }

    // MARK: Passkey unlock (PRF)

    /// The PRF output of this launch's passkey ceremony, for the account it signed
    /// in or made: it opens the keys on a new phone, or becomes the passkey's box
    /// once this phone holds them. Memory only, used once.
    private var heldPRF: (user: UUID, prf: PasskeyPRF)?

    /// The account the last sign-in or sign-up was for (kept or held back).
    private var signedInUser: UUID?

    /// The PRF output held for `user`, taken.
    private func takePRF(for user: UUID?) -> PasskeyPRF? {
        defer { heldPRF = nil }
        guard let held = heldPRF, held.user == user else { return nil }
        return held.prf
    }

    /// A passkey just added in Settings: its box, from the output at creation or,
    /// when the passkey gives one only at sign-in, from one more ceremony with it.
    /// A failure leaves it for the card; the passkey itself is saved either way.
    private func coverNewPasskey(_ created: Passkeys.Created, account: Account) async {
        var prf = created.prf.map { PasskeyPRF(credentialID: created.credentialID, output: $0) }
        if prf == nil, created.prfSupported {
            prf = try? await Passkeys.prf(allowing: [created.credentialID])
        }
        if let prf { _ = try? await account.savePasskeyBox(prf) }
        await refreshPasskeys()
    }

    /// The account's passkeys, as last fetched for Settings › Passkeys.
    @Published private(set) var passkeys: [Passkey] = []
    @Published private(set) var passkeysLoaded = false

    /// The calm card in Settings: this phone holds the keys, can ask for a PRF
    /// output, and a passkey of the account cannot unlock the counts yet.
    var offersPasskeyUnlock: Bool {
        status == .ready && Passkeys.prfAvailable && passkeys.contains { !$0.canUnlock }
    }

    /// U checked once a launch, after a sync: made if the account has none,
    /// wrapped to, and given to this account's other phones.
    private var userKeyKept = false

    private func keepPasskeyUnlock(_ account: Account) async {
        if !userKeyKept { userKeyKept = (try? await account.keepUserKey()) ?? false }
        if let prf = takePRF(for: userID) { _ = try? await account.savePasskeyBox(prf) }
        await refreshPasskeys()
    }

    func refreshPasskeys() async {
        guard let account, status == .ready || status == .needsKeys else { return }
        if let list = try? await account.api.passkeys() {
            passkeys = list
            passkeysLoaded = true
        }
    }

    enum UnlockResult { case saved, cancelled, noPRF, waiting, otherAccount, failed }

    /// The card's ceremony: whichever passkey answers (no allowCredentials) gets
    /// a box of U. One system prompt; a passkey without PRF is said so.
    func letPasskeyUnlock() async -> UnlockResult {
        guard let account, status == .ready else { return .failed }
        do {
            guard let prf = try await Passkeys.prf() else { return .cancelled }
            let result = try await account.savePasskeyBox(prf)
            await refreshPasskeys()
            switch result {
            case .saved: return .saved
            case .waitingForUserKey: return .waiting
            case .otherAccountsPasskey: return .otherAccount
            }
        } catch Passkeys.Failure.noPRF {
            return .noPRF
        } catch {
            return .failed
        }
    }

    enum RemoveResult { case removed, lastWayToSignIn, failed }

    func renamePasskey(_ passkey: Passkey, to name: String) async -> Bool {
        guard let account else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await account.api.renamePasskey(passkey.id, name: trimmed.isEmpty ? nil : String(trimmed.prefix(64)))
            await refreshPasskeys()
            return true
        } catch {
            return false
        }
    }

    /// Removes a passkey, its box and the sessions it signed in with; removing
    /// the one this phone signed in with signs this phone out.
    func removePasskey(_ passkey: Passkey) async -> RemoveResult {
        guard let account else { return .failed }
        do {
            try await account.api.removePasskey(passkey.id)
        } catch APIError.conflict {
            return .lastWayToSignIn
        } catch APIError.notFound {
            // Already gone (removed on another phone).
        } catch {
            return .failed
        }
        if passkey.current {
            sessionEnded()
        } else {
            await refreshPasskeys()
        }
        return .removed
    }

    // MARK: Keys

    /// Whether the signed-in account needs setting up here, restoring, or nothing;
    /// also takes the profile as the server has it, for a sign-in on a new phone.
    func standing() async throws -> Account.Standing {
        guard let account else { throw Account.Failure.missingSecret }
        var standing = try await account.standing()
        if standing == .restore, try await unlockWithPasskey(account) { standing = .ready }
        if standing == .ready {
            status = .ready
            if heldPRF != nil { Task { await self.keepPasskeyUnlock(account) } }
        }
        if let me = try? await account.api.me() {
            if !me.displayName.isEmpty { displayName = me.displayName }
            username = me.username
            email = me.email
            if let g = me.gender { UserDefaults.standard.set(g, forKey: Gender.storageKey) }
        }
        return standing
    }

    /// A new phone signed in with a passkey that has a box: the keys come from
    /// it, no recovery code asked. False without a box or a PRF output.
    private func unlockWithPasskey(_ account: Account) async throws -> Bool {
        guard let prf = heldPRF.flatMap({ held in held.user == signedInUser ? held.prf : nil }) else { return false }
        return try await keyed {
            guard !account.hasKeys else { return true }
            do {
                guard try await account.unlock(with: prf) else { return false }
            } catch let error as URLError {
                throw error
            } catch {
                // A box or wrap that does not verify: the recovery code still can.
                return false
            }
            self.heldPRF = nil
            self.status = .ready
            self.afterKeysInBackground(account)
            return true
        }
    }

    /// Sets up keys during onboarding (or finishes an interrupted set-up, with the
    /// same code) and returns the recovery code, which the onboarding shows itself.
    /// Asked again while it runs or after, it returns the same code.
    func setUpKeys() async throws -> String {
        try await keyed {
            if let code = self.shownCode { return code }
            guard let account = self.account else { throw Account.Failure.missingSecret }
            let code = account.hasKeys ? try await account.newRecoveryCode() : try await account.setUpFirstDevice()
            // Both leave this account's sync state behind, so the user is known.
            // Should it not read back, the step says so and offers Try again,
            // rather than waiting for a code it would never be given.
            guard let user = self.userID else { throw Account.Failure.missingSecret }
            self.onShow.show(code, for: user)
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

    /// The held friendship link's friendship, once keys exist, then the fallback
    /// report and the first sync. Failures here never fail the set-up.
    private func afterKeys(_ account: Account) async {
        // Taken now: the flow may be closed (forgetting what it held) while this runs.
        let held = checkedInvite
        if let checked = held, let social {
            if let me = userID, checked.inviter != me {
                try? await social.redeem(checked)
            }
            // The link that started this sign-up is used: never offer it for accepting.
            if pendingInvite?.id == checked.link.id { pendingInvite = nil }
        }
        clearInvitation()
        await reportFallback(account)
        await syncNow()
    }

    // MARK: Keys

    func setUp() async {
        await run {
            try await self.keyed {
                // A second tap, or one after the first finished: nothing more to do.
                guard self.recoveryCode == nil, let account = self.account, !account.hasKeys else { return }
                let code = try await account.setUpFirstDevice()
                self.keepShown(code)
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

    /// A new code, asked for in Settings: it replaces the old one, and any code
    /// kept unconfirmed, on the server.
    func newRecoveryCode() async {
        await run {
            try await self.keyed {
                guard self.recoveryCode == nil, let account = self.account else { return }
                // The kept code stops being offered before any box is resealed: an
                // upload that fails half-way leaves boxes under the new code, which
                // stays pending in the Keychain and is finished by the next attempt.
                self.onShow.forget()
                self.keepShown(try await account.newRecoveryCode())
            }
        }
    }

    /// Kept for showing again until confirmed, then on screen.
    private func keepShown(_ code: String) {
        if let user = userID { onShow.show(code, for: user) } else { onShow.forget() }
        recoveryCode = code
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
            // U and the passkeys' boxes follow, never ahead of the counts.
            await keepPasskeyUnlock(account)
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
            sessionEnded()
        } catch {
            // Offline or the server is away: the data is safe here and syncs later.
            offline = true
            self.error = nil
        }
    }

    /// The session ended (removed elsewhere, or its passkey removed): keys stay,
    /// sign in again. The server dropped the push token with the session.
    private func sessionEnded() {
        try? secrets.delete(Self.tokenName)
        UserDefaults.standard.removeObject(forKey: Keys.pushSent)
        UserDefaults.standard.removeObject(forKey: Keys.pushSentAt)
        account = nil
        social = nil
        status = .signedOut
        passkeys = []
        passkeysLoaded = false
        userKeyKept = false
        // No session to finish the account steps with: sign in again instead.
        stepsPending = false
        error = nil
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
                email = me.email
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
        forgetHeldInvite()
        stepsPending = false
        heldSignIn = nil
        heldPRF = nil
        passkeys = []
        passkeysLoaded = false
        userKeyKept = false
        magicToken = nil
        linkWindow.close()
        status = .none
        lastSync = nil
        recoveryCode = nil
        onShow.forget()
        recoveryUnconfirmed = false
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
    /// "Make an online account": from the consent on.
    case newAccount
    /// An account made here whose Name, Gender and recovery code steps were left
    /// unfinished (the app closed): resumed at Name.
    case finishAccount
    /// "I already have an account", "Sign in again".
    case signIn

    var id: String { rawValue }
}

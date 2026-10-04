import CryptoKit
import DuongondroAPI
import DuongondroCore
import DuongondroCrypto
import DuongondroStore
import Foundation

/// Phase 3's keys and account, on the phone (design: Keys). The server holds
/// sealed blobs, wraps and signed statements; every secret stays here.
///
/// - First device: make the identity key and the practice key, register this
///   device, publish the signed device list, wrap both secrets to this device,
///   and seal both into recovery boxes under a new recovery code, shown once.
///   Every step can be repeated, so an interrupted set-up resumes.
/// - New phone without the old one: the recovery code opens the recovery boxes
///   (their AEAD under the code authenticates them; the seed must match the
///   account's published identity key), and the phone enrols itself.
/// Signing in alone never gives keys: a session proves an inbox, not the keys.
public final class Account: @unchecked Sendable {
    public let api: APIClient
    let secrets: SecretStore
    let deviceKeys: DeviceKeys
    let database: AppDatabase
    let now: () -> Date
    /// True once set-up or restore found a Secure Enclave that refused to make a key.
    public private(set) var deviceKeyFellBack = false

    public init(api: APIClient, secrets: SecretStore, database: AppDatabase, preferSoftwareKey: Bool = false,
                now: @escaping () -> Date = Date.init) {
        self.api = api
        self.secrets = secrets
        self.deviceKeys = DeviceKeys(store: secrets, preferSoftware: preferSoftwareKey)
        self.database = database
        self.now = now
    }

    public enum Failure: Error, Equatable {
        /// The account already has keys this phone does not hold: restore instead.
        case accountHasKeys
        /// The account has no keys yet: set it up first.
        case accountHasNoKeys
        case badRecoveryCode
        /// The recovery boxes hold an older practice key than the account uses:
        /// they were not resealed after a rotation, so they cannot restore it.
        case recoveryOutdated
        /// A box, wrap or list did not verify against the account's identity key.
        case notAuthentic
        case missingSecret
    }

    // MARK: Identity

    func identity() throws -> Curve25519.Signing.PrivateKey {
        guard let seed = try secrets.read(SecretName.identitySeed) else { throw Failure.missingSecret }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }

    func practiceKey(_ version: Int) throws -> Data {
        guard let key = try secrets.read(SecretName.practiceKey(version)) else { throw Failure.missingSecret }
        return key
    }

    public var hasKeys: Bool {
        ((try? secrets.read(SecretName.identitySeed)) ?? nil) != nil && ((try? database.syncState()) ?? nil) != nil
    }

    // MARK: First device

    /// Sets up a new account's keys on this phone, or finishes a set-up that was
    /// interrupted; returns the recovery code to show once.
    public func setUpFirstDevice() async throws -> String {
        // A finished set-up is not repeated: it would replace the recovery code.
        guard try database.syncState() == nil else { throw Failure.accountHasKeys }
        let me = try await api.me()
        let identity: Curve25519.Signing.PrivateKey
        let practiceKey: Data
        if let published = me.identityPublicKey {
            // Resuming is allowed only with the very identity the account published.
            guard let seed = try secrets.read(SecretName.identitySeed),
                  let local = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed),
                  local.publicKey.rawRepresentation == published,
                  let key = try secrets.read(SecretName.practiceKey(me.keyVersion)) else { throw Failure.accountHasKeys }
            identity = local
            practiceKey = key
        } else {
            if let seed = try secrets.read(SecretName.identitySeed) {
                identity = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            } else {
                identity = Curve25519.Signing.PrivateKey()
                try secrets.write(SecretName.identitySeed, identity.rawRepresentation)
            }
            if let key = try secrets.read(SecretName.practiceKey(me.keyVersion)) {
                practiceKey = key
            } else {
                practiceKey = SymmetricKey(size: .bits256).data
                try secrets.write(SecretName.practiceKey(me.keyVersion), practiceKey)
            }
        }

        let device = try await registerThisDevice()
        if me.identityPublicKey == nil {
            try await api.setIdentity(publicKey: identity.publicKey.rawRepresentation)
        }
        let current = try await api.deviceList()
        if !(current.flatMap { Statements.parseDeviceList($0.payload) }?.devices.contains { $0.id == device.id } ?? false) {
            try await publishDeviceList(adding: device, user: me.id, identity: identity, previous: current)
        }
        try await wrapSecrets(to: device, user: me.id, keyVersion: me.keyVersion, identity: identity, practiceKey: practiceKey)
        let code = try await putRecoveryBoxes(user: me.id, identity: identity, practiceKey: practiceKey)
        try database.saveSyncState(SyncState(userID: me.id, keyVersion: me.keyVersion))
        // Everything logged before the account existed goes up on the first sync.
        try database.markAllDirty()
        return code
    }

    // MARK: New phone, from the recovery code

    public func restore(recoveryCode: String) async throws {
        guard let recovery = RecoveryCode.decode(recoveryCode) else { throw Failure.badRecoveryCode }
        let me = try await api.me()
        guard let identityPk = me.identityPublicKey,
              let identityPublic = try? Curve25519.Signing.PublicKey(rawRepresentation: identityPk) else {
            throw Failure.accountHasNoKeys
        }
        let key = E2EE.recoveryKey(secret: recovery, user: me.id)
        let boxes = try await api.recoveryBoxes()
        func open(_ kind: E2EE.WrapKind) throws -> Data {
            guard let box = boxes.first(where: { $0.kind == Int(kind.rawValue) }) else { throw Failure.notAuthentic }
            do { return try E2EE.openRecovery(box.box, key: key, user: me.id, kind: kind) } catch { throw Failure.badRecoveryCode }
        }
        let seed = try open(.identitySeed)
        let practiceKey = try open(.practiceKey)
        let identity = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        // The seed must be the account's own: the server published its public half.
        guard identity.publicKey.rawRepresentation == identityPublic.rawRepresentation else { throw Failure.notAuthentic }
        // The box does not say which key version it holds. Check it opens the
        // account's current version, using a log sealed under that version; a box
        // left over from before a rotation would otherwise be filed as the new key.
        let version = me.keyVersion
        let page = try await api.sync(since: nil)
        if let sample = page.logs.first(where: { $0.keyVersion == version && $0.sealed != nil }) {
            let sealKey = E2EE.sealKey(practiceKey: practiceKey, user: me.id)
            guard (try? E2EE.openSession(sealKey: sealKey, session: sample.id, user: me.id, keyVersion: UInt32(version),
                                         sealed: sample.sealed!)) != nil else { throw Failure.recoveryOutdated }
        }
        try secrets.write(SecretName.identitySeed, seed)
        try secrets.write(SecretName.practiceKey(version), practiceKey)

        let device = try await registerThisDevice()
        let previous = try await api.deviceList()
        try await publishDeviceList(adding: device, user: me.id, identity: identity, previous: previous, verifyWith: identityPublic)
        try await wrapSecrets(to: device, user: me.id, keyVersion: version, identity: identity, practiceKey: practiceKey)
        try database.saveSyncState(SyncState(userID: me.id, keyVersion: version))
        try database.markAllDirty()
    }

    /// A new recovery code, replacing the old one (the old code stops working).
    public func newRecoveryCode() async throws -> String {
        guard let state = try database.syncState() else { throw Failure.accountHasNoKeys }
        try secrets.delete(SecretName.pendingRecovery)
        return try await putRecoveryBoxes(user: state.userID, identity: try identity(),
                                          practiceKey: try practiceKey(state.keyVersion))
    }

    // MARK: Steps

    struct RegisteredDevice {
        let id: UUID
        let key: DeviceKeys.Key
    }

    func registerThisDevice() async throws -> RegisteredDevice {
        let (key, fellBack) = try deviceKeys.currentOrCreate()
        deviceKeyFellBack = deviceKeyFellBack || fellBack
        let device = try await api.registerDevice(publicKey: key.publicKey, tier: key.tier)
        try secrets.write(SecretName.deviceID, Data(device.id.uuidString.utf8))
        return RegisteredDevice(id: device.id, key: key)
    }

    /// Publishes a list with this device added. The list it extends must be one
    /// this identity signed, and keeps only devices the server still has
    /// registered with the same key and tier, so a removed device is not listed
    /// again (and the server would refuse a list naming it).
    func publishDeviceList(adding device: RegisteredDevice, user: UUID, identity: Curve25519.Signing.PrivateKey,
                           previous: SignedStatement?, verifyWith: Curve25519.Signing.PublicKey? = nil) async throws {
        var devices: [Statements.ListedDevice] = []
        var version = 1
        if let previous {
            guard E2EE.verifyStatement(type: "device-list", payload: previous.payload, signature: previous.signature,
                                       identity: verifyWith ?? identity.publicKey),
                  let parsed = Statements.parseDeviceList(previous.payload) else { throw Failure.notAuthentic }
            let registered = try await api.devices()
            devices = parsed.devices.filter { listed in
                listed.id != device.id && registered.contains { $0.id == listed.id && $0.publicKey == listed.publicKey && $0.tier == listed.tier }
            }
            version = parsed.version + 1
        }
        devices.append(Statements.ListedDevice(id: device.id, publicKey: device.key.publicKey, tier: device.key.tier))
        let payload = Statements.deviceList(devices: devices, issuedAt: now(), user: user, version: version)
        let signature = try E2EE.signStatement(type: "device-list", payload: payload, identity: identity)
        try await api.putDeviceList(SignedStatement(payload: payload, signature: signature))
    }

    func wrapSecrets(to device: RegisteredDevice, user: UUID, keyVersion: Int, identity: Curve25519.Signing.PrivateKey,
                     practiceKey: Data) async throws {
        let recipient = try P256.KeyAgreement.PublicKey(x963Representation: device.key.publicKey)
        for (kind, secret) in [(E2EE.WrapKind.practiceKey, practiceKey), (.identitySeed, identity.rawRepresentation)] {
            let aad = E2EE.wrapAAD(user: user, keyVersion: UInt32(keyVersion), device: device.id, kind: kind)
            let wrapped = try E2EE.wrap(secret, to: recipient, aad: aad)
            let signature = try E2EE.signWrap(wrapped, aad: aad, recipientPk: device.key.publicKey, identity: identity)
            try await api.putWrap(WrapInput(kind: Int(kind.rawValue), keyVersion: keyVersion, ephemeralKey: wrapped.epk,
                                            box: wrapped.box, authType: .signature, authenticator: signature), device: device.id)
        }
    }

    /// Seals both secrets under a recovery code and returns it. The code is kept
    /// in the Keychain until both boxes are stored, so a failure halfway is
    /// retried with the same code rather than leaving one box under each.
    func putRecoveryBoxes(user: UUID, identity: Curve25519.Signing.PrivateKey, practiceKey: Data) async throws -> String {
        let recovery: Data
        if let pending = try secrets.read(SecretName.pendingRecovery) {
            recovery = pending
        } else {
            recovery = SymmetricKey(size: .bits128).data
            try secrets.write(SecretName.pendingRecovery, recovery)
        }
        let key = E2EE.recoveryKey(secret: recovery, user: user)
        for (kind, secret) in [(E2EE.WrapKind.practiceKey, practiceKey), (.identitySeed, identity.rawRepresentation)] {
            let box = try E2EE.sealRecovery(secret, key: key, user: user, kind: kind)
            let signature = try E2EE.signRecoveryBox(box, user: user, kind: kind, identity: identity)
            try await api.putRecoveryBox(kind: Int(kind.rawValue), RecoveryBoxInput(box: box, signature: signature))
        }
        try secrets.delete(SecretName.pendingRecovery)
        return RecoveryCode.encode(recovery)
    }

    // MARK: Key versions

    /// Fetches this device's wraps and keeps any practice-key version it does not
    /// hold yet, after checking the wrap's signature against the identity key.
    /// Returns the newest version this device now holds.
    @discardableResult
    func receiveNewerKeys(user: UUID) async throws -> Int {
        guard let idData = try secrets.read(SecretName.deviceID),
              let deviceID = UUID(uuidString: String(decoding: idData, as: UTF8.self)),
              let key = try deviceKeys.current() else { throw Failure.missingSecret }
        let identityPublic = try identity().publicKey
        var newest = (try database.syncState())?.keyVersion ?? 1
        for w in try await api.wraps(device: deviceID) where w.kind == Int(E2EE.WrapKind.practiceKey.rawValue) {
            if try secrets.read(SecretName.practiceKey(w.keyVersion)) != nil {
                newest = max(newest, w.keyVersion)
                continue
            }
            let aad = E2EE.wrapAAD(user: user, keyVersion: UInt32(w.keyVersion), device: deviceID, kind: .practiceKey)
            let wrapped = E2EE.Wrapped(epk: w.ephemeralKey, box: w.box)
            guard w.authType == .signature,
                  E2EE.verifyWrap(wrapped, aad: aad, recipientPk: key.publicKey, signature: w.authenticator, identity: identityPublic)
            else { continue }
            let secret = try E2EE.unwrap(wrapped, with: key.agreement, aad: aad)
            try secrets.write(SecretName.practiceKey(w.keyVersion), secret)
            newest = max(newest, w.keyVersion)
        }
        return newest
    }
}

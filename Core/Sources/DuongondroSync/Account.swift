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
/// - New phone without the old one: the recovery code opens the recovery boxes
///   (after checking their signatures), and the phone enrols itself.
/// Signing in alone never gives keys: a session proves an inbox, not the keys.
public final class Account: @unchecked Sendable {
    public let api: APIClient
    let secrets: SecretStore
    let deviceKeys: DeviceKeys
    let database: AppDatabase
    let now: () -> Date

    public init(api: APIClient, secrets: SecretStore, database: AppDatabase, preferSoftwareKey: Bool = false,
                now: @escaping () -> Date = Date.init) {
        self.api = api
        self.secrets = secrets
        self.deviceKeys = DeviceKeys(store: secrets, preferSoftware: preferSoftwareKey)
        self.database = database
        self.now = now
    }

    public enum Failure: Error, Equatable {
        /// The account already has keys: this phone must enrol or recover instead.
        case accountHasKeys
        /// The account has no keys yet: set it up first.
        case accountHasNoKeys
        case badRecoveryCode
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

    /// Sets up a new account's keys on this phone; returns the recovery code to show once.
    public func setUpFirstDevice() async throws -> String {
        let me = try await api.me()
        guard me.identityPublicKey == nil else { throw Failure.accountHasKeys }
        let identity = Curve25519.Signing.PrivateKey()
        let practiceKey = SymmetricKey(size: .bits256).data
        try secrets.write(SecretName.identitySeed, identity.rawRepresentation)
        try secrets.write(SecretName.practiceKey(me.keyVersion), practiceKey)

        let device = try await registerThisDevice()
        try await api.setIdentity(publicKey: identity.publicKey.rawRepresentation)
        try await publishDeviceList(adding: device, user: me.id, identity: identity, previous: nil)
        try await wrapSecrets(to: device, user: me.id, keyVersion: me.keyVersion, identity: identity, practiceKey: practiceKey)

        let recovery = SymmetricKey(size: .bits128).data
        try await putRecoveryBoxes(recovery: recovery, user: me.id, identity: identity, practiceKey: practiceKey)
        try database.saveSyncState(SyncState(userID: me.id, keyVersion: me.keyVersion))
        // Everything logged before the account existed goes up on the first sync.
        try database.markAllDirty()
        return RecoveryCode.encode(recovery)
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
        try secrets.write(SecretName.identitySeed, seed)
        // Recovery boxes hold the key version current when they were sealed; a newer
        // one arrives through wraps on the next sync.
        let boxVersion = me.keyVersion
        try secrets.write(SecretName.practiceKey(boxVersion), practiceKey)

        let device = try await registerThisDevice()
        let previous = try await api.deviceList()
        try await publishDeviceList(adding: device, user: me.id, identity: identity, previous: previous, verifyWith: identityPublic)
        try await wrapSecrets(to: device, user: me.id, keyVersion: boxVersion, identity: identity, practiceKey: practiceKey)
        try database.saveSyncState(SyncState(userID: me.id, keyVersion: boxVersion))
        try database.markAllDirty()
    }

    /// A new recovery code, replacing the old one (the old code stops working).
    public func newRecoveryCode() async throws -> String {
        guard let state = try database.syncState() else { throw Failure.accountHasNoKeys }
        let recovery = SymmetricKey(size: .bits128).data
        try await putRecoveryBoxes(recovery: recovery, user: state.userID, identity: try identity(),
                                   practiceKey: try practiceKey(state.keyVersion))
        return RecoveryCode.encode(recovery)
    }

    // MARK: Steps

    struct RegisteredDevice {
        let id: UUID
        let key: DeviceKeys.Key
    }

    func registerThisDevice() async throws -> RegisteredDevice {
        let key = try deviceKeys.currentOrCreate()
        let device = try await api.registerDevice(publicKey: key.publicKey, tier: key.tier)
        try secrets.write(SecretName.deviceID, Data(device.id.uuidString.utf8))
        return RegisteredDevice(id: device.id, key: key)
    }

    func publishDeviceList(adding device: RegisteredDevice, user: UUID, identity: Curve25519.Signing.PrivateKey,
                           previous: SignedStatement?, verifyWith: Curve25519.Signing.PublicKey? = nil) async throws {
        var devices: [Statements.ListedDevice] = []
        var version = 1
        if let previous {
            // Extend only a list this identity really signed.
            guard E2EE.verifyStatement(type: "device-list", payload: previous.payload, signature: previous.signature,
                                       identity: verifyWith ?? identity.publicKey),
                  let parsed = Statements.parseDeviceList(previous.payload) else { throw Failure.notAuthentic }
            devices = parsed.devices.filter { $0.id != device.id }
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

    func putRecoveryBoxes(recovery: Data, user: UUID, identity: Curve25519.Signing.PrivateKey, practiceKey: Data) async throws {
        let key = E2EE.recoveryKey(secret: recovery, user: user)
        for (kind, secret) in [(E2EE.WrapKind.practiceKey, practiceKey), (.identitySeed, identity.rawRepresentation)] {
            let box = try E2EE.sealRecovery(secret, key: key, user: user, kind: kind)
            let signature = try E2EE.signRecoveryBox(box, user: user, kind: kind, identity: identity)
            try await api.putRecoveryBox(kind: Int(kind.rawValue), RecoveryBoxInput(box: box, signature: signature))
        }
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

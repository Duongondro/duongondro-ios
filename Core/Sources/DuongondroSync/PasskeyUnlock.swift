import CryptoKit
import DuongondroAPI
import DuongondroCore
import DuongondroCrypto
import Foundation

/// What a passkey ceremony asked with the PRF input gave back: the passkey's raw
/// credential id and its 32-byte PRF output. Kept in memory only, never stored.
public struct PasskeyPRF: Equatable, Sendable {
    public let credentialID: Data
    public let output: Data
    public init(credentialID: Data, output: Data) {
        self.credentialID = credentialID
        self.output = output
    }

    /// The credential id as the server names it in paths and lists.
    public var credentialKey: String { WebAuthn.base64URL(credentialID) }
}

extension SecretName {
    /// U as this phone holds it: id, version and the private scalar.
    static let userKey = "user-key"
    /// The devices this phone gave U to, as kind 4 wraps.
    static let userKeyShared = "user-key-shared"
}

/// Passkey unlock (design: Keys › Passkeys that unlock the counts; docs/crypto.md
/// › Passkey unlock). A user key U sits between passkeys and the keys: the
/// practice key and the identity seed are wrapped to U as to a device, and U's
/// scalar is sealed once per passkey under its PRF output.
///
/// - A phone holding the keys creates U only when the server has none (a
///   conditional create: the first phone wins; 409 means another phone did, and
///   U reaches this one later as a kind 4 wrap). It never replaces an existing U.
/// - The phone holding U gives it to the account's other phones (kind 4), so any
///   of them can add a passkey's box.
/// - A new phone signing in with a passkey that has a box opens U with the PRF
///   output, then the seed and the practice key, and enrols as after recovery.
extension Account {
    struct HeldUserKey: Codable, Equatable {
        let id: UUID
        let version: Int
        let scalar: Data

        var privateKey: P256.KeyAgreement.PrivateKey {
            get throws { try P256.KeyAgreement.PrivateKey(rawRepresentation: scalar) }
        }
    }

    func heldUserKey() throws -> HeldUserKey? {
        guard let data = try secrets.read(SecretName.userKey) else { return nil }
        return try JSONDecoder().decode(HeldUserKey.self, from: data)
    }

    private func hold(_ key: HeldUserKey) throws {
        try secrets.write(SecretName.userKey, try JSONEncoder().encode(key))
    }

    private func forgetUserKey() throws {
        try secrets.delete(SecretName.userKey)
        try secrets.delete(SecretName.userKeyShared)
    }

    /// U's statement, checked against the account's identity key before anything
    /// is wrapped to it or opened with it: the server cannot slip in a key of its own.
    func verifiedUserKey(_ state: UserKeyState, user: UUID, identity: Curve25519.Signing.PublicKey) throws -> Statements.UserKey {
        guard E2EE.verifyStatement(type: "user-key", payload: state.statement.payload, signature: state.statement.signature,
                                   identity: identity),
              let key = Statements.parseUserKey(state.statement.payload),
              key.user == user, key.id == state.id, key.version == state.version,
              key.publicKey.count == E2EE.publicKeySize else { throw Failure.notAuthentic }
        return key
    }

    // MARK: Keeping U, on a phone with the keys

    /// After a sync, on a phone holding the keys: makes sure the account has a U,
    /// that this phone holds it, that the keys are wrapped to it, and that the
    /// account's other phones have it. True when this phone holds the current U;
    /// false while it waits for another phone's U to reach it.
    @discardableResult
    public func keepUserKey() async throws -> Bool {
        guard let state = try database.syncState() else { throw Failure.accountHasNoKeys }
        let identity = try identity()
        let user = state.userID
        guard let current = try await api.userKey() else {
            return try await createUserKey(user: user, identity: identity, keyVersion: state.keyVersion)
        }
        let key = try verifiedUserKey(current, user: user, identity: identity.publicKey)
        var held = try heldUserKey()
        if let h = held, h.id != key.id {
            // Another phone's U won, or replaced this one: this one is useless now.
            try forgetUserKey()
            held = nil
        }
        if held == nil { held = try await receiveUserKey(key, user: user, identity: identity.publicKey) }
        guard let held else { return false }
        try await wrapKeys(to: key, already: current.wraps, user: user, identity: identity, keyVersion: state.keyVersion)
        try await shareUserKey(key, held: held, user: user, identity: identity)
        return true
    }

    /// A new U, published only if the account has none. It is kept here before it
    /// goes up, so an interrupted create resumes with the same key.
    private func createUserKey(user: UUID, identity: Curve25519.Signing.PrivateKey, keyVersion: Int) async throws -> Bool {
        let held: HeldUserKey
        if let kept = try heldUserKey() {
            held = kept
        } else {
            held = HeldUserKey(id: UUID.v7(), version: 1, scalar: P256.KeyAgreement.PrivateKey().rawRepresentation)
            try hold(held)
        }
        let key = Statements.UserKey(id: held.id, publicKey: try held.privateKey.publicKey.x963Representation,
                                     user: user, version: held.version)
        let payload = Statements.userKey(key)
        let signature = try E2EE.signStatement(type: "user-key", payload: payload, identity: identity)
        switch try await api.createUserKey(SignedStatement(payload: payload, signature: signature)) {
        case .exists:
            // Another phone published one first: never replace it; it comes here
            // as a kind 4 wrap from a phone that holds it.
            try forgetUserKey()
            return false
        case .created:
            try await wrapKeys(to: key, already: [], user: user, identity: identity, keyVersion: keyVersion)
            try await shareUserKey(key, held: held, user: user, identity: identity)
            return true
        }
    }

    /// The practice key (current version) and the identity seed wrapped to U,
    /// unless they are there already.
    private func wrapKeys(to key: Statements.UserKey, already: [UserKeyWrap], user: UUID,
                          identity: Curve25519.Signing.PrivateKey, keyVersion: Int) async throws {
        let has = { (kind: E2EE.WrapKind, version: Int?) in
            already.contains { $0.userKeyId == key.id && $0.kind == Int(kind.rawValue) && (version == nil || $0.keyVersion == version) }
        }
        if !has(.practiceKey, keyVersion) {
            try await api.putUserKeyWrap(try Self.wrapToUserKey(try practiceKey(keyVersion), kind: .practiceKey, key: key,
                                                                user: user, keyVersion: keyVersion, identity: identity))
        }
        if !has(.identitySeed, nil) {
            try await api.putUserKeyWrap(try Self.wrapToUserKey(identity.rawRepresentation, kind: .identitySeed, key: key,
                                                                user: user, keyVersion: keyVersion, identity: identity))
        }
    }

    /// A secret wrapped to U, as to a device with U's id in its place; always signed.
    static func wrapToUserKey(_ secret: Data, kind: E2EE.WrapKind, key: Statements.UserKey, user: UUID, keyVersion: Int,
                              identity: Curve25519.Signing.PrivateKey) throws -> UserKeyWrapInput {
        let aad = E2EE.wrapAAD(user: user, keyVersion: UInt32(keyVersion), device: key.id, kind: kind)
        let wrapped = try E2EE.wrap(secret, to: try P256.KeyAgreement.PublicKey(x963Representation: key.publicKey), aad: aad)
        let signature = try E2EE.signWrap(wrapped, aad: aad, recipientPk: key.publicKey, identity: identity)
        return UserKeyWrapInput(userKeyId: key.id, kind: Int(kind.rawValue), keyVersion: keyVersion,
                                ephemeralKey: wrapped.epk, box: wrapped.box, signature: signature)
    }

    /// For a practice-key rotation: the new key wrapped to U, which the server
    /// requires while U holds the current one. Nil when this phone holds no U.
    public func rotationWrapToUserKey(newKey: Data, newVersion: Int) async throws -> UserKeyWrapInput? {
        guard let state = try database.syncState(), let held = try heldUserKey(),
              let current = try await api.userKey(), current.id == held.id else { return nil }
        let identity = try identity()
        let key = try verifiedUserKey(current, user: state.userID, identity: identity.publicKey)
        return try Self.wrapToUserKey(newKey, kind: .practiceKey, key: key, user: state.userID, keyVersion: newVersion,
                                      identity: identity)
    }

    // MARK: U between phones (kind 4)

    private struct Shared: Codable {
        let userKey: UUID
        var devices: Set<UUID>
    }

    /// Gives U to each device in the signed list that does not have it from this
    /// phone yet, as a signed kind 4 wrap at U's version.
    private func shareUserKey(_ key: Statements.UserKey, held: HeldUserKey, user: UUID,
                              identity: Curve25519.Signing.PrivateKey) async throws {
        guard let list = try await api.deviceList(),
              E2EE.verifyStatement(type: "device-list", payload: list.payload, signature: list.signature, identity: identity.publicKey),
              let devices = Statements.parseDeviceList(list.payload)?.devices else { return }
        var shared = (try secrets.read(SecretName.userKeyShared)).flatMap { try? JSONDecoder().decode(Shared.self, from: $0) }
        if shared?.userKey != key.id { shared = Shared(userKey: key.id, devices: []) }
        let me = deviceID
        for device in devices where device.id != me && !(shared!.devices.contains(device.id)) {
            let aad = E2EE.wrapAAD(user: user, keyVersion: UInt32(key.version), device: device.id, kind: .userKey)
            let wrapped = try E2EE.wrap(held.scalar, to: try P256.KeyAgreement.PublicKey(x963Representation: device.publicKey), aad: aad)
            let signature = try E2EE.signWrap(wrapped, aad: aad, recipientPk: device.publicKey, identity: identity)
            try await api.putWrap(WrapInput(kind: Int(E2EE.WrapKind.userKey.rawValue), keyVersion: key.version,
                                            ephemeralKey: wrapped.epk, box: wrapped.box, authType: .signature,
                                            authenticator: signature), device: device.id)
            shared!.devices.insert(device.id)
            try secrets.write(SecretName.userKeyShared, try JSONEncoder().encode(shared!))
        }
    }

    /// U from a kind 4 wrap to this device, checked by signature and against the
    /// signed public key; nil when none has arrived yet.
    private func receiveUserKey(_ key: Statements.UserKey, user: UUID,
                                identity: Curve25519.Signing.PublicKey) async throws -> HeldUserKey? {
        guard let deviceID, let device = try deviceKeys.current() else { return nil }
        let aad = E2EE.wrapAAD(user: user, keyVersion: UInt32(key.version), device: deviceID, kind: .userKey)
        for w in try await api.wraps(device: deviceID)
        where w.kind == Int(E2EE.WrapKind.userKey.rawValue) && w.keyVersion == key.version && w.authType == .signature {
            let wrapped = E2EE.Wrapped(epk: w.ephemeralKey, box: w.box)
            guard E2EE.verifyWrap(wrapped, aad: aad, recipientPk: device.publicKey, signature: w.authenticator, identity: identity),
                  let scalar = try? E2EE.unwrap(wrapped, with: device.agreement, aad: aad),
                  (try? E2EE.userKey(scalar: scalar, expectedPublicKey: key.publicKey)) != nil else { continue }
            let held = HeldUserKey(id: key.id, version: key.version, scalar: scalar)
            try hold(held)
            return held
        }
        return nil
    }

    // MARK: A passkey's box

    public enum BoxResult: Equatable, Sendable {
        case saved
        /// Another phone's U has not reached this one yet: try after it syncs.
        case waitingForUserKey
        /// The passkey that answered is not this account's.
        case otherAccountsPasskey
    }

    /// Seals U under a passkey's PRF output and stores it as that passkey's box,
    /// creating U first if the account has none.
    public func savePasskeyBox(_ prf: PasskeyPRF) async throws -> BoxResult {
        guard try await keepUserKey(), let held = try heldUserKey(), let state = try database.syncState() else {
            return .waitingForUserKey
        }
        let box = try Self.passkeyBox(prf, held: held, user: state.userID, identity: try identity())
        do {
            try await api.putPasskeyBox(credential: prf.credentialKey, box)
        } catch APIError.notFound {
            return .otherAccountsPasskey
        }
        return .saved
    }

    static func passkeyBox(_ prf: PasskeyPRF, held: HeldUserKey, user: UUID,
                           identity: Curve25519.Signing.PrivateKey) throws -> PasskeyBoxInput {
        let aad = E2EE.prfAAD(user: user, userKey: held.id, credentialID: prf.credentialID)
        let box = try E2EE.sealPasskeyBox(held.scalar, key: E2EE.prfKey(output: prf.output, user: user), aad: aad)
        return PasskeyBoxInput(userKeyId: held.id, box: box, signature: try E2EE.signPasskeyBox(box, aad: aad, identity: identity))
    }

    // MARK: A new phone, from a passkey

    /// Brings the keys to this phone from the passkey just signed in with: no
    /// recovery code. False when this passkey cannot unlock the counts (no box,
    /// or one its PRF output does not open, or no wrap of the current practice
    /// key), so the recovery code is asked instead; throws when something does
    /// not verify against the account's identity key.
    public func unlock(with prf: PasskeyPRF) async throws -> Bool {
        let me = try await api.me()
        guard let identityPk = me.identityPublicKey,
              let identityPublic = try? Curve25519.Signing.PublicKey(rawRepresentation: identityPk) else {
            throw Failure.accountHasNoKeys
        }
        guard let unlock = try await api.passkeyUnlock(credential: prf.credentialKey) else { return false }
        let key = try verifiedUserKey(unlock.userKey, user: me.id, identity: identityPublic)
        let aad = E2EE.prfAAD(user: me.id, userKey: key.id, credentialID: prf.credentialID)
        guard E2EE.verifyPasskeyBox(unlock.box, aad: aad, signature: unlock.signature, identity: identityPublic) else {
            throw Failure.notAuthentic
        }
        guard let scalar = try? E2EE.openPasskeyBox(unlock.box, key: E2EE.prfKey(output: prf.output, user: me.id), aad: aad) else {
            return false
        }
        let u = try E2EE.userKey(scalar: scalar, expectedPublicKey: key.publicKey)

        func open(_ kind: E2EE.WrapKind, version: Int?) throws -> Data? {
            guard let w = unlock.userKey.wraps.first(where: {
                $0.userKeyId == key.id && $0.kind == Int(kind.rawValue) && (version == nil || $0.keyVersion == version)
            }) else { return nil }
            let wrapAAD = E2EE.wrapAAD(user: me.id, keyVersion: UInt32(w.keyVersion), device: key.id, kind: kind)
            let wrapped = E2EE.Wrapped(epk: w.ephemeralKey, box: w.box)
            guard E2EE.verifyWrap(wrapped, aad: wrapAAD, recipientPk: key.publicKey, signature: w.signature, identity: identityPublic)
            else { throw Failure.notAuthentic }
            return try E2EE.unwrap(wrapped, with: u, aad: wrapAAD)
        }
        guard let seed = try open(.identitySeed, version: nil),
              let practiceKey = try open(.practiceKey, version: me.keyVersion) else { return false }
        let identity = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        // The seed must be the account's own: the server published its public half.
        guard identity.publicKey.rawRepresentation == identityPk else { throw Failure.notAuthentic }

        try hold(HeldUserKey(id: key.id, version: key.version, scalar: scalar))
        try await enrol(user: me.id, identity: identity, identityPublic: identityPublic, practiceKey: practiceKey,
                        version: me.keyVersion)
        return true
    }
}

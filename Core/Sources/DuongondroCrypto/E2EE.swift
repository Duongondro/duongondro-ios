import CryptoKit
import Foundation

/// The byte formats of duongondro-api's docs/crypto.md, in CryptoKit. The Go
/// package internal/e2ee is the reference; testdata/vectors.json (copied into
/// the tests unchanged) pins every output here to it.
///
/// HKDF is HKDF-SHA256 with 32-byte output; AEAD is ChaCha20-Poly1305 with a
/// 12-byte random nonce stored in front of the ciphertext; device keys are on
/// NIST P-256 (nicknamed the glowie curve in prose); identity keys are Ed25519.
public enum E2EE {
    public static let labelSeal = "duongondro/v1/seal"
    public static let labelWrap = "duongondro/v1/wrap"
    public static let labelWrapSig = "duongondro/v1/wrap-sig"
    public static let labelEnrolAuth = "duongondro/v1/enrol-auth"
    public static let labelSelfAuth = "duongondro/v1/self-auth"
    public static let labelInviteAuth = "duongondro/v1/invite-auth"
    public static let labelInvitePin = "duongondro/v1/invite-pin"
    public static let labelRecovery = "duongondro/v1/recovery"
    public static let labelRecoverySig = "duongondro/v1/recovery-sig"
    static let statementPrefix = "duongondro/v1/"

    public static let keySize = 32
    public static let nonceSize = 12
    public static let tagSize = 16
    public static let publicKeySize = 65
    public static let wrappedBoxSize = nonceSize + keySize + tagSize
    static let padBlock = 256

    public enum Failure: Error, Equatable {
        case open, padding, size, signature, tag
    }

    /// What a wrap carries: the practice key, the identity seed, or a share key.
    public enum WrapKind: UInt8, Sendable {
        case practiceKey = 1, identitySeed = 2, shareKey = 3
    }

    // MARK: Building blocks

    public static func derive(_ ikm: some DataProtocol, salt: some DataProtocol, info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(ikm)), salt: Data(salt),
                               info: Data(info.utf8), outputByteCount: keySize)
    }

    static func seal(_ key: SymmetricKey, _ plaintext: Data, aad: Data, nonce: Data? = nil) throws -> Data {
        let n = try nonce.map { try ChaChaPoly.Nonce(data: $0) } ?? ChaChaPoly.Nonce()
        return try ChaChaPoly.seal(plaintext, using: key, nonce: n, authenticating: aad).combined
    }

    static func open(_ key: SymmetricKey, _ box: Data, aad: Data) throws -> Data {
        guard box.count >= nonceSize + tagSize else { throw Failure.size }
        do {
            return try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: box), using: key, authenticating: aad)
        } catch {
            throw Failure.open
        }
    }

    static func mac(_ key: SymmetricKey, _ message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
    }

    /// Constant-time comparison of two tags.
    public static func equalTags(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func uint32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }

    // MARK: Sealed sessions

    public static func sealKey(practiceKey: Data, user: UUID) -> SymmetricKey {
        derive(practiceKey, salt: user.bytes, info: labelSeal)
    }

    /// uuid(session) ‖ uuid(user) ‖ u32be(keyVersion): 36 bytes.
    public static func sessionAAD(session: UUID, user: UUID, keyVersion: UInt32) -> Data {
        session.bytes + user.bytes + uint32(keyVersion)
    }

    /// json ‖ 0x80 ‖ zero bytes up to the next multiple of 256, which hides the
    /// length of notes from the server.
    public static func pad(_ data: Data) -> Data {
        var out = data
        out.append(0x80)
        let rest = (padBlock - out.count % padBlock) % padBlock
        out.append(Data(count: rest))
        return out
    }

    public static func unpad(_ data: Data) throws -> Data {
        guard let i = data.lastIndex(where: { $0 != 0 }), data[i] == 0x80 else { throw Failure.padding }
        return data[data.startIndex..<i]
    }

    public static func sealSession(sealKey: SymmetricKey, session: UUID, user: UUID, keyVersion: UInt32,
                                   json: Data, nonce: Data? = nil) throws -> Data {
        try seal(sealKey, pad(json), aad: sessionAAD(session: session, user: user, keyVersion: keyVersion), nonce: nonce)
    }

    public static func openSession(sealKey: SymmetricKey, session: UUID, user: UUID, keyVersion: UInt32,
                                   sealed: Data) throws -> Data {
        try unpad(open(sealKey, sealed, aad: sessionAAD(session: session, user: user, keyVersion: keyVersion)))
    }

    // MARK: Wraps

    /// uuid(user) ‖ u32be(keyVersion) ‖ uuid(recipientDevice) ‖ u8(kind): 37 bytes.
    public static func wrapAAD(user: UUID, keyVersion: UInt32, device: UUID, kind: WrapKind) -> Data {
        user.bytes + uint32(keyVersion) + device.bytes + Data([kind.rawValue])
    }

    static func wrapKey(shared: Data, epk: Data, recipientPk: Data) -> SymmetricKey {
        derive(shared, salt: epk + recipientPk, info: labelWrap)
    }

    public struct Wrapped: Equatable, Sendable {
        public let epk: Data
        public let box: Data
    }

    /// Wraps a 32-byte secret to a device's public key with a fresh ephemeral key
    /// (or a given one, for test vectors only).
    public static func wrap(_ secret: Data, to recipient: P256.KeyAgreement.PublicKey, aad: Data,
                            ephemeral: P256.KeyAgreement.PrivateKey = .init(), nonce: Data? = nil) throws -> Wrapped {
        guard secret.count == keySize else { throw Failure.size }
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient).data
        let epk = ephemeral.publicKey.x963Representation
        let box = try seal(wrapKey(shared: shared, epk: epk, recipientPk: recipient.x963Representation),
                           secret, aad: aad, nonce: nonce)
        return Wrapped(epk: epk, box: box)
    }

    /// Opens a wrap with the device's own key agreement (a Secure Enclave key or a
    /// software one). The caller verifies the wrap's authenticator first.
    public static func unwrap(_ wrapped: Wrapped, with recipient: some DeviceKeyAgreement, aad: Data) throws -> Data {
        guard wrapped.epk.count == publicKeySize, wrapped.box.count == wrappedBoxSize else { throw Failure.size }
        let epk = try P256.KeyAgreement.PublicKey(x963Representation: wrapped.epk)
        let shared = try recipient.sharedSecret(with: epk)
        return try open(wrapKey(shared: shared, epk: wrapped.epk, recipientPk: recipient.publicKeyX963),
                        wrapped.box, aad: aad)
    }

    static func authenticated(_ w: Wrapped, aad: Data, recipientPk: Data) -> Data {
        w.epk + w.box + aad + recipientPk
    }

    public static func wrapSignatureMessage(_ w: Wrapped, aad: Data, recipientPk: Data) -> Data {
        Data(labelWrapSig.utf8) + authenticated(w, aad: aad, recipientPk: recipientPk)
    }

    public static func signWrap(_ w: Wrapped, aad: Data, recipientPk: Data,
                                identity: Curve25519.Signing.PrivateKey) throws -> Data {
        try identity.signature(for: wrapSignatureMessage(w, aad: aad, recipientPk: recipientPk))
    }

    public static func verifyWrap(_ w: Wrapped, aad: Data, recipientPk: Data, signature: Data,
                                  identity: Curve25519.Signing.PublicKey) -> Bool {
        identity.isValidSignature(signature, for: wrapSignatureMessage(w, aad: aad, recipientPk: recipientPk))
    }

    /// A new device's first wrap, keyed from the secret in its enrolment QR code.
    public static func enrolTag(qrSecret: Data, _ w: Wrapped, aad: Data, recipientPk: Data) -> Data {
        mac(derive(qrSecret, salt: recipientPk, info: labelEnrolAuth), authenticated(w, aad: aad, recipientPk: recipientPk))
    }

    /// A device wrapping to itself: keyed from ECDH(d, d·G).
    public static func selfTag(selfShared: Data, user: UUID, _ w: Wrapped, aad: Data, recipientPk: Data) -> Data {
        mac(derive(selfShared, salt: user.bytes, info: labelSelfAuth), authenticated(w, aad: aad, recipientPk: recipientPk))
    }

    // MARK: Signed statements

    /// "duongondro/v1/" ‖ type ‖ "\n" ‖ payload.
    public static func statementMessage(type: String, payload: Data) -> Data {
        Data((statementPrefix + type + "\n").utf8) + payload
    }

    public static func signStatement(type: String, payload: Data, identity: Curve25519.Signing.PrivateKey) throws -> Data {
        try identity.signature(for: statementMessage(type: type, payload: payload))
    }

    /// Checks the signature over the exact bytes received, before anything parses them.
    public static func verifyStatement(type: String, payload: Data, signature: Data,
                                       identity: Curve25519.Signing.PublicKey) -> Bool {
        identity.isValidSignature(signature, for: statementMessage(type: type, payload: payload))
    }

    // MARK: Invitations

    /// auth goes to the server (which keeps a hash); pin never leaves phones.
    public static func inviteKeys(secret: Data) -> (auth: Data, pin: Data) {
        (derive(secret, salt: Data(), info: labelInviteAuth).data, derive(secret, salt: Data(), info: labelInvitePin).data)
    }

    /// HMAC(pin, inviterIdentityPk): the invitee checks it before trusting the key.
    public static func inviteMAC(pin: Data, inviterIdentityPk: Data) -> Data {
        mac(SymmetricKey(data: pin), inviterIdentityPk)
    }

    // MARK: Recovery

    public static func recoveryKey(secret: Data, user: UUID) -> SymmetricKey {
        derive(secret, salt: user.bytes, info: labelRecovery)
    }

    public static func recoveryAAD(user: UUID, kind: WrapKind) -> Data { user.bytes + Data([kind.rawValue]) }

    public static func sealRecovery(_ secret: Data, key: SymmetricKey, user: UUID, kind: WrapKind,
                                    nonce: Data? = nil) throws -> Data {
        try seal(key, secret, aad: recoveryAAD(user: user, kind: kind), nonce: nonce)
    }

    public static func openRecovery(_ box: Data, key: SymmetricKey, user: UUID, kind: WrapKind) throws -> Data {
        try open(key, box, aad: recoveryAAD(user: user, kind: kind))
    }

    public static func recoveryBoxMessage(user: UUID, kind: WrapKind, box: Data) -> Data {
        Data(labelRecoverySig.utf8) + user.bytes + Data([kind.rawValue]) + box
    }

    public static func signRecoveryBox(_ box: Data, user: UUID, kind: WrapKind,
                                       identity: Curve25519.Signing.PrivateKey) throws -> Data {
        try identity.signature(for: recoveryBoxMessage(user: user, kind: kind, box: box))
    }

    public static func verifyRecoveryBox(_ box: Data, user: UUID, kind: WrapKind, signature: Data,
                                         identity: Curve25519.Signing.PublicKey) -> Bool {
        identity.isValidSignature(signature, for: recoveryBoxMessage(user: user, kind: kind, box: box))
    }
}

/// A device key that can agree on a secret: a Secure Enclave key, or a software
/// one where the enclave is unavailable (the Simulator).
public protocol DeviceKeyAgreement {
    var publicKeyX963: Data { get }
    func sharedSecret(with other: P256.KeyAgreement.PublicKey) throws -> Data
}

extension P256.KeyAgreement.PrivateKey: DeviceKeyAgreement {
    public var publicKeyX963: Data { publicKey.x963Representation }
    public func sharedSecret(with other: P256.KeyAgreement.PublicKey) throws -> Data {
        try sharedSecretFromKeyAgreement(with: other).data
    }
}

extension SecureEnclave.P256.KeyAgreement.PrivateKey: DeviceKeyAgreement {
    public var publicKeyX963: Data { publicKey.x963Representation }
    public func sharedSecret(with other: P256.KeyAgreement.PublicKey) throws -> Data {
        try sharedSecretFromKeyAgreement(with: other).data
    }
}

extension SharedSecret {
    /// The raw 32-byte x coordinate, as Go's crypto/ecdh returns it.
    var data: Data { withUnsafeBytes { Data($0) } }
}

extension SymmetricKey {
    public var data: Data { withUnsafeBytes { Data($0) } }
}

extension UUID {
    /// The 16 raw bytes.
    public var bytes: Data { withUnsafeBytes(of: uuid) { Data($0) } }

    public init?(bytes: Data) {
        guard bytes.count == 16 else { return nil }
        let b = [UInt8](bytes)
        self.init(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

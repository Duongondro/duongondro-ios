import CryptoKit
import XCTest
@testable import DuongondroCrypto

/// Every output of docs/crypto.md, reproduced from the inputs in
/// duongondro-api/testdata/vectors.json (copied here unchanged; refresh it from
/// there, never edit it). CryptoKit's Ed25519 signatures are randomised, so the
/// vectors' signatures are verified rather than reproduced.
final class VectorTests: XCTestCase {
    struct Vectors: Decodable {
        struct Inputs: Decodable {
            let practiceKey, user, session, recipientDevice, identitySeed, identityPublic: String
            let recipientPrivate, recipientPublic, ephemeralPrivate, ephemeralPublic: String
            let nonce, recoverySecret, inviteSecret, qrSecret: String
            let keyVersion: UInt32
        }
        struct Session: Decodable { let json, aad, padded, sealed: String }
        struct Wrap: Decodable {
            let name: String
            let kind: UInt8
            let aad, shared, wrapKey, epk, box, signature, enrolTag, selfShared, selfTag: String
        }
        struct Statement: Decodable { let type, payload, message, signature: String }
        struct Invite: Decodable { let auth, pin, mac: String }
        struct Recovery: Decodable { let recoveryKey, aad, practiceKeyBox, practiceKeyBoxSignature: String }
        let inputs: Inputs
        let derived: [String: String]
        let session: Session
        let wraps: [Wrap]
        let statements: [Statement]
        let invite: Invite
        let recovery: Recovery
    }

    var v: Vectors!

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "vectors", withExtension: "json", subdirectory: "Resources"))
        v = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    func hex(_ s: String) -> Data {
        var data = Data(capacity: s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            data.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return data
    }

    func uuid(_ s: String) -> UUID { UUID(bytes: hex(s))! }

    var user: UUID { uuid(v.inputs.user) }

    func testSealedSession() throws {
        let sealKey = E2EE.sealKey(practiceKey: hex(v.inputs.practiceKey), user: user)
        XCTAssertEqual(sealKey.data, hex(v.derived["sealKey"]!))
        let session = uuid(v.inputs.session)
        XCTAssertEqual(E2EE.sessionAAD(session: session, user: user, keyVersion: 1), hex(v.session.aad))
        let json = Data(v.session.json.utf8)
        XCTAssertEqual(E2EE.pad(json), hex(v.session.padded))
        let sealed = try E2EE.sealSession(sealKey: sealKey, session: session, user: user, keyVersion: 1,
                                          json: json, nonce: hex(v.inputs.nonce))
        XCTAssertEqual(sealed, hex(v.session.sealed))
        XCTAssertEqual(try E2EE.openSession(sealKey: sealKey, session: session, user: user, keyVersion: 1, sealed: sealed), json)
        // The AAD binds the blob to its session, user and key version.
        XCTAssertThrowsError(try E2EE.openSession(sealKey: sealKey, session: user, user: user, keyVersion: 1, sealed: sealed))
        XCTAssertThrowsError(try E2EE.openSession(sealKey: sealKey, session: session, user: user, keyVersion: 2, sealed: sealed))
    }

    func testPaddingRoundTripsAndRejectsGarbage() throws {
        for n in [0, 1, 254, 255, 256, 600] {
            let data = Data(repeating: 0x41, count: n)
            let padded = E2EE.pad(data)
            XCTAssertEqual(padded.count % 256, 0)
            XCTAssertEqual(try E2EE.unpad(padded), data)
        }
        XCTAssertThrowsError(try E2EE.unpad(Data(count: 256)))
    }

    func testWraps() throws {
        let recipient = try P256.KeyAgreement.PrivateKey(rawRepresentation: hex(v.inputs.recipientPrivate))
        XCTAssertEqual(recipient.publicKey.x963Representation, hex(v.inputs.recipientPublic))
        let ephemeral = try P256.KeyAgreement.PrivateKey(rawRepresentation: hex(v.inputs.ephemeralPrivate))
        XCTAssertEqual(ephemeral.publicKey.x963Representation, hex(v.inputs.ephemeralPublic))
        let identity = try Curve25519.Signing.PrivateKey(rawRepresentation: hex(v.inputs.identitySeed))
        XCTAssertEqual(identity.publicKey.rawRepresentation, hex(v.inputs.identityPublic))
        let rpk = recipient.publicKey.x963Representation
        let secrets: [UInt8: Data] = [1: hex(v.inputs.practiceKey), 2: hex(v.inputs.identitySeed)]

        for w in v.wraps {
            let kind = try XCTUnwrap(E2EE.WrapKind(rawValue: w.kind))
            let aad = E2EE.wrapAAD(user: user, keyVersion: 1, device: uuid(v.inputs.recipientDevice), kind: kind)
            XCTAssertEqual(aad, hex(w.aad), w.name)
            XCTAssertEqual(try ephemeral.sharedSecret(with: recipient.publicKey), hex(w.shared), w.name)
            XCTAssertEqual(E2EE.wrapKey(shared: hex(w.shared), epk: hex(w.epk), recipientPk: rpk).data, hex(w.wrapKey), w.name)

            let wrapped = try E2EE.wrap(secrets[w.kind]!, to: recipient.publicKey, aad: aad,
                                        ephemeral: ephemeral, nonce: hex(v.inputs.nonce))
            XCTAssertEqual(wrapped.epk, hex(w.epk), w.name)
            XCTAssertEqual(wrapped.box, hex(w.box), w.name)
            XCTAssertEqual(try E2EE.unwrap(wrapped, with: recipient, aad: aad), secrets[w.kind], w.name)

            // Authenticators: the vector's signature verifies, ours does too, and
            // both tags are reproduced exactly.
            XCTAssertTrue(E2EE.verifyWrap(wrapped, aad: aad, recipientPk: rpk, signature: hex(w.signature), identity: identity.publicKey), w.name)
            let ours = try E2EE.signWrap(wrapped, aad: aad, recipientPk: rpk, identity: identity)
            XCTAssertTrue(E2EE.verifyWrap(wrapped, aad: aad, recipientPk: rpk, signature: ours, identity: identity.publicKey), w.name)
            XCTAssertFalse(E2EE.verifyWrap(wrapped, aad: hex(v.session.aad), recipientPk: rpk, signature: ours, identity: identity.publicKey), w.name)
            XCTAssertEqual(E2EE.enrolTag(qrSecret: hex(v.inputs.qrSecret), wrapped, aad: aad, recipientPk: rpk), hex(w.enrolTag), w.name)
            XCTAssertEqual(try recipient.sharedSecret(with: recipient.publicKey), hex(w.selfShared), w.name)
            XCTAssertEqual(E2EE.selfTag(selfShared: hex(w.selfShared), user: user, wrapped, aad: aad, recipientPk: rpk), hex(w.selfTag), w.name)

            // A wrap opened under another AAD fails.
            let otherKind = E2EE.wrapAAD(user: user, keyVersion: 1, device: uuid(v.inputs.recipientDevice), kind: .shareKey)
            XCTAssertThrowsError(try E2EE.unwrap(wrapped, with: recipient, aad: otherKind), w.name)
        }
    }

    func testStatements() throws {
        let identity = try Curve25519.Signing.PrivateKey(rawRepresentation: hex(v.inputs.identitySeed))
        XCTAssertFalse(v.statements.isEmpty)
        for s in v.statements {
            let payload = Data(s.payload.utf8)
            XCTAssertEqual(E2EE.statementMessage(type: s.type, payload: payload), hex(s.message), s.type)
            XCTAssertTrue(E2EE.verifyStatement(type: s.type, payload: payload, signature: hex(s.signature), identity: identity.publicKey), s.type)
            XCTAssertFalse(E2EE.verifyStatement(type: s.type + "x", payload: payload, signature: hex(s.signature), identity: identity.publicKey), s.type)
            let ours = try E2EE.signStatement(type: s.type, payload: payload, identity: identity)
            XCTAssertTrue(E2EE.verifyStatement(type: s.type, payload: payload, signature: ours, identity: identity.publicKey), s.type)
        }
    }

    func testInvite() {
        let keys = E2EE.inviteKeys(secret: hex(v.inputs.inviteSecret))
        XCTAssertEqual(keys.auth, hex(v.invite.auth))
        XCTAssertEqual(keys.pin, hex(v.invite.pin))
        XCTAssertEqual(E2EE.inviteMAC(pin: keys.pin, inviterIdentityPk: hex(v.inputs.identityPublic)), hex(v.invite.mac))
    }

    func testRecovery() throws {
        let key = E2EE.recoveryKey(secret: hex(v.inputs.recoverySecret), user: user)
        XCTAssertEqual(key.data, hex(v.recovery.recoveryKey))
        XCTAssertEqual(E2EE.recoveryAAD(user: user, kind: .practiceKey), hex(v.recovery.aad))
        let box = try E2EE.sealRecovery(hex(v.inputs.practiceKey), key: key, user: user, kind: .practiceKey, nonce: hex(v.inputs.nonce))
        XCTAssertEqual(box, hex(v.recovery.practiceKeyBox))
        XCTAssertEqual(try E2EE.openRecovery(box, key: key, user: user, kind: .practiceKey), hex(v.inputs.practiceKey))
        let identity = try Curve25519.Signing.PrivateKey(rawRepresentation: hex(v.inputs.identitySeed))
        XCTAssertTrue(E2EE.verifyRecoveryBox(box, user: user, kind: .practiceKey,
                                             signature: hex(v.recovery.practiceKeyBoxSignature), identity: identity.publicKey))
        XCTAssertFalse(E2EE.verifyRecoveryBox(box, user: user, kind: .identitySeed,
                                              signature: hex(v.recovery.practiceKeyBoxSignature), identity: identity.publicKey))
    }

    func testTagComparisonIsExact() {
        XCTAssertTrue(E2EE.equalTags(Data([1, 2, 3]), Data([1, 2, 3])))
        XCTAssertFalse(E2EE.equalTags(Data([1, 2, 3]), Data([1, 2, 4])))
        XCTAssertFalse(E2EE.equalTags(Data([1, 2]), Data([1, 2, 3])))
    }
}

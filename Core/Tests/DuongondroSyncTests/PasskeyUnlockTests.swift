import CryptoKit
import DuongondroAPI
import DuongondroCrypto
import DuongondroStore
import XCTest
@testable import DuongondroSync

/// One account's keys on a server, in memory: what set-up, restore and passkey
/// unlock call, with the user key's conditional create (201, or 409 when the
/// account has one).
final class KeyServer: URLProtocol {
    struct State {
        var user = UUID()
        var identity: Data?
        var keyVersion = 1
        var devices: [(id: UUID, pk: Data, tier: String)] = []
        var deviceList: (payload: Data, signature: Data)?
        var wraps: [UUID: [[String: Any]]] = [:]
        var recovery: [Int: [String: Any]] = [:]
        var userKey: (id: UUID, version: Int, payload: Data, signature: Data)?
        var userKeyWraps: [[String: Any]] = []
        /// The next GET of the user key answers 404, as if read before another phone's create.
        var hideUserKeyOnce = false
        /// Credential id (base64url) → its box, if any.
        var passkeys: [String: [String: Any]?] = [:]
        var names: [String: String] = [:]
        var userKeyPuts = 0
    }

    private static let lock = NSLock()
    nonisolated(unsafe) static var state = State()

    static func reset() { lock.withLock { state = State() } }
    static func with<T>(_ f: (inout State) throws -> T) rethrows -> T { try lock.withLock { try f(&state) } }

    static func client(token: String = "t") -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [KeyServer.self]
        return APIClient(baseURL: URL(string: "http://test")!, token: token, session: URLSession(configuration: config))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let (status, body) = Self.lock.withLock { Self.answer(request, &Self.state) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body.map { try! JSONSerialization.data(withJSONObject: $0) } ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    static let now = "2026-10-16T12:00:00.000Z"

    static func answer(_ request: URLRequest, _ s: inout State) -> (Int, Any?) {
        let path = request.url!.path
        let method = request.httpMethod ?? "GET"
        let input = (try? JSONSerialization.jsonObject(with: body(of: request))) as? [String: Any] ?? [:]
        let parts = path.split(separator: "/").map(String.init)
        func b64(_ d: Data) -> String { d.base64EncodedString() }
        func data(_ k: String) -> Data { Data(base64Encoded: input[k] as! String)! }
        switch (method, path) {
        case ("GET", "/api/me"):
            var me: [String: Any] = ["id": s.user.uuidString.lowercased(), "keyVersion": s.keyVersion, "displayName": "", "devices": []]
            if let identity = s.identity { me["identityPublicKey"] = b64(identity) }
            return (200, me)
        case ("PUT", "/api/me/identity"):
            s.identity = data("publicKey")
            return (204, nil)
        case ("POST", "/api/devices"):
            let pk = data("publicKey")
            if let d = s.devices.first(where: { $0.pk == pk }) {
                return (200, ["id": d.id.uuidString, "publicKey": b64(d.pk), "tier": d.tier, "createdAt": now])
            }
            let d = (id: UUID(), pk: pk, tier: input["tier"] as! String)
            s.devices.append(d)
            return (200, ["id": d.id.uuidString, "publicKey": b64(d.pk), "tier": d.tier, "createdAt": now])
        case ("GET", "/api/devices"):
            return (200, ["devices": s.devices.map { ["id": $0.id.uuidString, "publicKey": b64($0.pk), "tier": $0.tier, "createdAt": now] }])
        case ("GET", "/api/me/device-list"):
            guard let l = s.deviceList else { return (404, ["error": "none"]) }
            return (200, ["payload": b64(l.payload), "signature": b64(l.signature)])
        case ("PUT", "/api/me/device-list"):
            s.deviceList = (data("payload"), data("signature"))
            return (204, nil)
        case ("GET", "/api/me/recovery-boxes"):
            return (200, ["boxes": s.recovery.values.map { $0 }])
        case ("GET", "/api/sync"):
            return (200, ["cursor": "c", "full": true, "logs": []])
        case ("GET", "/api/me/user-key"):
            if s.hideUserKeyOnce { s.hideUserKeyOnce = false; return (404, ["error": "none"]) }
            guard let u = s.userKey else { return (404, ["error": "none"]) }
            return (200, ["id": u.id.uuidString.lowercased(), "version": u.version,
                          "statement": ["payload": b64(u.payload), "signature": b64(u.signature)],
                          "wraps": s.userKeyWraps.filter { ($0["userKeyId"] as! String).lowercased() == u.id.uuidString.lowercased() }])
        case ("PUT", "/api/me/user-key"):
            s.userKeyPuts += 1
            XCTAssertNil(input["replace"], "the app never replaces U")
            let payload = data("payload")
            if let u = s.userKey {
                return u.payload == payload ? (201, nil) : (409, ["error": "exists", "userKey": ["id": u.id.uuidString.lowercased(), "version": u.version]])
            }
            let parsed = Statements.parseUserKey(payload)!
            s.userKey = (parsed.id, parsed.version, payload, data("signature"))
            return (201, nil)
        case ("POST", "/api/me/user-key/wraps"):
            guard let u = s.userKey, (input["userKeyId"] as! String).lowercased() == u.id.uuidString.lowercased() else {
                return (409, ["error": "not the current user key"])
            }
            s.userKeyWraps.removeAll { $0["kind"] as! Int == input["kind"] as! Int && $0["keyVersion"] as! Int == input["keyVersion"] as! Int }
            var w = input
            w["createdAt"] = now
            s.userKeyWraps.append(w)
            return (204, nil)
        case ("GET", "/api/me/credentials"):
            return (200, ["passkeys": s.passkeys.keys.sorted().map { id -> [String: Any] in
                var p: [String: Any] = ["id": id, "createdAt": now, "current": false, "canUnlock": s.passkeys[id]! != nil]
                if let n = s.names[id] { p["name"] = n }
                return p
            }])
        default:
            break
        }
        if parts.count == 4, parts[1] == "devices", parts[3] == "wraps", let id = UUID(uuidString: parts[2]) {
            if method == "GET" { return (200, ["wraps": s.wraps[id] ?? []]) }
            var w = input
            w["deviceId"] = id.uuidString
            w["createdAt"] = now
            s.wraps[id, default: []].removeAll { $0["kind"] as! Int == w["kind"] as! Int && $0["keyVersion"] as! Int == w["keyVersion"] as! Int }
            s.wraps[id, default: []].append(w)
            return (204, nil)
        }
        if parts.count == 4, parts[2] == "recovery-boxes", let kind = Int(parts[3]) {
            s.recovery[kind] = ["kind": kind, "box": input["box"]!, "updatedAt": now]
            return (204, nil)
        }
        if parts.count >= 4, parts[1] == "me", parts[2] == "credentials" {
            let id = parts[3]
            guard s.passkeys.keys.contains(id) else { return (404, ["error": "not found"]) }
            if parts.count == 4 {
                if method == "PATCH" { s.names[id] = input["name"] as? String; return (204, nil) }
                if method == "DELETE" {
                    if s.passkeys.count == 1 { return (409, ["error": "last way to sign in"]) }
                    s.passkeys[id] = nil
                    return (204, nil)
                }
            }
            if parts.count == 5, parts[4] == "unlock" {
                if method == "PUT" {
                    guard let u = s.userKey, (input["userKeyId"] as! String).lowercased() == u.id.uuidString.lowercased() else {
                        return (409, ["error": "not the current user key"])
                    }
                    s.passkeys[id] = .some(["box": input["box"]!, "signature": input["signature"]!])
                    return (204, nil)
                }
                guard let box = s.passkeys[id] ?? nil, let u = s.userKey else { return (404, ["error": "cannot unlock"]) }
                return (200, ["box": box["box"]!, "signature": box["signature"]!,
                              "userKey": ["id": u.id.uuidString.lowercased(), "version": u.version,
                                          "statement": ["payload": b64(u.payload), "signature": b64(u.signature)],
                                          "wraps": s.userKeyWraps]])
            }
        }
        return (404, ["error": "no route \(method) \(path)"])
    }

    static func body(of request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

final class PasskeyUnlockTests: XCTestCase {
    override func setUp() { KeyServer.reset() }

    func phone() throws -> (Account, MemorySecretStore, AppDatabase) {
        let secrets = MemorySecretStore()
        let db = try AppDatabase.inMemory()
        return (Account(api: KeyServer.client(), secrets: secrets, database: db, preferSoftwareKey: true), secrets, db)
    }

    func prf(_ credential: String) -> PasskeyPRF {
        PasskeyPRF(credentialID: Data(credential.utf8), output: Data(SHA256.hash(data: Data("prf of \(credential)".utf8))))
    }

    func addPasskey(_ p: PasskeyPRF) {
        KeyServer.with { $0.passkeys[p.credentialKey] = .some(nil) }
    }

    func testANewPhoneOpensTheKeysWithAPasskeyAlone() async throws {
        let (first, firstSecrets, _) = try phone()
        _ = try await first.setUpFirstDevice()
        let passkey = prf("passkey-1")
        addPasskey(passkey)
        let v1 = try await first.savePasskeyBox(passkey)
        XCTAssertEqual(v1, .saved)
        XCTAssertEqual(KeyServer.with { $0.userKeyWraps.count }, 2, "the practice key and the seed are wrapped to U")
        let v2 = try await first.api.passkeys().allSatisfy(\.canUnlock)
        XCTAssertTrue(v2)

        let (second, secrets, db) = try phone()
        let v3 = try await second.standing()
        XCTAssertEqual(v3, .restore)
        let v4 = try await second.unlock(with: passkey)
        XCTAssertTrue(v4, "no recovery code asked")
        XCTAssertEqual(try secrets.read(SecretName.identitySeed), try firstSecrets.read(SecretName.identitySeed))
        XCTAssertEqual(try secrets.read(SecretName.practiceKey(1)), try firstSecrets.read(SecretName.practiceKey(1)))
        XCTAssertEqual(try db.syncState()?.userID, KeyServer.with { $0.user })
        XCTAssertEqual(try second.heldUserKey(), try first.heldUserKey(), "the new phone holds U too")
        XCTAssertEqual(KeyServer.with { $0.devices.count }, 2, "the new phone registered and listed itself")
        let v5 = try await second.standing()
        XCTAssertEqual(v5, .ready)
    }

    func testWithoutABoxOrWithAnotherOutputTheRecoveryCodeIsAsked() async throws {
        let (first, _, _) = try phone()
        _ = try await first.setUpFirstDevice()
        let boxed = prf("boxed"), bare = prf("bare")
        addPasskey(boxed)
        addPasskey(bare)
        let v6 = try await first.savePasskeyBox(boxed)
        XCTAssertEqual(v6, .saved)

        let (second, secrets, _) = try phone()
        let unlockedBare = try await second.unlock(with: bare)
        XCTAssertFalse(unlockedBare, "a passkey without a box")
        let wrongOutput = PasskeyPRF(credentialID: boxed.credentialID, output: Data(repeating: 7, count: 32))
        let unlockedWrong = try await second.unlock(with: wrongOutput)
        XCTAssertFalse(unlockedWrong, "a PRF output that does not open the box")
        XCTAssertNil(try secrets.read(SecretName.identitySeed))
    }

    func testABoxForAnotherAccountsPasskeyIsRefused() async throws {
        let (first, _, _) = try phone()
        _ = try await first.setUpFirstDevice()
        let v7 = try await first.savePasskeyBox(prf("someone else's"))
        XCTAssertEqual(v7, .otherAccountsPasskey)
    }

    func testABoxTheServerMovedToAnotherPasskeyDoesNotOpen() async throws {
        let (first, _, _) = try phone()
        _ = try await first.setUpFirstDevice()
        let a = prf("a"), b = prf("b")
        addPasskey(a)
        addPasskey(b)
        let saved = try await first.savePasskeyBox(a)
        XCTAssertEqual(saved, .saved)
        // The server serves a's box as b's: its AAD names a's credential id.
        KeyServer.with { $0.passkeys[b.credentialKey] = $0.passkeys[a.credentialKey]! }
        let (second, secrets, _) = try phone()
        let opened = try await second.unlock(with: PasskeyPRF(credentialID: b.credentialID, output: a.output))
        XCTAssertFalse(opened, "a box under another credential id does not open")
        XCTAssertNil(try secrets.read(SecretName.identitySeed))
    }

    /// A server that publishes an identity key of its own, re-signs U's statement
    /// and serves wraps of keys it chose: the box, sealed under the real identity
    /// key, does not open, and nothing from that response is trusted.
    func testAServersOwnIdentityKeyIsShutOutByTheBox() async throws {
        let (first, _, _) = try phone()
        _ = try await first.setUpFirstDevice()
        let passkey = prf("p")
        addPasskey(passkey)
        let saved = try await first.savePasskeyBox(passkey)
        XCTAssertEqual(saved, .saved)
        let forger = Curve25519.Signing.PrivateKey()
        try KeyServer.with { s in
            s.identity = forger.publicKey.rawRepresentation
            let u = s.userKey!
            s.userKey = (u.id, u.version, u.payload, try E2EE.signStatement(type: "user-key", payload: u.payload, identity: forger))
            let key = Statements.parseUserKey(u.payload)!
            s.userKeyWraps = try [(E2EE.WrapKind.practiceKey, SymmetricKey(size: .bits256).data), (.identitySeed, forger.rawRepresentation)].map { kind, secret in
                let w = try Account.wrapToUserKey(secret, kind: kind, key: key, user: s.user, keyVersion: 1, identity: forger)
                return ["userKeyId": w.userKeyId.uuidString, "kind": w.kind, "keyVersion": w.keyVersion, "ephemeralKey": w.ephemeralKey.base64EncodedString(),
                        "box": w.box.base64EncodedString(), "signature": w.signature.base64EncodedString(), "createdAt": KeyServer.now]
            }
        }
        let (second, secrets, db) = try phone()
        let opened = try await second.unlock(with: passkey)
        XCTAssertFalse(opened)
        XCTAssertNil(try secrets.read(SecretName.identitySeed))
        XCTAssertNil(try secrets.read(SecretName.userKey))
        XCTAssertNil(try db.syncState())
    }

    func testAnExistingUserKeyIsNeverReplacedAndArrivesAsKindFour() async throws {
        let (first, _, _) = try phone()
        let code = try await first.setUpFirstDevice()
        // A second phone with the keys, by the recovery code, before U exists.
        let (second, secrets, _) = try phone()
        try await second.restore(recoveryCode: code)

        let v9 = try await first.keepUserKey()
        XCTAssertTrue(v9, "the first phone creates U")
        let published = KeyServer.with { $0.userKey!.id }
        // The second phone made its own U before seeing the first's: the
        // conditional create answers 409 and it keeps nothing of its own.
        try secrets.write(SecretName.userKey, try JSONEncoder().encode(
            Account.HeldUserKey(id: UUID(), version: 1, scalar: P256.KeyAgreement.PrivateKey().rawRepresentation)))
        let v10 = try await second.keepUserKey()
        XCTAssertTrue(v10, "U reached it as a kind 4 wrap from the first phone")
        XCTAssertEqual(KeyServer.with { $0.userKey!.id }, published, "never replaced")
        XCTAssertEqual(try second.heldUserKey(), try first.heldUserKey())

    }

    func testACreateThatLosesTheRaceKeepsNothingAndWaits() async throws {
        let (first, _, _) = try phone()
        let code = try await first.setUpFirstDevice()
        let v11 = try await first.keepUserKey()
        XCTAssertTrue(v11)
        let published = KeyServer.with { $0.userKey!.id }
        // A phone that came in by the recovery code after U was shared: no kind 4
        // wrap for it yet. It reads no U (before the first phone's create landed),
        // creates its own, and gets 409.
        let (second, secrets, _) = try phone()
        try await second.restore(recoveryCode: code)
        KeyServer.with { $0.hideUserKeyOnce = true }
        let puts = KeyServer.with { $0.userKeyPuts }
        let holds = try await second.keepUserKey()
        XCTAssertFalse(holds, "waits for the existing U")
        XCTAssertEqual(KeyServer.with { $0.userKeyPuts }, puts + 1)
        XCTAssertEqual(KeyServer.with { $0.userKey!.id }, published, "never replaced")
        XCTAssertNil(try secrets.read(SecretName.userKey), "keeps no U of its own")
        let v12 = try await second.savePasskeyBox(prf("p"))
        XCTAssertEqual(v12, .waitingForUserKey)
        // The first phone's next sync gives it U.
        let v13 = try await first.keepUserKey()
        XCTAssertTrue(v13)
        let v14 = try await second.keepUserKey()
        XCTAssertTrue(v14)
        XCTAssertEqual(try second.heldUserKey()?.id, published)
    }

    /// A kind 4 wrap at another version than U's statement, or one whose scalar
    /// is not the signed key's (even signed by the identity), is ignored.
    func testAKindFourAtAnotherVersionOrWithAnotherScalarIsIgnored() async throws {
        let (first, _, _) = try phone()
        let code = try await first.setUpFirstDevice()
        let (second, secrets, _) = try phone()
        try await second.restore(recoveryCode: code)
        let created = try await first.keepUserKey()
        XCTAssertTrue(created)
        let me = try XCTUnwrap(second.deviceID)
        let user = KeyServer.with { $0.user }
        let devicePk = try XCTUnwrap(try DeviceKeys(store: secrets, preferSoftware: true).current()).publicKey
        let identity = try first.identity()
        let key = Statements.parseUserKey(KeyServer.with { $0.userKey!.payload })!

        // Signed, right version, but another scalar.
        let aad = E2EE.wrapAAD(user: user, keyVersion: UInt32(key.version), device: me, kind: .userKey)
        let wrapped = try E2EE.wrap(P256.KeyAgreement.PrivateKey().rawRepresentation,
                                    to: try P256.KeyAgreement.PublicKey(x963Representation: devicePk), aad: aad)
        let signature = try E2EE.signWrap(wrapped, aad: aad, recipientPk: devicePk, identity: identity)
        KeyServer.with {
            $0.wraps[me] = [["kind": 4, "keyVersion": key.version, "ephemeralKey": wrapped.epk.base64EncodedString(),
                             "box": wrapped.box.base64EncodedString(), "authType": "signature",
                             "authenticator": signature.base64EncodedString(), "deviceId": me.uuidString, "createdAt": KeyServer.now]]
        }
        var holds = try await second.keepUserKey()
        XCTAssertFalse(holds, "scalar·G is not the signed pk")
        XCTAssertNil(try secrets.read(SecretName.userKey))

        // The real one, relabelled at another version.
        try secrets.delete(SecretName.userKeyShared)
        try first.secrets.delete(SecretName.userKeyShared)
        _ = try await first.keepUserKey()
        KeyServer.with { s in s.wraps[me] = s.wraps[me]!.map { var w = $0; w["keyVersion"] = key.version + 1; return w } }
        holds = try await second.keepUserKey()
        XCTAssertFalse(holds, "not U's current version")
        XCTAssertNil(try secrets.read(SecretName.userKey))
    }

    func testAUserKeyTheIdentityDidNotSignIsRefused() async throws {
        let (first, _, _) = try phone()
        _ = try await first.setUpFirstDevice()
        KeyServer.with {
            let payload = Statements.userKey(.init(id: UUID(), publicKey: P256.KeyAgreement.PrivateKey().publicKey.x963Representation,
                                                   user: $0.user, version: 1))
            $0.userKey = (Statements.parseUserKey(payload)!.id, 1, payload, Data(count: 64))
        }
        do {
            _ = try await first.keepUserKey()
            XCTFail("a statement the identity did not sign")
        } catch Account.Failure.notAuthentic {}
        XCTAssertNil(try first.heldUserKey())
        XCTAssertTrue(KeyServer.with { $0.userKeyWraps.isEmpty }, "nothing wrapped to it")
    }

    func testARotationWrapsTheNewKeyToTheUserKey() async throws {
        let (first, _, _) = try phone()
        _ = try await first.setUpFirstDevice()
        let none = try await first.rotationWrapToUserKey(newKey: SymmetricKey(size: .bits256).data, newVersion: 2)
        XCTAssertNil(none, "no U, nothing to wrap")
        let v15 = try await first.keepUserKey()
        XCTAssertTrue(v15)
        let newKey = SymmetricKey(size: .bits256).data
        let v16 = try await first.rotationWrapToUserKey(newKey: newKey, newVersion: 2)
        let wrap = try XCTUnwrap(v16)
        let held = try XCTUnwrap(try first.heldUserKey())
        XCTAssertEqual(wrap.userKeyId, held.id)
        XCTAssertEqual(wrap.keyVersion, 2)
        let user = try XCTUnwrap(try first.database.syncState()).userID
        let aad = E2EE.wrapAAD(user: user, keyVersion: 2, device: held.id, kind: .practiceKey)
        XCTAssertEqual(try E2EE.unwrap(.init(epk: wrap.ephemeralKey, box: wrap.box), with: try held.privateKey, aad: aad), newKey)
        let rotation = KeyRotation(newVersion: 2, wraps: [], userKeyWrap: wrap)
        let json = try JSONSerialization.jsonObject(with: APIClient.encoder.encode(rotation)) as! [String: Any]
        XCTAssertNotNil(json["userKeyWrap"])
    }

    func testTheUserKeyStatementIsCanonical() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "vectors", withExtension: "json", subdirectory: "Resources"))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let statement = (json["prf"] as! [String: Any])["statement"] as! [String: Any]
        let payload = Data((statement["payload"] as! String).utf8)
        let parsed = try XCTUnwrap(Statements.parseUserKey(payload))
        XCTAssertEqual(parsed.version, 1)
        XCTAssertEqual(parsed.publicKey.count, 65)
        XCTAssertEqual(String(decoding: Statements.userKey(parsed), as: UTF8.self), String(decoding: payload, as: UTF8.self))
    }
}

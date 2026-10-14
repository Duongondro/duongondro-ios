import CryptoKit
import DuongondroAPI
import DuongondroStore
import XCTest
@testable import DuongondroSync

/// Answers GET api/me with the account the test sets.
final class MeProtocol: URLProtocol {
    nonisolated(unsafe) static var me = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let ok = request.url!.path.hasSuffix("/api/me")
        let response = HTTPURLResponse(url: request.url!, statusCode: ok ? 200 : 404, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: ok ? Self.me : Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// After a reinstall the database is new and the Keychain is not.
final class FreshInstallTests: XCTestCase {
    /// What an install left after a set-up interrupted once the identity was
    /// published but before the recovery boxes were stored.
    func interruptedSetUp(of user: UUID) throws -> (MemorySecretStore, Curve25519.Signing.PrivateKey) {
        let secrets = MemorySecretStore()
        let identity = Curve25519.Signing.PrivateKey()
        try secrets.write(SecretName.sessionToken, Data("old-token".utf8))
        try secrets.write(SecretName.setUpUser, Data(user.uuidString.lowercased().utf8))
        try secrets.write(SecretName.identitySeed, identity.rawRepresentation)
        try secrets.write(SecretName.practiceKey(1), SymmetricKey(size: .bits256).data)
        return (secrets, identity)
    }

    func testAFreshDatabaseDropsOnlyTheSessionToken() throws {
        let user = UUID()
        let (secrets, identity) = try interruptedSetUp(of: user)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try AppDatabase.open(path: dir.appendingPathComponent("t.sqlite").path)
        XCTAssertTrue(db.createdFile)
        try Account.forgetEarlierInstall(secrets)
        XCTAssertNil(try secrets.read(SecretName.sessionToken), "no account opens before anyone signs in")
        XCTAssertEqual(try secrets.read(SecretName.identitySeed), identity.rawRepresentation, "the only copy of the keys stays")
        XCTAssertNotNil(try secrets.read(SecretName.practiceKey(1)))
        XCTAssertEqual(Account(api: APIClient(baseURL: URL(string: "http://test")!), secrets: secrets, database: db).setUpUser, user)
    }

    func testTheSameAccountSigningInResumesItsSetUp() async throws {
        let user = UUID()
        let (secrets, identity) = try interruptedSetUp(of: user)
        try Account.forgetEarlierInstall(secrets)
        XCTAssertEqual(Account.plan(signingIn: user, syncUser: nil, setUpUser: user, lastUser: nil, holdsPractice: true), .keep)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MeProtocol.self]
        MeProtocol.me = Data("""
            {"id":"\(user.uuidString.lowercased())","identityPublicKey":"\(identity.publicKey.rawRepresentation.base64EncodedString())",
             "keyVersion":1,"displayName":"","devices":[]}
            """.utf8)
        let api = APIClient(baseURL: URL(string: "http://test")!, token: "new-token", session: URLSession(configuration: config))
        let account = Account(api: api, secrets: secrets, database: try AppDatabase.inMemory())
        let standing = try await account.standing()
        XCTAssertEqual(standing, .setUp, "set-up resumes with the kept identity, and its recovery code")
    }

    func testAnotherAccountSigningInClearsTheKeysWithoutAsking() {
        let earlier = UUID(), other = UUID()
        XCTAssertEqual(Account.plan(signingIn: other, syncUser: nil, setUpUser: earlier, lastUser: nil, holdsPractice: true),
                       .forgetOtherAccount, "an earlier install's keys own no practice here")
        XCTAssertEqual(Account.plan(signingIn: other, syncUser: nil, setUpUser: earlier, lastUser: nil, holdsPractice: false),
                       .forgetOtherAccount)
        // Practice that may be another account's is still asked about.
        XCTAssertEqual(Account.plan(signingIn: other, syncUser: earlier, setUpUser: earlier, lastUser: nil, holdsPractice: true),
                       .askAboutPractice)
        XCTAssertEqual(Account.plan(signingIn: other, syncUser: nil, setUpUser: nil, lastUser: earlier, holdsPractice: true),
                       .askAboutPractice)
        XCTAssertEqual(Account.plan(signingIn: other, syncUser: nil, setUpUser: earlier, lastUser: earlier, holdsPractice: true),
                       .askAboutPractice)
        XCTAssertEqual(Account.plan(signingIn: other, syncUser: earlier, setUpUser: nil, lastUser: nil, holdsPractice: false),
                       .forgetOtherAccount)
        XCTAssertEqual(Account.plan(signingIn: other, syncUser: nil, setUpUser: nil, lastUser: nil, holdsPractice: true), .keep,
                       "local mode signing up")
    }
}

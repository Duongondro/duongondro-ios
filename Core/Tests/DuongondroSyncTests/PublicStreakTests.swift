import CryptoKit
import XCTest
import DuongondroAPI
import DuongondroCore
import DuongondroStore
@testable import DuongondroSync

/// The server's public streaks for one account, in memory: GET, PUT and DELETE
/// of /api/streaks, nothing else.
final class StreakServer: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stored: [String: (payload: Data, signature: Data)] = [:]
    /// Runs once, on the next GET /api/streaks, after its answer is made and before it arrives.
    nonisolated(unsafe) private static var onList: (() -> Void)?

    static func reset() { lock.withLock { stored = [:]; onList = nil } }
    static var practices: Set<String> { lock.withLock { Set(stored.keys) } }
    static func drop(_ practice: String) { lock.withLock { stored[practice] = nil } }
    static func whenListed(_ hook: @escaping () -> Void) { lock.withLock { onList = hook } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url!.path
        let method = request.httpMethod ?? "GET"
        var status = 404
        var body = Data(#"{"error":"not found"}"#.utf8)
        if method == "GET", path == "/api/streaks" {
            let list = Self.lock.withLock { Self.stored.map { p, s in
                ["userId": UUID().uuidString, "practice": p,
                 "payload": s.payload.base64EncodedString(), "signature": s.signature.base64EncodedString()]
            } }
            body = try! JSONSerialization.data(withJSONObject: ["streaks": list])
            status = 200
            let hook = Self.lock.withLock { () -> (() -> Void)? in defer { Self.onList = nil }; return Self.onList }
            hook?()
        } else if path.hasPrefix("/api/streaks/") {
            let practice = String(path.dropFirst("/api/streaks/".count))
            if method == "PUT" {
                let o = try! JSONSerialization.jsonObject(with: Self.body(of: request)) as! [String: String]
                Self.lock.withLock { Self.stored[practice] = (Data(base64Encoded: o["payload"]!)!, Data(base64Encoded: o["signature"]!)!) }
                status = 204
            } else if method == "DELETE" {
                status = Self.lock.withLock { Self.stored.removeValue(forKey: practice) } == nil ? 404 : 204
            }
            if status == 204 { body = Data() }
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func body(of request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            out.append(buffer, count: n)
        }
        return out
    }
}

final class PublicStreakTests: XCTestCase {
    var db: AppDatabase!
    var social: Social!

    override func setUp() async throws {
        StreakServer.reset()
        db = try AppDatabase.inMemory()
        for (i, id) in ["chenrezig", "mandala"].enumerated() {
            try db.save(TrackedPractice(practice: Catalogue.builtIn.first { $0.id == id }!, sortOrder: i))
        }
        let t = Date().addingTimeInterval(-60)
        try db.insert(Session(practiceID: "chenrezig", amount: 10, startedAt: t, startExact: true,
                              timeZoneID: TimeZone.current.identifier, loggedAt: t))
        let secrets = MemorySecretStore()
        try secrets.write(SecretName.identitySeed, Curve25519.Signing.PrivateKey().rawRepresentation)
        try db.saveSyncState(SyncState(userID: UUID(), keyVersion: 1))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StreakServer.self]
        let api = APIClient(baseURL: URL(string: "https://api.example")!, token: "t", session: URLSession(configuration: config))
        social = Social(account: Account(api: api, secrets: secrets, database: db))
    }

    /// Review found it (Android 7e6580c2): private while a publish has the
    /// server's list in hand must stay private, not be merged back and sent again.
    func testPrivateDuringAPublishStaysPrivate() async throws {
        try await social.setPublic("chenrezig", true)
        XCTAssertEqual(StreakServer.practices, ["chenrezig"])
        let social = self.social!
        // The switch to private is asked for while the publish waits for the list.
        let toggled = ToggleBox()
        StreakServer.whenListed {
            toggled.task = Task { try await social.setPublic("chenrezig", false) }
            Thread.sleep(forTimeInterval: 0.3)
        }
        try await social.publishStreaks()
        try await toggled.task!.value
        XCTAssertFalse(try db.isPublic("chenrezig"))
        XCTAssertTrue(StreakServer.practices.isEmpty)
    }
}

final class ToggleBox: @unchecked Sendable {
    var task: Task<Void, Error>?
}

import Foundation

/// The phone's side of duongondro-api's api/openapi.yaml: the operations phase 3
/// uses, typed. Byte strings travel as standard base64 (JSONEncoder's default for
/// Data, Go's for []byte); times as RFC 3339.
public struct APIClient: Sendable {
    public var baseURL: URL
    public var token: String?
    let session: URLSession

    public init(baseURL: URL, token: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    // MARK: Account and keys

    public func me() async throws -> Me { try await get("api/me") }

    /// Deletes everything the server holds about this account (GDPR Article 17).
    public func deleteMe() async throws {
        let _: Empty = try await request("DELETE", "api/me", query: [], body: Optional<Empty>.none)
    }

    public func setIdentity(publicKey: Data) async throws {
        try await send("PUT", "api/me/identity", body: IdentityKey(publicKey: publicKey))
    }

    public func deviceList() async throws -> SignedStatement? {
        do { return try await get("api/me/device-list") } catch APIError.notFound { return nil }
    }

    public func putDeviceList(_ statement: SignedStatement) async throws {
        try await send("PUT", "api/me/device-list", body: statement)
    }

    /// Registers this device's key; the same key again returns the existing device.
    public func registerDevice(publicKey: Data, tier: Tier) async throws -> Device {
        try await send("POST", "api/devices", body: DeviceInput(publicKey: publicKey, tier: tier))
    }

    public func devices() async throws -> [Device] {
        let list: DeviceList = try await get("api/devices")
        return list.devices
    }

    public func wraps(device: UUID) async throws -> [Wrap] {
        let list: WrapList = try await get("api/devices/\(device.lowercased)/wraps")
        return list.wraps
    }

    public func putWrap(_ wrap: WrapInput, device: UUID) async throws {
        try await send("POST", "api/devices/\(device.lowercased)/wraps", body: wrap)
    }

    public func rotate(_ rotation: KeyRotation) async throws {
        try await send("POST", "api/me/key-rotations", body: rotation)
    }

    public func recoveryBoxes() async throws -> [RecoveryBox] {
        let list: RecoveryBoxList = try await get("api/me/recovery-boxes")
        return list.boxes
    }

    public func putRecoveryBox(kind: Int, _ box: RecoveryBoxInput) async throws {
        try await send("PUT", "api/me/recovery-boxes/\(kind)", body: box)
    }

    // MARK: Sync

    public func putLog(id: UUID, _ log: PracticeLogInput) async throws -> PracticeLog {
        try await send("PUT", "api/practice-logs/\(id.lowercased)", body: log)
    }

    public func sync(since cursor: String?) async throws -> SyncResponse {
        var query: [URLQueryItem] = []
        if let cursor { query.append(URLQueryItem(name: "since", value: cursor)) }
        return try await get("api/sync", query: query)
    }

    /// Development builds of the server only (`make serve`): a session for a new
    /// user, or for `user`. Release servers have no such route.
    public func devSession(user: UUID? = nil) async throws -> DevSession {
        var query: [URLQueryItem] = []
        if let user { query.append(URLQueryItem(name: "user", value: user.lowercased)) }
        return try await request("POST", "api/dev/session", query: query, body: Optional<Empty>.none)
    }

    // MARK: Plumbing

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await request("GET", path, query: query, body: Optional<Empty>.none)
    }

    func send<B: Encodable, T: Decodable>(_ method: String, _ path: String, body: B) async throws -> T {
        try await request(method, path, query: [], body: body)
    }

    func send<B: Encodable>(_ method: String, _ path: String, body: B) async throws {
        let _: Empty = try await request(method, path, query: [], body: body)
    }

    func request<B: Encodable, T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem], body: B?) async throws -> T {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var req = URLRequest(url: components.url!)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try Self.encoder.encode(body)
        }
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300:
            if T.self == Empty.self || data.isEmpty { return try Self.decoder.decode(T.self, from: Data("{}".utf8)) }
            return try Self.decoder.decode(T.self, from: data)
        case 401: throw APIError.unauthorized
        case 404: throw APIError.notFound
        case 422:
            if let old = try? Self.decoder.decode(OldKeyError.self, from: data) {
                throw APIError.oldKey(currentKeyVersion: old.currentKeyVersion)
            }
            throw APIError.status(status, Self.message(data))
        case 409: throw APIError.conflict(Self.message(data))
        default: throw APIError.status(status, Self.message(data))
        }
    }

    static func message(_ data: Data) -> String {
        (try? decoder.decode(ErrorBody.self, from: data))?.error ?? String(decoding: data.prefix(200), as: UTF8.self)
    }

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(RFC3339.string(date))
        }
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = RFC3339.date(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "not an RFC 3339 time: \(s)")
            }
            return date
        }
        return d
    }()
}

public enum APIError: Error, Equatable {
    case unauthorized
    case notFound
    case conflict(String)
    /// Another phone rotated the practice key; wraps of the new one are waiting.
    case oldKey(currentKeyVersion: Int)
    case status(Int, String)
}

/// RFC 3339 with milliseconds out; in, any fractional precision (Go writes nanoseconds).
enum RFC3339 {
    static func string(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    static func date(_ s: String) -> Date? {
        // ISO8601DateFormatter takes at most millisecond fractions: trim the rest.
        var s = s
        if let dot = s.firstIndex(of: "."), let end = s[dot...].firstIndex(where: { !$0.isNumber && $0 != "." }) {
            let digits = s[s.index(after: dot)..<end]
            if digits.count > 3 { s.removeSubrange(s.index(dot, offsetBy: 4)..<end) }
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = s.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return f.date(from: s)
    }
}

extension UUID {
    var lowercased: String { uuidString.lowercased() }
}

// MARK: - Models

struct Empty: Codable {}
struct ErrorBody: Decodable { let error: String }

public enum Tier: String, Codable, Sendable { case hardware, tee, software }

public struct Me: Codable, Equatable, Sendable {
    public let id: UUID
    public let identityPublicKey: Data?
    public let keyVersion: Int
    public let displayName: String
    public let devices: [Device]
}

public struct IdentityKey: Codable, Sendable { public let publicKey: Data }

public struct SignedStatement: Codable, Equatable, Sendable {
    public let payload: Data
    public let signature: Data
    public init(payload: Data, signature: Data) {
        self.payload = payload
        self.signature = signature
    }
}

struct DeviceInput: Codable { let publicKey: Data; let tier: Tier }
struct DeviceList: Codable { let devices: [Device] }

public struct Device: Codable, Equatable, Sendable {
    public let id: UUID
    public let publicKey: Data
    public let tier: Tier
    public let createdAt: Date
}

public enum AuthType: String, Codable, Sendable { case signature, enrol, `self` }

public struct WrapInput: Codable, Equatable, Sendable {
    public let kind: Int
    public let keyVersion: Int
    public let ephemeralKey: Data
    public let box: Data
    public let authType: AuthType
    public let authenticator: Data
    public init(kind: Int, keyVersion: Int, ephemeralKey: Data, box: Data, authType: AuthType, authenticator: Data) {
        self.kind = kind
        self.keyVersion = keyVersion
        self.ephemeralKey = ephemeralKey
        self.box = box
        self.authType = authType
        self.authenticator = authenticator
    }
}

public struct Wrap: Codable, Equatable, Sendable {
    public let kind: Int
    public let keyVersion: Int
    public let ephemeralKey: Data
    public let box: Data
    public let authType: AuthType
    public let authenticator: Data
    public let deviceId: UUID
    public let createdAt: Date
}

struct WrapList: Codable { let wraps: [Wrap] }

public struct RotationWrap: Codable, Sendable {
    public let deviceId: UUID
    public let kind: Int
    public let keyVersion: Int
    public let ephemeralKey: Data
    public let box: Data
    public let authType: AuthType
    public let authenticator: Data
    public init(deviceId: UUID, _ w: WrapInput) {
        self.deviceId = deviceId
        kind = w.kind
        keyVersion = w.keyVersion
        ephemeralKey = w.ephemeralKey
        box = w.box
        authType = w.authType
        authenticator = w.authenticator
    }
}

public struct KeyRotation: Codable, Sendable {
    public let newVersion: Int
    public let wraps: [RotationWrap]
    public init(newVersion: Int, wraps: [RotationWrap]) {
        self.newVersion = newVersion
        self.wraps = wraps
    }
}

public struct RecoveryBoxInput: Codable, Sendable {
    public let box: Data
    public let signature: Data
    public init(box: Data, signature: Data) {
        self.box = box
        self.signature = signature
    }
}

public struct RecoveryBox: Codable, Equatable, Sendable {
    public let kind: Int
    public let box: Data
    public let updatedAt: Date
}

struct RecoveryBoxList: Codable { let boxes: [RecoveryBox] }

public struct PracticeLogInput: Codable, Sendable {
    public let sealed: Data
    public let keyVersion: Int
    public let updatedAt: Date
    public let deleted: Bool?
    public init(sealed: Data, keyVersion: Int, updatedAt: Date, deleted: Bool) {
        self.sealed = sealed
        self.keyVersion = keyVersion
        self.updatedAt = updatedAt
        self.deleted = deleted ? true : nil
    }
}

public struct PracticeLog: Codable, Equatable, Sendable {
    public let id: UUID
    public let sealed: Data?
    public let keyVersion: Int
    public let updatedAt: Date
    public let deletedAt: Date?

    public init(id: UUID, sealed: Data?, keyVersion: Int, updatedAt: Date, deletedAt: Date? = nil) {
        self.id = id
        self.sealed = sealed
        self.keyVersion = keyVersion
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

public struct SyncResponse: Codable, Sendable {
    public let cursor: String
    public let full: Bool
    public let logs: [PracticeLog]
}

struct OldKeyError: Codable { let error: String; let currentKeyVersion: Int }

public struct DevSession: Codable, Sendable {
    public let token: String
    public let userId: UUID
}

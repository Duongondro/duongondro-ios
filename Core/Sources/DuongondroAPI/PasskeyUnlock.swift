import Foundation

/// Settings › Passkeys (design decision 25) and passkey unlock (PRF, decision 23):
/// the account's passkeys, the user key U, wraps to it, and each passkey's box of
/// U's scalar (docs/crypto.md › Passkey unlock). Credential ids travel as base64url
/// without padding, as the server lists them.
extension APIClient {
    // MARK: Passkeys in Settings

    /// The account's passkeys, oldest first.
    public func passkeys() async throws -> [Passkey] {
        let list: PasskeyList = try await get("api/me/credentials")
        return list.passkeys
    }

    /// Names a passkey; nil or blank clears the name (the app then shows its
    /// password manager's name).
    public func renamePasskey(_ id: String, name: String?) async throws {
        try await send("PATCH", "api/me/credentials/\(id)", body: PasskeyRename(name: name))
    }

    /// Removes a passkey, its box, and every session it signed in with. 409
    /// (`APIError.conflict`): it is the account's last way to sign in.
    public func removePasskey(_ id: String) async throws {
        let _: Empty = try await request("DELETE", "api/me/credentials/\(id)", query: [], body: Optional<Empty>.none)
    }

    // MARK: The user key

    /// U's signed statement and the wraps to it; nil when the account has none.
    public func userKey() async throws -> UserKeyState? {
        do { return try await get("api/me/user-key") } catch APIError.notFound { return nil }
    }

    /// Publishes U, only when the account has none: a conditional create (201; the
    /// same statement again is 201 too). 409 with the stored U's id: the account
    /// has one already and nothing changed. Any other 409 (a precondition, such as
    /// no identity key yet) throws `APIError.conflict`.
    ///
    /// `replace` replaces an existing U, only when the person asks (it was lost,
    /// or a passkey that could unlock it was removed): the server takes it from a
    /// device holding the current practice key, for a new id and a higher version,
    /// and deletes every box and wrap of the old U.
    public func createUserKey(_ statement: SignedStatement, replace: Bool = false) async throws -> UserKeyCreation {
        let body = UserKeyInput(payload: statement.payload, signature: statement.signature, replace: replace ? true : nil)
        let (status, data) = try await exchange("PUT", "api/me/user-key", query: [], body: body)
        if status == 409, let existing = (try? Self.decoder.decode(UserKeyConflict.self, from: data))?.userKey {
            return .exists(id: existing.id, version: existing.version)
        }
        _ = try Self.check(status, data)
        return .created
    }

    /// The practice key or the identity seed wrapped to the current U.
    public func putUserKeyWrap(_ wrap: UserKeyWrapInput) async throws {
        try await send("POST", "api/me/user-key/wraps", body: wrap)
    }

    // MARK: A passkey's box

    /// What a new phone needs after signing in with this passkey; nil when it
    /// cannot unlock the counts (no box), or is not this account's.
    public func passkeyUnlock(credential id: String) async throws -> PasskeyUnlock? {
        do { return try await get("api/me/credentials/\(id)/unlock") } catch APIError.notFound { return nil }
    }

    /// Stores U's scalar sealed under this passkey's PRF output. 409: U changed.
    public func putPasskeyBox(credential id: String, _ box: PasskeyBoxInput) async throws {
        try await send("PUT", "api/me/credentials/\(id)/unlock", body: box)
    }
}

public struct Passkey: Codable, Equatable, Sendable, Identifiable {
    /// The credential id, base64url without padding.
    public let id: String
    public let name: String?
    public let aaguid: String?
    public let createdAt: Date
    public let lastUsedAt: Date?
    /// This session signed in with it: removing it signs this phone out.
    public let current: Bool
    /// It holds a box of U: signing in with it brings the keys to a new phone.
    public let canUnlock: Bool

    public init(id: String, name: String? = nil, aaguid: String? = nil, createdAt: Date, lastUsedAt: Date? = nil,
                current: Bool = false, canUnlock: Bool = false) {
        self.id = id
        self.name = name
        self.aaguid = aaguid
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.current = current
        self.canUnlock = canUnlock
    }
}

struct PasskeyList: Codable { let passkeys: [Passkey] }

struct PasskeyRename: Encodable {
    let name: String?
    func encode(to encoder: Encoder) throws {
        // An explicit null clears the name; the field is required.
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
    }
    enum CodingKeys: String, CodingKey { case name }
}

struct UserKeyInput: Encodable {
    let payload: Data
    let signature: Data
    /// Only ever true, when the person asked for a replacement; absent otherwise.
    let replace: Bool?
}

struct UserKeyConflict: Decodable {
    struct Existing: Decodable { let id: UUID; let version: Int }
    let userKey: Existing?
}

public enum UserKeyCreation: Equatable, Sendable {
    case created
    /// The account has this U already (another phone won); nothing changed.
    case exists(id: UUID, version: Int)
}

public struct UserKeyWrapInput: Codable, Equatable, Sendable {
    public let userKeyId: UUID
    public let kind: Int
    public let keyVersion: Int
    public let ephemeralKey: Data
    public let box: Data
    public let signature: Data
    public init(userKeyId: UUID, kind: Int, keyVersion: Int, ephemeralKey: Data, box: Data, signature: Data) {
        self.userKeyId = userKeyId
        self.kind = kind
        self.keyVersion = keyVersion
        self.ephemeralKey = ephemeralKey
        self.box = box
        self.signature = signature
    }
}

public struct UserKeyWrap: Codable, Equatable, Sendable {
    public let userKeyId: UUID
    public let kind: Int
    public let keyVersion: Int
    public let ephemeralKey: Data
    public let box: Data
    public let signature: Data
}

public struct UserKeyState: Codable, Equatable, Sendable {
    public let id: UUID
    public let version: Int
    public let statement: SignedStatement
    public let wraps: [UserKeyWrap]
    public init(id: UUID, version: Int, statement: SignedStatement, wraps: [UserKeyWrap]) {
        self.id = id
        self.version = version
        self.statement = statement
        self.wraps = wraps
    }
}

public struct PasskeyBoxInput: Codable, Equatable, Sendable {
    public let userKeyId: UUID
    public let box: Data
    public let signature: Data
    public init(userKeyId: UUID, box: Data, signature: Data) {
        self.userKeyId = userKeyId
        self.box = box
        self.signature = signature
    }
}

public struct PasskeyUnlock: Codable, Equatable, Sendable {
    public let userKey: UserKeyState
    public let box: Data
    public let signature: Data
}

extension Passkey {
    /// The name Settings shows: the person's, or the password manager's that holds
    /// it, from the authenticator's AAGUID; nil for the app's own "Passkey".
    public var displayName: String? {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        return aaguid.flatMap { PasswordManagers.name(aaguid: $0) }
    }
}

/// Password managers by the AAGUID their passkeys carry (the community list
/// passkeydeveloper/passkey-authenticator-aaguids), for a passkey nobody named.
public enum PasswordManagers {
    static let names: [String: String] = [
        "fbfc3007-154e-4ecc-8c0b-6e020557d7bd": "iCloud Keychain",
        "dd4ec289-e01d-41c9-bb89-70fa845d4bf2": "iCloud Keychain",
        "ea9b8d66-4d01-1d21-3ce4-b6b48cb575d4": "Google Password Manager",
        "adce0002-35bc-c60a-648b-0b25f1f05503": "Chrome on Mac",
        "08987058-cadc-4b81-b6e1-30de50dcbe96": "Windows Hello",
        "9ddd1817-af5a-4672-a2b9-3e3dd95000a9": "Windows Hello",
        "6028b017-b1d4-4c02-b4b3-afcdafc96bb2": "Windows Hello",
        "bada5566-a7aa-401f-bd96-45619a55120d": "1Password",
        "d548826e-79b4-db40-a3d8-11116f7e8349": "Bitwarden",
        "531126d6-e717-415c-9320-3d9aa6981239": "Dashlane",
        "53414d53-554e-4700-0000-000000000000": "Samsung Pass",
        "fdb141b2-5d84-443e-8a35-4698c205a502": "KeePassXC",
    ]

    public static func name(aaguid: String) -> String? { names[aaguid.lowercased()] }
}

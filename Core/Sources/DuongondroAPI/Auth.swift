import Foundation

/// Signing up and in (onboarding v2): magic links mailed with an 8-character
/// code, and passkeys. A sign-up says it is one (`signUp`, with the consent the
/// onboarding collected) and carries an invitation or admission code when there
/// is one; a server with open sign-up needs neither. Signing in sends no flag.
extension APIClient {
    // MARK: Magic links

    /// Mails a link (`https://duongondro.app/m#<token>`) and an 8-character code,
    /// both good for 15 minutes. With `signUp`, redeeming either makes the account
    /// when none uses the address, and its failures throw `SignUpFailure`; without,
    /// only an address with an account gets mail. 429: too many requests.
    public func requestMagicLink(email: String, signUp: SignUp? = nil) async throws {
        try await signingUp(signUp != nil) {
            try await send("POST", "api/auth/magic-links", body: MagicLinkRequest(email: email, signUp: signUp))
        }
    }

    /// Redeems an opened link's token. 400: wrong, expired or used; 403: no account
    /// uses the address and the link was no sign-up, or sign-up closed since it was
    /// sent; 404: the invitation stopped being valid since the link was sent.
    public func redeemMagicLink(token: String) async throws -> SignInResult {
        try await send("POST", "api/auth/magic-links/redeem", body: MagicLinkRedemption(token: token, email: nil, code: nil))
    }

    /// Redeems the code typed from the mail, with the address it went to.
    public func redeemMagicLink(email: String, code: String) async throws -> SignInResult {
        try await send("POST", "api/auth/magic-links/redeem", body: MagicLinkRedemption(token: nil, email: email, code: code))
    }

    // MARK: An email for a signed-in account

    /// Mails an 8-character code that adds `email` to this account as a second way
    /// to sign in (15 minutes). 204 also when the account has the address already.
    /// 400: not an address; 429: too many mails.
    public func requestEmailConfirmation(email: String) async throws {
        try await send("POST", "api/me/email", body: EmailRequest(email: email))
    }

    /// Confirms the address with the typed code. 400: wrong, expired or replaced;
    /// 409: another account signs in with it; 429: too many tries.
    public func confirmEmail(code: String) async throws {
        try await send("POST", "api/me/email/verify", body: EmailConfirmation(code: code))
    }

    // MARK: Passkeys

    /// Starts making an account with a passkey; the profile names the passkey and
    /// is set when the account is made. Throws `SignUpFailure` for 403, 404 and
    /// 429; 409 (`APIError.conflict`): the username is taken.
    public func beginPasskeySignUp(_ signUp: SignUp, profile: Profile = Profile()) async throws -> Ceremony {
        try await signingUp {
            try await send("POST", "api/auth/passkeys/sign-up", body: PasskeySignUp(signUp: signUp, profile: profile))
        }
    }

    /// Completes a passkey sign-up: as `finishPasskey`, with 403 (sign-up closed
    /// since it began), 404 and 429 as `SignUpFailure`.
    public func finishPasskeySignUp(ceremony: UUID, credential: JSONValue) async throws -> SignInResult {
        try await signingUp { try await finishPasskey(ceremony: ceremony, credential: credential) }
    }

    /// Runs a sign-up call, its refusals typed as `SignUpFailure`.
    private func signingUp<T>(_ isSignUp: Bool = true, _ call: () async throws -> T) async throws -> T {
        do {
            return try await call()
        } catch let error as APIError {
            guard isSignUp, let failure = SignUpFailure(error) else { throw error }
            throw failure
        }
    }

    /// Starts a discoverable sign-in: the phone offers the passkeys it has.
    public func beginPasskeySignIn() async throws -> Ceremony {
        try await request("POST", "api/auth/passkeys/sign-in", query: [], body: Optional<Empty>.none)
    }

    /// Completes a passkey sign-up or sign-in with the authenticator's response.
    public func finishPasskey(ceremony: UUID, credential: JSONValue) async throws -> SignInResult {
        try await send("POST", "api/auth/passkeys/\(ceremony.lowercased)", body: PasskeyResponse(credential: credential))
    }

    /// Starts adding a passkey to the signed-in account.
    public func beginPasskeyAdd() async throws -> Ceremony {
        try await request("POST", "api/me/passkeys", query: [], body: Optional<Empty>.none)
    }

    public func finishPasskeyAdd(ceremony: UUID, credential: JSONValue) async throws {
        try await send("POST", "api/me/passkeys/\(ceremony.lowercased)", body: PasskeyResponse(credential: credential))
    }

    // MARK: The session and the profile

    /// Ends this session; its token stops working.
    public func signOut() async throws {
        let _: Empty = try await request("DELETE", "api/me/session", query: [], body: Optional<Empty>.none)
    }

    /// `PATCH /api/me`: each field is left as it is, set, or (username and gender)
    /// cleared. 409: the username is taken, regardless of case.
    public func updateMe(displayName: String? = nil, username: Patch<String> = .keep, gender: Patch<String> = .keep) async throws {
        try await send("PATCH", "api/me", body: MePatch(displayName: displayName, username: username, gender: gender))
    }
}

/// A field of a partial update: absent, an explicit null, or a value.
public enum Patch<Value: Encodable & Equatable & Sendable>: Equatable, Sendable {
    case keep
    case clear
    case set(Value)

    /// nil clears.
    public init(_ value: Value?) {
        self = value.map(Patch.set) ?? .clear
    }
}

struct MePatch: Encodable {
    let displayName: String?
    let username: Patch<String>
    let gender: Patch<String>

    enum CodingKeys: String, CodingKey { case displayName, username, gender }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(displayName, forKey: .displayName)
        for (field, key) in [(username, CodingKeys.username), (gender, .gender)] {
            switch field {
            case .keep: break
            case .clear: try c.encodeNil(forKey: key)
            case .set(let v): try c.encode(v, forKey: key)
            }
        }
    }
}

/// The invitation or admission code a sign-up presents.
public enum SignUpProof: Equatable, Sendable {
    /// A friend's invitation: its id and auth = HKDF(secret, "invite-auth"); the
    /// secret itself never reaches the server.
    case invite(id: String, auth: Data)
    /// A single-use admission code, 16 Crockford characters.
    case admission(String)
}

/// A sign-up: `signUp: true` on the request, with the onboarding's consent (GDPR
/// Article 9, which the server requires with the flag) and the invitation or
/// admission code, when there is one.
public struct SignUp: Equatable, Sendable {
    public var proof: SignUpProof?
    public var consent: Bool

    public init(proof: SignUpProof? = nil, consent: Bool) {
        self.proof = proof
        self.consent = consent
    }
}

/// Why the server refused to start or finish a sign-up.
public enum SignUpFailure: Error, Equatable {
    /// 403: this server makes accounts only with an invitation or admission code
    /// (open sign-up is off, or was turned off since the sign-up began).
    case invitationNeeded
    /// 404: the invitation or admission code is unknown, spent, revoked or expired.
    case unknownInvitation
    /// 429 from the limits on sign-ups without an invitation from one network in
    /// an hour (accounts made; sign-up mails requested). A sign-up with a code is
    /// not limited.
    case tooManyAccounts
    /// Any other 429: too many requests (or sign-in mails to one address).
    case tooManyRequests

    /// The sign-up refusal an API error means, or nil for any other error.
    public init?(_ error: APIError) {
        switch error {
        case .forbidden: self = .invitationNeeded
        case .notFound: self = .unknownInvitation
        // The limits share 429 and differ only in their message: the per-network
        // sign-up limits' name the network.
        case .tooManyRequests(let message): self = message.lowercased().contains("network") ? .tooManyAccounts : .tooManyRequests
        default: return nil
        }
    }
}

/// The profile a passkey sign-up carries; nil fields are left out.
public struct Profile: Equatable, Sendable {
    public var displayName: String?
    public var username: String?
    /// "male", "female" or "nonbinary".
    public var gender: String?

    public init(displayName: String? = nil, username: String? = nil, gender: String? = nil) {
        self.displayName = displayName
        self.username = username
        self.gender = gender
    }
}

struct InviteProofBody: Encodable { let id: String; let auth: Data }

private enum SignUpKeys: String, CodingKey { case invite, admissionCode, signUp, consent }

/// `signUp` and `consent`, and the code when there is one; nothing for a sign-in.
private func encodeSignUp(_ signUp: SignUp?, to encoder: Encoder) throws {
    guard let signUp else { return }
    var c = encoder.container(keyedBy: SignUpKeys.self)
    try c.encode(true, forKey: .signUp)
    try c.encode(signUp.consent, forKey: .consent)
    switch signUp.proof {
    case .invite(let id, let auth): try c.encode(InviteProofBody(id: id.uppercased(), auth: auth), forKey: .invite)
    case .admission(let code): try c.encode(code, forKey: .admissionCode)
    case nil: break
    }
}

struct MagicLinkRequest: Encodable {
    let email: String
    let signUp: SignUp?

    enum CodingKeys: String, CodingKey { case email }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(email, forKey: .email)
        try encodeSignUp(signUp, to: encoder)
    }
}

struct MagicLinkRedemption: Encodable {
    let token: String?
    let email: String?
    let code: String?
}

struct PasskeySignUp: Encodable {
    let signUp: SignUp
    let profile: Profile

    enum CodingKeys: String, CodingKey { case username, displayName, gender }

    func encode(to encoder: Encoder) throws {
        try encodeSignUp(signUp, to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(profile.username, forKey: .username)
        try c.encodeIfPresent(profile.displayName, forKey: .displayName)
        try c.encodeIfPresent(profile.gender, forKey: .gender)
    }
}

struct PasskeyResponse: Encodable { let credential: JSONValue }

public struct SignInResult: Codable, Equatable, Sendable {
    /// The bearer token.
    public let token: String
    public let userId: UUID
    /// The redemption or passkey made a new account.
    public let created: Bool

    public init(token: String, userId: UUID, created: Bool) {
        self.token = token
        self.userId = userId
        self.created = created
    }
}

/// A WebAuthn ceremony the server started: its id, and the options for the
/// platform authenticator (`{"publicKey": {...}}`).
public struct Ceremony: Codable, Equatable, Sendable {
    public let sessionId: UUID
    public let options: JSONValue

    public init(sessionId: UUID, options: JSONValue) {
        self.sessionId = sessionId
        self.options = options
    }

    /// The `publicKey` member, or the options themselves when they have none.
    public var publicKey: JSONValue { options["publicKey"] ?? options }
}

/// Any JSON value, for WebAuthn's options and credentials, which the API passes
/// through as they are.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n.rounded() == n, abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var array: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }
}

struct EmailRequest: Encodable {
    let email: String
}

struct EmailConfirmation: Encodable {
    let code: String
}

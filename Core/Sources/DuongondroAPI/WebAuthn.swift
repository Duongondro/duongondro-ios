import Foundation

/// The server's WebAuthn options (go-webauthn's JSON, byte strings as
/// base64url) read into what AuthenticationServices takes, and the platform
/// authenticator's answer written back as the WebAuthn JSON the server parses.
/// Pure, so the mapping is tested without a passkey.
public enum WebAuthn {
    /// The relying party when the options name none: the apex domain, which
    /// serves the webcredentials association.
    public static let defaultRelyingParty = "duongondro.app"

    /// What a registration (a new passkey) needs.
    public struct Creation: Equatable, Sendable {
        public let relyingParty: String
        public let challenge: Data
        public let userID: Data
        /// Names the passkey in the password manager.
        public let userName: String
        public let userVerification: String?
    }

    /// What an assertion (signing in with a passkey) needs.
    public struct Assertion: Equatable, Sendable {
        public let relyingParty: String
        public let challenge: Data
        /// Empty for a discoverable sign-in: the phone offers whatever it has.
        public let allowedCredentials: [Data]
        public let userVerification: String?
    }

    public static func creation(_ publicKey: JSONValue) -> Creation? {
        guard let challenge = publicKey["challenge"]?.string.flatMap(data(base64URL:)),
              let user = publicKey["user"],
              let userID = user["id"]?.string.flatMap(data(base64URL:)) else { return nil }
        let name = user["name"]?.string ?? user["displayName"]?.string ?? ""
        return Creation(relyingParty: publicKey["rp"]?["id"]?.string ?? defaultRelyingParty, challenge: challenge,
                        userID: userID, userName: name,
                        userVerification: publicKey["authenticatorSelection"]?["userVerification"]?.string)
    }

    public static func assertion(_ publicKey: JSONValue) -> Assertion? {
        guard let challenge = publicKey["challenge"]?.string.flatMap(data(base64URL:)) else { return nil }
        let allowed = (publicKey["allowCredentials"]?.array ?? []).compactMap { $0["id"]?.string.flatMap(data(base64URL:)) }
        return Assertion(relyingParty: publicKey["rpId"]?.string ?? defaultRelyingParty, challenge: challenge,
                         allowedCredentials: allowed, userVerification: publicKey["userVerification"]?.string)
    }

    /// A PublicKeyCredential for a registration, as the server's finish call takes it.
    /// No authenticatorAttachment: a passkey from another device (hybrid) is not
    /// a platform one, and the member is optional.
    public static func registration(credentialID: Data, clientDataJSON: Data, attestationObject: Data) -> JSONValue {
        let id = base64URL(credentialID)
        return .object([
            "id": .string(id),
            "rawId": .string(id),
            "type": .string("public-key"),
            "response": .object([
                "clientDataJSON": .string(base64URL(clientDataJSON)),
                "attestationObject": .string(base64URL(attestationObject)),
                "transports": .array([.string("internal"), .string("hybrid")]),
            ]),
            "clientExtensionResults": .object([:]),
        ])
    }

    /// A PublicKeyCredential for an assertion.
    public static func assertion(credentialID: Data, clientDataJSON: Data, authenticatorData: Data, signature: Data,
                                 userHandle: Data?) -> JSONValue {
        let id = base64URL(credentialID)
        var response: [String: JSONValue] = [
            "clientDataJSON": .string(base64URL(clientDataJSON)),
            "authenticatorData": .string(base64URL(authenticatorData)),
            "signature": .string(base64URL(signature)),
        ]
        if let userHandle, !userHandle.isEmpty { response["userHandle"] = .string(base64URL(userHandle)) }
        return .object([
            "id": .string(id),
            "rawId": .string(id),
            "type": .string("public-key"),
            "response": .object(response),
            "clientExtensionResults": .object([:]),
        ])
    }

    /// The credential with `clientExtensionResults` emptied: a PRF output, or
    /// anything derived from it, must never be posted (docs/crypto.md › Passkey
    /// unlock). The PRF input is made on the phone; the options' `extensions` are
    /// never read.
    public static func withoutExtensionResults(_ credential: JSONValue) -> JSONValue {
        guard case .object(var o) = credential else { return credential }
        o["clientExtensionResults"] = .object([:])
        return .object(o)
    }

    /// base64url without padding, as WebAuthn writes byte strings.
    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Reads base64url, padded or not (standard base64 too).
    public static func data(base64URL text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s = s.replacingOccurrences(of: "=", with: "")
        while s.count % 4 != 0 { s.append("=") }
        return Data(base64Encoded: s)
    }
}

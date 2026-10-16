import AuthenticationServices
import CryptoKit
import DuongondroAPI
import DuongondroCrypto
import DuongondroSync
import UIKit

/// Passkeys through AuthenticationServices (iOS 16): the relying party is
/// duongondro.app, which the system checks against the site's
/// apple-app-site-association (webcredentials) and the app's associated-domains
/// entitlement. iCloud Keychain keeps them, so a new iPhone has them too.
@MainActor
enum Passkeys {
    enum Failure: Error {
        /// The options the server sent cannot be read.
        case badOptions
        /// The system refused: no association with the relying party (a development
        /// server on localhost), or no passcode on this phone.
        case refused(String)
        /// The passkey that answered gives no PRF output, so it cannot unlock the counts.
        case noPRF
    }

    /// A new passkey: the registration response (WebAuthn JSON) for the server,
    /// and what the PRF extension gave at creation (iOS 18 and later).
    struct Created {
        let json: JSONValue
        let credentialID: Data
        /// The PRF output, when the password manager gives one at creation.
        let prf: Data?
        /// The passkey can give a PRF output (perhaps only when signing in).
        let prfSupported: Bool
    }

    /// A sign-in: the assertion (WebAuthn JSON) for the server, and the PRF output.
    struct Asserted {
        let json: JSONValue
        let credentialID: Data
        let prf: Data?
    }

    /// The registration; nil when the person backed out. Asks for the PRF output
    /// with the fixed input (docs/crypto.md › Passkey unlock), never the server's.
    static func create(_ ceremony: Ceremony) async throws -> Created? {
        guard let options = WebAuthn.creation(ceremony.publicKey) else { throw Failure.badOptions }
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: options.relyingParty)
        let request = provider.createCredentialRegistrationRequest(challenge: options.challenge, name: options.userName,
                                                                   userID: options.userID)
        if let uv = options.userVerification { request.userVerificationPreference = .init(rawValue: uv) }
        if #available(iOS 18, *) { request.prf = .inputValues(.init(saltInput1: E2EE.prfInput)) }
        guard let credential = try await perform(request) as? ASAuthorizationPlatformPublicKeyCredentialRegistration,
              let attestation = credential.rawAttestationObject else { return nil }
        var prf: Data?
        var supported = false
        if #available(iOS 18, *), let result = credential.prf {
            supported = result.isSupported
            prf = result.first.map(\.data)
        }
        return Created(json: WebAuthn.registration(credentialID: credential.credentialID,
                                                   clientDataJSON: credential.rawClientDataJSON, attestationObject: attestation),
                       credentialID: credential.credentialID, prf: prf, prfSupported: supported || prf != nil)
    }

    /// The assertion; nil when there is no passkey or the person backed out.
    static func assert(_ ceremony: Ceremony) async throws -> Asserted? {
        guard let options = WebAuthn.assertion(ceremony.publicKey) else { throw Failure.badOptions }
        let request = assertionRequest(relyingParty: options.relyingParty, challenge: options.challenge,
                                       allowed: options.allowedCredentials)
        if let uv = options.userVerification { request.userVerificationPreference = .init(rawValue: uv) }
        guard let credential = try await perform(request) as? ASAuthorizationPlatformPublicKeyCredentialAssertion else { return nil }
        return Asserted(json: WebAuthn.assertion(credentialID: credential.credentialID, clientDataJSON: credential.rawClientDataJSON,
                                                 authenticatorData: credential.rawAuthenticatorData, signature: credential.signature,
                                                 userHandle: credential.userID),
                        credentialID: credential.credentialID, prf: prfOutput(credential))
    }

    /// Whether this system can ask a passkey for a PRF output at all.
    static var prfAvailable: Bool {
        if #available(iOS 18, *) { return true }
        return false
    }

    /// A ceremony only for the PRF output, with a challenge made here: nothing
    /// goes to the server and nobody is signed in. `allowed` empty offers every
    /// passkey of the account's relying party; nil when cancelled or before iOS 18.
    static func prf(allowing allowed: [Data] = []) async throws -> PasskeyPRF? {
        guard prfAvailable else { return nil }
        let request = assertionRequest(relyingParty: WebAuthn.defaultRelyingParty, challenge: random(32), allowed: allowed)
        request.userVerificationPreference = .required
        guard let credential = try await perform(request) as? ASAuthorizationPlatformPublicKeyCredentialAssertion else { return nil }
        guard let output = prfOutput(credential) else { throw Failure.noPRF }
        return PasskeyPRF(credentialID: credential.credentialID, output: output)
    }

    private static func assertionRequest(relyingParty: String, challenge: Data,
                                         allowed: [Data]) -> ASAuthorizationPlatformPublicKeyCredentialAssertionRequest {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: relyingParty)
        let request = provider.createCredentialAssertionRequest(challenge: challenge)
        request.allowedCredentials = allowed.map(ASAuthorizationPlatformPublicKeyCredentialDescriptor.init)
        if #available(iOS 18, *) { request.prf = .inputValues(.init(saltInput1: E2EE.prfInput)) }
        return request
    }

    private static func prfOutput(_ credential: ASAuthorizationPlatformPublicKeyCredentialAssertion) -> Data? {
        if #available(iOS 18, *) { return credential.prf.map(\.first.data) }
        return nil
    }

    private static func random(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    /// Runs one request; nil when cancelled. The delegate is kept alive until it answers.
    private static func perform(_ request: ASAuthorizationRequest) async throws -> ASAuthorizationCredential? {
        try await withCheckedThrowingContinuation { continuation in
            let controller = ASAuthorizationController(authorizationRequests: [request])
            let delegate = Delegate(continuation: continuation)
            controller.delegate = delegate
            controller.presentationContextProvider = delegate
            objc_setAssociatedObject(controller, &Delegate.key, delegate, .OBJC_ASSOCIATION_RETAIN)
            controller.performRequests()
        }
    }

    private final class Delegate: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
        static var key = 0
        private var continuation: CheckedContinuation<ASAuthorizationCredential?, Error>?

        init(continuation: CheckedContinuation<ASAuthorizationCredential?, Error>) {
            self.continuation = continuation
        }

        func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
            continuation?.resume(returning: authorization.credential)
            continuation = nil
        }

        func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
            if let e = error as? ASAuthorizationError, e.code == .canceled {
                continuation?.resume(returning: nil)
            } else {
                continuation?.resume(throwing: Failure.refused(String(describing: error)))
            }
            continuation = nil
        }

        func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
            // The scene in front: its key window, else its first. A bare anchor
            // would be no window at all.
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let active = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            return active?.windows.first(where: \.isKeyWindow) ?? active?.windows.first ?? ASPresentationAnchor()
        }
    }
}

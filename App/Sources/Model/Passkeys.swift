import AuthenticationServices
import DuongondroAPI
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
    }

    /// The registration response (WebAuthn JSON); nil when the person backed out.
    static func create(_ ceremony: Ceremony) async throws -> JSONValue? {
        guard let options = WebAuthn.creation(ceremony.publicKey) else { throw Failure.badOptions }
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: options.relyingParty)
        let request = provider.createCredentialRegistrationRequest(challenge: options.challenge, name: options.userName,
                                                                   userID: options.userID)
        if let uv = options.userVerification { request.userVerificationPreference = .init(rawValue: uv) }
        guard let credential = try await perform(request) as? ASAuthorizationPlatformPublicKeyCredentialRegistration,
              let attestation = credential.rawAttestationObject else { return nil }
        return WebAuthn.registration(credentialID: credential.credentialID, clientDataJSON: credential.rawClientDataJSON,
                                     attestationObject: attestation)
    }

    /// The assertion (WebAuthn JSON); nil when there is no passkey or the person backed out.
    static func assert(_ ceremony: Ceremony) async throws -> JSONValue? {
        guard let options = WebAuthn.assertion(ceremony.publicKey) else { throw Failure.badOptions }
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: options.relyingParty)
        let request = provider.createCredentialAssertionRequest(challenge: options.challenge)
        request.allowedCredentials = options.allowedCredentials.map(ASAuthorizationPlatformPublicKeyCredentialDescriptor.init)
        if let uv = options.userVerification { request.userVerificationPreference = .init(rawValue: uv) }
        guard let credential = try await perform(request) as? ASAuthorizationPlatformPublicKeyCredentialAssertion else { return nil }
        return WebAuthn.assertion(credentialID: credential.credentialID, clientDataJSON: credential.rawClientDataJSON,
                                  authenticatorData: credential.rawAuthenticatorData, signature: credential.signature,
                                  userHandle: credential.userID)
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
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }
}

import AuthenticationServices
import CryptoKit
import UIKit

/// The PRF spike (design: Keys › Passkeys that unlock the counts): does iCloud
/// Keychain hand back a PRF output for a passkey of duongondro.app, at creation
/// or only at sign-in, and the same one every time? The requests are made here
/// with a random challenge and never go to the server, so the ceremony proves
/// nothing to anyone; only the extension's result matters. The PRF input is the
/// one docs/crypto.md (duongondro-api) fixes for Passkey unlock. PRF needs iOS 18;
/// on older systems the check says so instead of running.
final class PrfCheck: NSObject, ObservableObject {
    static let relyingParty = "duongondro.app"
    static let input = Data("duongondro/v1/prf".utf8)

    struct Result {
        var credentialID: Data
        var supported: Bool?   // creation only: whether the passkey can do PRF
        var output: Data?      // the first PRF output, if one came back
    }

    enum Failure: Error { case unsupportedSystem, unexpectedCredential }

    private var continuation: CheckedContinuation<ASAuthorization, Error>?
    private var anchor: ASPresentationAnchor?

    /// A discoverable sign-in with any passkey of duongondro.app, asking for the PRF output.
    @MainActor
    func signIn() async throws -> Result {
        guard #available(iOS 18, *) else { throw Failure.unsupportedSystem }
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: Self.relyingParty)
        let request = provider.createCredentialAssertionRequest(challenge: Self.random(32))
        request.prf = .inputValues(.init(saltInput1: Self.input))
        let authorization = try await perform(request)
        guard let assertion = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            throw Failure.unexpectedCredential
        }
        return Result(credentialID: assertion.credentialID, supported: nil,
                      output: assertion.prf.map { $0.first.withUnsafeBytes { Data($0) } })
    }

    /// A throwaway passkey named "PRF check" (never registered with the server, so
    /// it signs nobody in), asking for a PRF output at creation.
    @MainActor
    func create() async throws -> Result {
        guard #available(iOS 18, *) else { throw Failure.unsupportedSystem }
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: Self.relyingParty)
        let request = provider.createCredentialRegistrationRequest(challenge: Self.random(32), name: "PRF check", userID: Self.random(16))
        request.prf = .inputValues(.init(saltInput1: Self.input))
        let authorization = try await perform(request)
        guard let registration = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration else {
            throw Failure.unexpectedCredential
        }
        return Result(credentialID: registration.credentialID, supported: registration.prf?.isSupported,
                      output: registration.prf?.first.map { $0.withUnsafeBytes { Data($0) } })
    }

    /// A short fingerprint of a PRF output, to compare runs on screen without
    /// showing the output: the first 6 bytes of its SHA-256, hex.
    static func fingerprint(_ output: Data) -> String {
        SHA256.hash(data: output).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    private static func random(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    @MainActor
    private func perform(_ request: ASAuthorizationRequest) async throws -> ASAuthorization {
        anchor = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }
}

extension PrfCheck: ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    // The system calls these on the main thread, after perform set the anchor.
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        continuation?.resume(returning: authorization)
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        anchor ?? ASPresentationAnchor()
    }
}

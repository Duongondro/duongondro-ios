import XCTest
@testable import DuongondroAPI

final class WebAuthnTests: XCTestCase {
    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// go-webauthn's creation options, as BeginRegistration writes them.
    func testReadsCreationOptions() throws {
        let ceremony = Ceremony(sessionId: UUID(), options: try json("""
            {"publicKey":{"rp":{"name":"Duongöndro","id":"duongondro.app"},
             "user":{"name":"ana","displayName":"Ana","id":"AAECAwQ"},
             "challenge":"_-8","pubKeyCredParams":[{"type":"public-key","alg":-7}],"timeout":300000,
             "authenticatorSelection":{"requireResidentKey":true,"residentKey":"required","userVerification":"preferred"}}}
            """))
        let c = try XCTUnwrap(WebAuthn.creation(ceremony.publicKey))
        XCTAssertEqual(c.relyingParty, "duongondro.app")
        XCTAssertEqual(c.challenge, Data([0xFF, 0xEF]))
        XCTAssertEqual(c.userID, Data([0, 1, 2, 3, 4]))
        XCTAssertEqual(c.userName, "ana")
        XCTAssertEqual(c.userVerification, "preferred")
    }

    func testCreationWithoutAUserIsRefused() throws {
        XCTAssertNil(WebAuthn.creation(try json(#"{"challenge":"AA"}"#)))
    }

    func testReadsRequestOptions() throws {
        let discoverable = try XCTUnwrap(WebAuthn.assertion(try json(
            #"{"challenge":"AQID","timeout":300000,"rpId":"localhost","userVerification":"preferred"}"#)))
        XCTAssertEqual(discoverable.relyingParty, "localhost")
        XCTAssertEqual(discoverable.challenge, Data([1, 2, 3]))
        XCTAssertEqual(discoverable.allowedCredentials, [])
        let allowed = try XCTUnwrap(WebAuthn.assertion(try json(
            #"{"challenge":"AQID","allowCredentials":[{"type":"public-key","id":"BAU="}]}"#)))
        XCTAssertEqual(allowed.relyingParty, WebAuthn.defaultRelyingParty)
        XCTAssertEqual(allowed.allowedCredentials, [Data([4, 5])])
    }

    func testWritesTheRegistrationAsWebAuthnJSON() throws {
        let value = WebAuthn.registration(credentialID: Data([0xFB, 0xFF]), clientDataJSON: Data("{}".utf8),
                                          attestationObject: Data([1]))
        XCTAssertEqual(value["id"], .string("-_8"))
        XCTAssertEqual(value["rawId"], .string("-_8"))
        XCTAssertEqual(value["type"], .string("public-key"))
        XCTAssertEqual(value["response"]?["clientDataJSON"], .string("e30"))
        XCTAssertEqual(value["response"]?["attestationObject"], .string("AQ"))
        // Review found it: not every passkey is the platform's own (hybrid, from another device).
        XCTAssertNil(value["authenticatorAttachment"])
    }

    func testWritesTheAssertionWithItsUserHandle() throws {
        let value = WebAuthn.assertion(credentialID: Data([1]), clientDataJSON: Data([2]), authenticatorData: Data([3]),
                                       signature: Data([4]), userHandle: Data([5]))
        XCTAssertEqual(value["response"]?["authenticatorData"], .string("Aw"))
        XCTAssertEqual(value["response"]?["signature"], .string("BA"))
        XCTAssertEqual(value["response"]?["userHandle"], .string("BQ"))
        XCTAssertNil(value["authenticatorAttachment"])
        let anonymous = WebAuthn.assertion(credentialID: Data([1]), clientDataJSON: Data([2]), authenticatorData: Data([3]),
                                           signature: Data([4]), userHandle: nil)
        XCTAssertNil(anonymous["response"]?["userHandle"])
    }

    func testBase64URLRoundTrips() {
        for n in 0..<40 {
            let bytes = Data((0..<n).map { UInt8(truncatingIfNeeded: $0 * 37 + 251) })
            let text = WebAuthn.base64URL(bytes)
            XCTAssertFalse(text.contains("=") || text.contains("+") || text.contains("/"))
            XCTAssertEqual(WebAuthn.data(base64URL: text), bytes)
        }
    }

    // MARK: The PRF output never reaches the server

    /// Options that ask for PRF with the server's own input change nothing the
    /// phone reads: the input is the app's fixed label.
    func testTheServersExtensionsAreIgnored() throws {
        let plain = try json(#"{"rp":{"id":"duongondro.app"},"user":{"name":"a","id":"AA"},"challenge":"AA"}"#)
        let withPRF = try json(#"{"rp":{"id":"duongondro.app"},"user":{"name":"a","id":"AA"},"challenge":"AA","extensions":{"prf":{"eval":{"first":"c2VydmVy"}}}}"#)
        XCTAssertEqual(WebAuthn.creation(plain), WebAuthn.creation(withPRF))
        let request = try json(#"{"challenge":"AA","rpId":"duongondro.app","extensions":{"prf":{"eval":{"first":"c2VydmVy"}}}}"#)
        XCTAssertEqual(WebAuthn.assertion(request), WebAuthn.assertion(try json(#"{"challenge":"AA","rpId":"duongondro.app"}"#)))
    }

    /// What finish posts: no PRF result, ever, even from a credential that held one.
    func testTheFinishBodyCarriesNoPRFResult() throws {
        let output = Data(repeating: 0xAB, count: 32)
        let registration = WebAuthn.registration(credentialID: Data([1, 2]), clientDataJSON: Data("{}".utf8), attestationObject: Data([3]))
        let assertion = WebAuthn.assertion(credentialID: Data([1, 2]), clientDataJSON: Data("{}".utf8), authenticatorData: Data([4]),
                                           signature: Data([5]), userHandle: Data([6]))
        guard case .object(var leaky) = assertion else { return XCTFail() }
        leaky["clientExtensionResults"] = .object(["prf": .object(["enabled": .bool(true), "results": .object(["first": .string(WebAuthn.base64URL(output))])])])
        for credential in [registration, assertion, JSONValue.object(leaky)] {
            let body = try APIClient.encoder.encode(PasskeyResponse(credential: credential))
            let text = String(decoding: body, as: UTF8.self)
            XCTAssertFalse(text.contains("prf"), text)
            XCTAssertFalse(text.contains(WebAuthn.base64URL(output)), text)
            XCTAssertFalse(text.contains(output.base64EncodedString()), text)
            let object = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            let results = (object["credential"] as! [String: Any])["clientExtensionResults"] as! [String: Any]
            XCTAssertTrue(results.isEmpty)
        }
    }
}

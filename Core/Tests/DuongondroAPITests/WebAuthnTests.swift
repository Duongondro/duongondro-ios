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
}

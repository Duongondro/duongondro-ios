import XCTest
@testable import DuongondroAPI

/// Answers every request with the next canned response and records what was sent.
final class StubProtocol: URLProtocol {
    struct Sent { let method: String; let path: String; let headers: [String: String]; let body: [String: Any]? }
    nonisolated(unsafe) static var responses: [(Int, String)] = []
    nonisolated(unsafe) static var sent: [Sent] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65536)
            var out = Data()
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                out.append(buffer, count: n)
            }
            stream.close()
            data = out
        }
        let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) as? [String: Any] }
        Self.sent.append(Sent(method: request.httpMethod ?? "", path: request.url!.path,
                              headers: request.allHTTPHeaderFields ?? [:], body: body))
        let (status, text) = Self.responses.isEmpty ? (204, "") : Self.responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class AuthTests: XCTestCase {
    var api: APIClient!

    override func setUp() {
        StubProtocol.responses = []
        StubProtocol.sent = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        api = APIClient(baseURL: URL(string: "https://api.example")!, session: URLSession(configuration: config))
    }

    var last: StubProtocol.Sent { StubProtocol.sent.last! }

    func testMagicLinkRequestCarriesTheProof() async throws {
        try await api.requestMagicLink(email: "a@b.c", signUp: SignUp(proof: .invite(id: "abcd1234", auth: Data([1, 2, 3])), consent: true))
        XCTAssertEqual(last.method, "POST")
        XCTAssertEqual(last.path, "/api/auth/magic-links")
        XCTAssertEqual(last.body?["email"] as? String, "a@b.c")
        let invite = last.body?["invite"] as? [String: Any]
        XCTAssertEqual(invite?["id"] as? String, "ABCD1234")
        XCTAssertEqual(invite?["auth"] as? String, "AQID")
        XCTAssertNil(last.body?["admissionCode"])
        XCTAssertEqual(last.body?["signUp"] as? Bool, true)
        XCTAssertEqual(last.body?["consent"] as? Bool, true)

        try await api.requestMagicLink(email: "a@b.c", signUp: SignUp(proof: .admission("0123456789ABCDEF"), consent: true))
        XCTAssertEqual(last.body?["admissionCode"] as? String, "0123456789ABCDEF")
        XCTAssertNil(last.body?["invite"])

        // A sign-in: no flag, no consent, no code.
        try await api.requestMagicLink(email: "a@b.c")
        XCTAssertEqual(last.body?.keys.sorted(), ["email"])
    }

    func testOpenSignUpSendsTheFlagAndConsentWithoutACode() async throws {
        try await api.requestMagicLink(email: "a@b.c", signUp: SignUp(consent: true))
        XCTAssertEqual(last.body?.keys.sorted(), ["consent", "email", "signUp"])
        XCTAssertEqual(last.body?["signUp"] as? Bool, true)
        XCTAssertEqual(last.body?["consent"] as? Bool, true)

        let session = UUID()
        StubProtocol.responses = [(200, #"{"sessionId":"\#(session.uuidString.lowercased())","options":{}}"#)]
        _ = try await api.beginPasskeySignUp(SignUp(consent: true), profile: Profile(displayName: "Ana"))
        XCTAssertEqual(last.path, "/api/auth/passkeys/sign-up")
        XCTAssertEqual(last.body?.keys.sorted(), ["consent", "displayName", "signUp"])
    }

    func testSignUpRefusalsAreTyped() async throws {
        let cases: [(Int, String, SignUpFailure)] = [
            (403, "an invitation or an admission code is needed to create an account", .invitationNeeded),
            (404, "not found", .unknownInvitation),
            (429, "too many new accounts from this network; try again later, or use an invitation", .tooManyAccounts),
            (429, "too many sign-in links to this address; try again in a few minutes", .tooManyRequests),
            (429, "too many sign-up mails requested from this network; try again later, or use an invitation", .tooManyAccounts),
        ]
        for (status, message, expected) in cases {
            StubProtocol.responses = [(status, #"{"error":"\#(message)"}"#)]
            do {
                try await api.requestMagicLink(email: "a@b.c", signUp: SignUp(consent: true))
                XCTFail("\(status) did not throw")
            } catch let failure as SignUpFailure {
                XCTAssertEqual(failure, expected, message)
            }
            StubProtocol.responses = [(status, #"{"error":"\#(message)"}"#)]
            do {
                _ = try await api.beginPasskeySignUp(SignUp(consent: true))
                XCTFail("\(status) did not throw")
            } catch let failure as SignUpFailure {
                XCTAssertEqual(failure, expected, message)
            }
            StubProtocol.responses = [(status, #"{"error":"\#(message)"}"#)]
            do {
                _ = try await api.finishPasskeySignUp(ceremony: UUID(), credential: .object([:]))
                XCTFail("\(status) did not throw")
            } catch let failure as SignUpFailure {
                XCTAssertEqual(failure, expected, message)
            }
        }
        // A sign-in keeps the plain API errors, and a username taken stays a conflict.
        StubProtocol.responses = [(429, #"{"error":"too many requests"}"#), (409, #"{"error":"taken"}"#)]
        do {
            try await api.requestMagicLink(email: "a@b.c")
            XCTFail("429 did not throw")
        } catch let error as APIError {
            XCTAssertEqual(error, .tooManyRequests("too many requests"))
        }
        do {
            _ = try await api.beginPasskeySignUp(SignUp(consent: true))
            XCTFail("409 did not throw")
        } catch let error as APIError {
            XCTAssertEqual(error, .conflict("taken"))
        }
    }

    func testRedeemingByTokenOrCode() async throws {
        let user = UUID()
        let answer = #"{"token":"t","userId":"\#(user.uuidString.lowercased())","created":true}"#
        StubProtocol.responses = [(200, answer), (200, answer)]
        let byToken = try await api.redeemMagicLink(token: "tok")
        XCTAssertEqual(byToken, SignInResult(token: "t", userId: user, created: true))
        XCTAssertEqual(last.path, "/api/auth/magic-links/redeem")
        XCTAssertEqual(last.body?.keys.sorted(), ["token"])
        _ = try await api.redeemMagicLink(email: "a@b.c", code: "ABCD1234")
        XCTAssertEqual(last.body?.keys.sorted(), ["code", "email"])
        XCTAssertEqual(last.body?["code"] as? String, "ABCD1234")
    }

    func testStatusesAreTyped() async throws {
        let cases: [(Int, APIError)] = [
            (400, .badRequest("bad")), (403, .forbidden("bad")), (404, .notFound),
            (409, .conflict("bad")), (429, .tooManyRequests("bad")), (401, .unauthorized),
        ]
        for (status, expected) in cases {
            StubProtocol.responses = [(status, #"{"error":"bad"}"#)]
            do {
                _ = try await api.redeemMagicLink(token: "x")
                XCTFail("\(status) did not throw")
            } catch let error as APIError {
                XCTAssertEqual(error, expected)
            }
        }
    }

    func testPasskeySignUpSendsProofAndProfile() async throws {
        let session = UUID()
        StubProtocol.responses = [(200, #"{"sessionId":"\#(session.uuidString.lowercased())","options":{"publicKey":{"challenge":"AAEC","timeout":60000}}}"#)]
        let ceremony = try await api.beginPasskeySignUp(SignUp(proof: .admission("CODE"), consent: true),
                                                        profile: Profile(displayName: "Ana", username: "ana", gender: nil))
        XCTAssertEqual(ceremony.sessionId, session)
        XCTAssertEqual(ceremony.publicKey["challenge"], .string("AAEC"))
        XCTAssertEqual(ceremony.publicKey["timeout"], .number(60000))
        XCTAssertEqual(last.path, "/api/auth/passkeys/sign-up")
        XCTAssertEqual(last.body?.keys.sorted(), ["admissionCode", "consent", "displayName", "signUp", "username"])
    }

    func testFinishingPasskeysPassesTheCredentialThrough() async throws {
        let session = UUID()
        StubProtocol.responses = [(200, #"{"token":"t","userId":"\#(UUID().uuidString)","created":false}"#), (204, "")]
        let credential: JSONValue = .object(["id": .string("abc"), "type": .string("public-key"),
                                             "response": .object(["clientDataJSON": .string("e30")])])
        _ = try await api.finishPasskey(ceremony: session, credential: credential)
        XCTAssertEqual(last.path, "/api/auth/passkeys/\(session.uuidString.lowercased())")
        let sent = last.body?["credential"] as? [String: Any]
        XCTAssertEqual(sent?["id"] as? String, "abc")
        XCTAssertEqual((sent?["response"] as? [String: Any])?["clientDataJSON"] as? String, "e30")
        try await api.finishPasskeyAdd(ceremony: session, credential: credential)
        XCTAssertEqual(last.path, "/api/me/passkeys/\(session.uuidString.lowercased())")
    }

    func testSignInAndAddBeginWithoutABody() async throws {
        let ceremony = #"{"sessionId":"\#(UUID().uuidString)","options":{}}"#
        StubProtocol.responses = [(200, ceremony), (200, ceremony)]
        _ = try await api.beginPasskeySignIn()
        XCTAssertEqual(last.path, "/api/auth/passkeys/sign-in")
        XCTAssertNil(last.body)
        _ = try await api.beginPasskeyAdd()
        XCTAssertEqual(last.path, "/api/me/passkeys")
    }

    func testPatchKeepsClearsOrSets() async throws {
        try await api.updateMe(displayName: "Ana", username: .set("ana"), gender: .clear)
        XCTAssertEqual(last.method, "PATCH")
        XCTAssertEqual(last.body?["displayName"] as? String, "Ana")
        XCTAssertEqual(last.body?["username"] as? String, "ana")
        XCTAssertTrue(last.body?["gender"] is NSNull)
        try await api.updateMe(username: .clear)
        XCTAssertEqual(last.body?.keys.sorted(), ["username"])
        XCTAssertTrue(last.body?["username"] is NSNull)
        try await api.setGender(nil)
        XCTAssertEqual(last.body?.keys.sorted(), ["gender"])
        try await api.setGender("female")
        XCTAssertEqual(last.body?["gender"] as? String, "female")
    }

    func testSignOutAndInvites() async throws {
        try await api.signOut()
        XCTAssertEqual(last.method, "DELETE")
        XCTAssertEqual(last.path, "/api/me/session")
        try await api.revokeInvite(id: "abcd1234")
        XCTAssertEqual(last.method, "DELETE")
        XCTAssertEqual(last.path, "/api/invites/ABCD1234")
        StubProtocol.responses = [(200, #"{"invites":[{"id":"ABCD1234","expiresAt":"2026-10-20T10:00:00.123456789Z","createdAt":"2026-10-13T10:00:00Z"}]}"#)]
        let list = try await api.invites()
        XCTAssertEqual(list.first?.id, "ABCD1234")
        XCTAssertNil(list.first?.revokedAt)
    }

    func testMeReadsTheUsername() throws {
        let json = #"{"id":"\#(UUID().uuidString)","keyVersion":1,"displayName":"Ana","username":"ana","devices":[]}"#
        let me = try APIClient.decoder.decode(Me.self, from: Data(json.utf8))
        XCTAssertEqual(me.username, "ana")
        XCTAssertNil(me.gender)
    }

    func testJSONValueRoundTrips() throws {
        let text = #"{"a":[1,2.5,"x",true,null],"b":{"c":-3}}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        let again = try JSONDecoder().decode(JSONValue.self, from: try JSONEncoder().encode(value))
        XCTAssertEqual(value, again)
        XCTAssertEqual(value["b"]?["c"], .number(-3))
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(JSONValue.number(60000)), as: UTF8.self), "60000")
    }
}

import XCTest
@testable import DuongondroAPI

final class PasskeyTests: XCTestCase {
    func testAListedPasskeyReadsWithAndWithoutItsOptionalFields() throws {
        let json = Data("""
            {"passkeys":[
              {"id":"AbC-_d","createdAt":"2026-10-07T09:00:00Z","current":true,"canUnlock":false},
              {"id":"xyz","name":"Laptop key","aaguid":"FBFC3007-154E-4ECC-8C0B-6E020557D7BD",
               "createdAt":"2026-10-09T09:00:00.123456789Z","lastUsedAt":"2026-10-12T10:00:00Z","current":false,"canUnlock":true}]}
            """.utf8)
        let list = try APIClient.decoder.decode(PasskeyList.self, from: json).passkeys
        XCTAssertEqual(list.count, 2)
        XCTAssertNil(list[0].lastUsedAt)
        XCTAssertTrue(list[0].current)
        XCTAssertNil(list[0].displayName, "no name, no AAGUID: the app says Passkey")
        XCTAssertEqual(list[1].displayName, "Laptop key", "the person's name first")
        XCTAssertTrue(list[1].canUnlock)
    }

    func testAnUnnamedPasskeyIsCalledAfterItsPasswordManager() {
        let icloud = Passkey(id: "a", aaguid: "fbfc3007-154e-4ecc-8c0b-6e020557d7bd", createdAt: Date())
        XCTAssertEqual(icloud.displayName, "iCloud Keychain")
        let blank = Passkey(id: "b", name: "  ", aaguid: "ea9b8d66-4d01-1d21-3ce4-b6b48cb575d4", createdAt: Date())
        XCTAssertEqual(blank.displayName, "Google Password Manager")
        XCTAssertNil(Passkey(id: "c", aaguid: "00000000-0000-0000-0000-000000000001", createdAt: Date()).displayName)
    }

    func testRenamingSendsTheNameOrAnExplicitNull() throws {
        XCTAssertEqual(String(decoding: try APIClient.encoder.encode(PasskeyRename(name: "Phone")), as: UTF8.self), #"{"name":"Phone"}"#)
        XCTAssertEqual(String(decoding: try APIClient.encoder.encode(PasskeyRename(name: nil)), as: UTF8.self), #"{"name":null}"#)
    }

    func testTheUserKeyCreateNeverAsksToReplace() throws {
        let body = try JSONSerialization.jsonObject(with: APIClient.encoder.encode(UserKeyInput(payload: Data([1]), signature: Data([2])))) as! [String: Any]
        XCTAssertEqual(Set(body.keys), ["payload", "signature"])
    }

    func testARotationWithoutAUserKeyLeavesTheFieldOut() throws {
        let body = try JSONSerialization.jsonObject(with: APIClient.encoder.encode(KeyRotation(newVersion: 2, wraps: []))) as! [String: Any]
        XCTAssertNil(body["userKeyWrap"])
    }
}

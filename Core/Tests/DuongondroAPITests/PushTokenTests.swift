import XCTest
@testable import DuongondroAPI

final class PushTokenTests: XCTestCase {
    var api: APIClient!

    override func setUp() {
        StubProtocol.responses = []
        StubProtocol.sent = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        api = APIClient(baseURL: URL(string: "https://api.example")!, token: "t", session: URLSession(configuration: config))
    }

    func testPutAndDeleteThisDevicesToken() async throws {
        let device = UUID(uuidString: "0192F3A4-0000-7000-8000-00000000ABCD")!
        try await api.putPushToken(device: device, platform: "apns-sandbox", token: "00ff")
        var sent = StubProtocol.sent.last!
        XCTAssertEqual(sent.method, "PUT")
        XCTAssertEqual(sent.path, "/api/devices/0192f3a4-0000-7000-8000-00000000abcd/push-token")
        XCTAssertEqual(sent.body?["platform"] as? String, "apns-sandbox")
        XCTAssertEqual(sent.body?["token"] as? String, "00ff")
        XCTAssertEqual(sent.headers["Authorization"], "Bearer t")

        try await api.deletePushToken(device: device)
        sent = StubProtocol.sent.last!
        XCTAssertEqual(sent.method, "DELETE")
        XCTAssertEqual(sent.path, "/api/devices/0192f3a4-0000-7000-8000-00000000abcd/push-token")
        XCTAssertNil(sent.body)
    }
}

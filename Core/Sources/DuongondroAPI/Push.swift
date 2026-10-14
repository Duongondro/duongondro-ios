import Foundation

/// This device's push token (api/openapi.yaml, /api/devices/{deviceId}/push-token).
extension APIClient {
    /// `platform` is "apns" or "apns-sandbox" (or "fcm"); an APNs token is hexadecimal.
    public func putPushToken(device: UUID, platform: String, token: String) async throws {
        try await send("PUT", "api/devices/\(device.lowercased)/push-token", body: PushTokenInput(platform: platform, token: token))
    }

    public func deletePushToken(device: UUID) async throws {
        let _: Empty = try await request("DELETE", "api/devices/\(device.lowercased)/push-token", query: [], body: Optional<Empty>.none)
    }
}

struct PushTokenInput: Codable {
    let platform: String
    let token: String
}

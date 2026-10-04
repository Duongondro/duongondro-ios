import Foundation
import Security
import UserNotifications
import DuongondroStore

/// The local half of "Delete everything" (design: Data export and deletion ›
/// Purge). With an account, `DELETE /api/me` comes first and this runs only
/// after the server confirms; in local mode there is nothing on any server.
@MainActor
enum Purge {
    static func run(_ model: AppModel) throws {
        model.discardInFlight()
        try model.database.eraseAll()
        deleteKeychainItems()
        let fm = FileManager.default
        for folder in [Covers.folderURL(), ExportFile.folderURL()] {
            try? fm.removeItem(at: folder)
        }
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    /// Every Keychain item this app owns, the device key included (a Secure
    /// Enclave key is a kSecClassKey item; deleting it destroys the key).
    static func deleteKeychainItems() {
        for itemClass in [kSecClassGenericPassword, kSecClassInternetPassword, kSecClassKey,
                          kSecClassCertificate, kSecClassIdentity] {
            SecItemDelete([kSecClass as String: itemClass] as CFDictionary)
        }
    }
}

/// Local-only cover photos: never uploaded, excluded from device backups.
enum Covers {
    static func folderURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Covers", isDirectory: true)
    }

    /// Every cover on the phone, by practice id, for the export.
    static func all() -> [String: Data] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folderURL().path) else { return [:] }
        var out: [String: Data] = [:]
        for name in names where name.hasSuffix(".jpg") {
            out[String(name.dropLast(4))] = try? Data(contentsOf: folderURL().appendingPathComponent(name))
        }
        return out
    }
}

/// Where the export ZIP is written before the share sheet takes it; emptied on
/// every new export and by the purge.
enum ExportFile {
    static func folderURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Export", isDirectory: true)
    }

    static func write(_ data: Data, name: String) throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: folderURL())
        try fm.createDirectory(at: folderURL(), withIntermediateDirectories: true)
        let url = folderURL().appendingPathComponent(name)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
}

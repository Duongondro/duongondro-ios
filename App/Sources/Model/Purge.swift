import Foundation
import UIKit
import Security
import UserNotifications
import DuongondroCore
import DuongondroStore

/// The local half of "Delete everything" (design: Data export and deletion ›
/// Purge). With an account, `DELETE /api/me` comes first and this runs only
/// after the server confirms; in local mode there is nothing on any server.
@MainActor
enum Purge {
    /// Every step runs even if an earlier one fails; the first error is thrown
    /// at the end, so a database error never leaves keys or files behind.
    static func run(_ model: AppModel) throws {
        model.discardInFlight()
        var failure: Error?
        do { try model.database.eraseAll() } catch { failure = error }
        deleteKeychainItems()
        let fm = FileManager.default
        for folder in [Covers.folderURL(), ExportFile.folderURL()] {
            try? fm.removeItem(at: folder)
        }
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        UserDefaults.standard.removeObject(forKey: Gender.storageKey)
        if let failure { throw failure }
    }

    /// Every Keychain item this app owns, the device key included (a Secure
    /// Enclave key is a kSecClassKey item; deleting it destroys the key).
    static func deleteKeychainItems() {
        for itemClass in [kSecClassGenericPassword, kSecClassInternetPassword, kSecClassKey,
                          kSecClassCertificate, kSecClassIdentity] {
            // Synchronizable "any" reaches iCloud Keychain items too.
            SecItemDelete([kSecClass as String: itemClass,
                           kSecAttrSynchronizable as String: kSecAttrSynchronizableAny] as CFDictionary)
        }
    }
}

/// Local-only cover photos: never uploaded, excluded from device backups.
enum Covers {
    static func folderURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Covers", isDirectory: true)
    }

    static func url(for practiceID: String) -> URL {
        folderURL().appendingPathComponent(practiceID + ".jpg")
    }

    /// The person's own photo for a practice, if they chose one.
    static func photo(for practiceID: String) -> UIImage? {
        UIImage(contentsOfFile: url(for: practiceID).path)
    }

    /// The thangka a built-in practice shows by default, if the app has one.
    static func builtIn(for practiceID: String) -> UIImage? {
        UIImage(named: "cover-" + practiceID)
    }

    /// Saves a chosen photo, scaled down and re-encoded (which also drops its
    /// location and camera metadata), in a folder kept out of device backups.
    static func save(_ data: Data, for practiceID: String) throws {
        guard let image = UIImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
        let longest: CGFloat = 1600
        let scale = min(1, longest / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpeg = scaled.jpegData(compressionQuality: 0.85) else { throw CocoaError(.fileWriteUnknown) }
        var folder = folderURL()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        try jpeg.write(to: url(for: practiceID), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func remove(for practiceID: String) {
        try? FileManager.default.removeItem(at: url(for: practiceID))
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

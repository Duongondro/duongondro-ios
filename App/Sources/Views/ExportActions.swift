import SwiftUI
import UIKit
import DuongondroCore
import DuongondroStore

/// Settings › Your data › Export, as CodeShare's Manage my data does it (design: Data
/// export and deletion › Export): one row per format, the open undo window closed
/// first, the file built on this phone (offline and in local mode from the local
/// database alone) while the screen shows progress, then the share sheet; the file
/// is removed once shared.
@MainActor
final class ExportController: ObservableObject {
    @Published private(set) var working = false
    @Published var problem: String?
    /// The last export went out without the server's part.
    @Published private(set) var serverMissing = false

    func export(_ format: ExportFormat, model: AppModel, account: AccountModel) async {
        guard !working else { return }
        working = true
        defer { working = false }
        // Final sessions only: the open undo window closes first.
        model.finalisePending()
        do {
            let result = try await ExportBuilder(model: model, account: account).build(format)
            serverMissing = result.serverMissing
            let sheet = UIActivityViewController(activityItems: [result.url], applicationActivities: nil)
            sheet.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: result.url) }
            guard let presenter = await Self.presenter() else {
                // Nothing to show it over: say so rather than leave the file behind.
                try? FileManager.default.removeItem(at: result.url)
                problem = String(localized: "The share sheet could not be shown. Try again.", table: "Export",
                                 bundle: .appLanguage, locale: .appLanguage)
                return
            }
            sheet.popoverPresentationController?.sourceView = presenter.view
            presenter.present(sheet, animated: true)
        } catch {
            problem = error.localizedDescription
        }
    }

    /// The controller on top, as CodeShare's share button finds it, once anything
    /// still going away (the "Export my data first" dialog) has gone: presenting
    /// over a controller being dismissed fails silently. Waits up to two seconds.
    static func presenter() async -> UIViewController? {
        for _ in 0..<40 {
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
                ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
            guard var top = scene?.keyWindow?.rootViewController else { return nil }
            var settling = top.isBeingDismissed || top.isBeingPresented
            while let next = top.presentedViewController {
                if next.isBeingDismissed || next.isBeingPresented { settling = true; break }
                top = next
            }
            if !settling { return top }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }
}

/// The three rows, in CodeShare's order.
struct ExportRows: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: AccountModel
    @ObservedObject var controller: ExportController

    var body: some View {
        ForEach(ExportFormat.allCases) { format in
            Button { Task { await controller.export(format, model: model, account: account) } } label: {
                // A title that wraps (French, German) makes its row taller, not cramped.
                Text(verbatim: format.rowTitle)
                    .foregroundStyle(Theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, Theme.Space.s)
                    .frame(maxWidth: .infinity, minHeight: Theme.Size.minTap, alignment: .leading)
                    .contentShape(Rectangle())
            }
        }
    }
}

enum ExportFormat: String, CaseIterable, Identifiable {
    case pdf, json, csv
    var id: String { rawValue }

    var rowTitle: String {
        switch self {
        case .pdf: String(localized: "Export all my data as PDF", table: "Export", bundle: .appLanguage, locale: .appLanguage)
        case .json: String(localized: "Export all my data as JSON", table: "Export", bundle: .appLanguage, locale: .appLanguage)
        case .csv: String(localized: "Export all my data as CSV", table: "Export", bundle: .appLanguage, locale: .appLanguage)
        }
    }
}

/// Builds the chosen format's file from the local database and, with a ready
/// account, the server's export; offline or failed, from the phone alone.
@MainActor
struct ExportBuilder {
    let model: AppModel
    let account: AccountModel
    var now = Date()

    struct Result {
        let url: URL
        let serverMissing: Bool
    }

    func build(_ format: ExportFormat) async throws -> Result {
        var server: DataExport.Server?
        var serverMissing = false
        do {
            server = try await account.serverExport()
        } catch {
            serverMissing = true
        }
        // An account that is signed out or still without keys cannot be asked either.
        let hasAccount = account.status != .none
        if server == nil && hasAccount { serverMissing = true }
        let snapshot = try model.database.snapshot()
        let known = try model.database.allSessionIDs()
        let local = hasAccount
            ? ExportContent.Local(displayName: account.displayName, username: account.username, email: account.email,
                                  gender: Gender.stored()?.rawValue, friends: (try? model.database.friends()) ?? [])
            : nil
        let now = now
        // Reading is done; building and drawing take a while for years of sessions,
        // so they run off the main actor, on values only.
        let url = try await Task.detached(priority: .userInitiated) {
            try Self.write(format, snapshot: snapshot, server: server, local: local, known: known, now: now)
        }.value
        return Result(url: url, serverMissing: serverMissing)
    }

    nonisolated static func write(_ format: ExportFormat, snapshot: Snapshot, server: DataExport.Server?,
                                  local: ExportContent.Local?, known: Set<UUID>, now: Date) throws -> URL {
        let hasAccount = local != nil
        let identity = BuildIdentity.current
        let data: Data
        let name: String
        switch format {
        case .json:
            data = try DataExport.zip(snapshot: snapshot, server: server, knownSessionIDs: known,
                                      accountWithoutServer: server == nil && hasAccount,
                                      appVersion: identity.version, now: now)
            name = DataExport.fileName(now: now)
        case .csv, .pdf:
            let content = ExportContent.build(snapshot: snapshot, server: server, local: local, knownSessionIDs: known, now: now)
            if format == .pdf {
                data = ExportPDF(content: content, build: "\(identity.version) · \(identity.shortRevision)").data()
                name = DataExport.fileName(now: now, ext: "pdf")
            } else {
                data = CSVExport.zip(content, header: header, aFriend: string("A friend")) { ($0.shownName, $0.shownSecondName) }
                name = DataExport.fileName(now: now, suffix: "-csv")
            }
        }
        return try ExportFile.write(data, name: name)
    }

    nonisolated static func string(_ key: String.LocalizationValue) -> String {
        String(localized: key, table: "Export", bundle: .appLanguage, locale: .appLanguage)
    }

    /// CSV headers in the app's language.
    nonisolated static func header(_ column: CSVExport.Column) -> String {
        let key: String.LocalizationValue = switch column {
        case .practice: "Practice"
        case .secondName: "Second name"
        case .target: "Target"
        case .malaSize: "Mala size"
        case .streakOnly: "Streak only"
        case .archived: "Archived"
        case .dayCounted: "Day counted"
        case .start: "Start"
        case .timeZone: "Time zone"
        case .count: "Count"
        case .round: "Round"
        case .chosenDay: "Day chosen after midnight"
        case .correction: "Correction"
        case .displayName: "Display name"
        case .friendsSince: "Friends since"
        case .code: "Friendship code"
        case .kind: "Made or redeemed"
        case .created: "Created"
        case .expires: "Expires"
        case .revoked: "Revoked"
        case .redemptions: "Redeemed"
        case .person: "Person"
        case .reason: "Reason"
        case .device: "Device"
        case .keyStorage: "Key storage"
        }
        return String(localized: key, table: "Export", bundle: .appLanguage, locale: .appLanguage)
    }
}

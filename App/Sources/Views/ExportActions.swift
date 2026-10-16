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
            Self.present(sheet)
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Over whatever is on screen, as CodeShare's share button does.
    private static func present(_ controller: UIViewController) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
        guard var top = scene?.keyWindow?.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        controller.popoverPresentationController?.sourceView = top.view
        top.present(controller, animated: true)
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
                Text(verbatim: format.rowTitle)
                    .foregroundStyle(Theme.accent)
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
            let local = hasAccount
                ? ExportContent.Local(displayName: account.displayName, username: account.username, email: account.email,
                                      gender: Gender.stored()?.rawValue, friends: (try? model.database.friends()) ?? [])
                : nil
            let content = ExportContent.build(snapshot: snapshot, server: server, local: local, knownSessionIDs: known, now: now)
            if format == .pdf {
                data = ExportPDF(content: content, build: "\(identity.version) · \(identity.shortRevision)").data()
                name = DataExport.fileName(now: now, ext: "pdf")
            } else {
                data = CSVExport.zip(content, header: Self.header) { ($0.shownName, $0.shownSecondName) }
                name = DataExport.fileName(now: now, suffix: "-csv")
            }
        }
        return Result(url: try ExportFile.write(data, name: name), serverMissing: serverMissing)
    }

    /// CSV headers in the app's language.
    static func header(_ column: CSVExport.Column) -> String {
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

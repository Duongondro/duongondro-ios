import SwiftUI
import DuongondroCore
import DuongondroStore

/// Settings › Your data › Export (mockups: Passkeys and export, 15 October; design:
/// Data export and deletion › Export): PDF, CSV or JSON, all built on this phone.
/// The open undo window closes first, so every format holds final sessions only;
/// offline and local mode build from the local database alone. The file then goes
/// to the share sheet.
struct ExportSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: AccountModel
    @Environment(\.dismiss) private var dismiss
    @State private var format: ExportFormat = .pdf
    @State private var exporting = false
    @State private var exported: SharedFile?
    @State private var failure: String?
    /// The last export went out without the server's part.
    @State private var serverMissing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text("Export my data", tableName: "Export")
                    .font(Typography.title)
                    .foregroundStyle(Theme.ink)
                    .padding(.top, Theme.Space.xl)
                VStack(spacing: Theme.Space.s) {
                    ForEach(ExportFormat.allCases) { option in
                        FormatChoice(format: option, selected: option == format) { format = option }
                    }
                }
                .accessibilityElement(children: .contain)
                Text("The file holds your counts unencrypted: they are decrypted on this phone, and the server never sees them. Keep it somewhere private.",
                     tableName: "Export")
                    .font(.subheadline)
                    .foregroundStyle(Theme.soft)
                    .fixedSize(horizontal: false, vertical: true)
                if serverMissing {
                    Text("Your account data could not be fetched from the server, so the export holds only what is on this phone.",
                         tableName: "Export")
                        .font(.footnote)
                        .foregroundStyle(Theme.destructive)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button { Task { await export() } } label: {
                    if exporting { ProgressView().tint(Theme.onAccent) } else { Text("Export", tableName: "Export") }
                }
                .buttonStyle(FilledButtonStyle(height: Theme.Size.secondary))
                .disabled(exporting)
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.bottom, Theme.Space.xl)
        }
        .background(Theme.ground.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(item: $exported) { file in ShareSheet(items: [file.url]) }
        .alert(Text("Export failed", tableName: "Export"),
               isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func export() async {
        exporting = true
        defer { exporting = false }
        // Final sessions only: the open undo window closes first.
        model.finalisePending()
        do {
            let result = try await ExportBuilder(model: model, account: account).build(format)
            serverMissing = result.serverMissing
            exported = SharedFile(url: result.url)
        } catch {
            failure = error.localizedDescription
        }
    }
}

enum ExportFormat: String, CaseIterable, Identifiable {
    case pdf, csv, json
    var id: String { rawValue }

    var title: String { rawValue.uppercased() }

    var detail: String {
        switch self {
        case .pdf: String(localized: "To read or print: every practice and session", table: "Export", bundle: .appLanguage, locale: .appLanguage)
        case .csv: String(localized: "For a spreadsheet: one table per kind of data", table: "Export", bundle: .appLanguage, locale: .appLanguage)
        case .json: String(localized: "Everything, machine-readable", table: "Export", bundle: .appLanguage, locale: .appLanguage)
        }
    }
}

private struct FormatChoice: View {
    let format: ExportFormat
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(verbatim: format.title).font(.headline).foregroundStyle(Theme.ink)
                Text(verbatim: format.detail).font(.subheadline).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: Theme.Size.passkeyBadge * 2 / 3, alignment: .leading)
            .padding(.horizontal, Theme.Space.l)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(selected ? Theme.accent : Theme.inputBorder, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
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

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct SharedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

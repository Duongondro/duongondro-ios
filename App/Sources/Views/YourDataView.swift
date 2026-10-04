import SwiftUI
import DuongondroStore

/// Settings › Your data: a full export and a full purge, both self-service
/// (GDPR Articles 15, 17 and 20). Nobody has to email a human.
struct YourDataView: View {
    @EnvironmentObject private var model: AppModel
    @State private var exported: ExportedFile?
    @State private var exportError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                CardSection(footer: "One ZIP with every practice, session and streak, readable without this app.") {
                    Button { export() } label: {
                        Label("Export all my data", systemImage: "square.and.arrow.up")
                            .foregroundStyle(Theme.accent)
                            .frame(maxWidth: .infinity, minHeight: Theme.Size.minTap, alignment: .leading)
                    }
                }
                CardSection(footer: "Removes all your data from this phone. It cannot be undone.") {
                    NavigationLink { DeleteEverythingView() } label: {
                        HStack {
                            Label("Delete everything", systemImage: "trash").foregroundStyle(Theme.destructive)
                            Spacer(minLength: Theme.Space.s)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(Theme.muted)
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: Theme.Size.minTap)
                        .contentShape(Rectangle())
                    }
                }
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.top, Theme.Space.l)
        }
        .buttonStyle(.plain)
        .background(Theme.ground.ignoresSafeArea())
        .navigationTitle("Your data")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $exported) { file in ShareSheet(items: [file.url]) }
        .alert("Export failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    private func export() {
        // Anything still in the undo window belongs in the export. The published
        // snapshot updates asynchronously, so read the database directly.
        model.commitPending()
        do {
            // Local mode: no account, so no server half (GET /api/me/export arrives with phase 3).
            let zip = try DataExport.zip(snapshot: try model.database.snapshot(), server: nil, covers: Covers.all(),
                                         appVersion: BuildIdentity.current.version)
            exported = ExportedFile(url: try ExportFile.write(zip, name: DataExport.fileName()))
        } catch {
            exportError = error.localizedDescription
        }
    }
}

/// Typed confirmation, then the purge, then Welcome.
private struct DeleteEverythingView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: AccountModel
    @State private var typed = ""
    @State private var failure: String?
    private let word = String(localized: "delete", comment: "The word typed to confirm deleting everything; lowercase")

    var body: some View {
        let confirmed = typed.trimmingCharacters(in: .whitespaces).lowercased() == word.lowercased()
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                CardSection {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text("This deletes every practice, session and streak on this phone, your reminders and any keys the app holds, then returns to the start.")
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Export first if you want a copy.")
                            .foregroundStyle(Theme.muted)
                    }
                    .padding(.vertical, Theme.Space.m)
                }
                CardSection(header: "Type \u{201C}\(word)\u{201D} to confirm") {
                    TextField(word, text: $typed)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .frame(minHeight: Theme.Size.minTap)
                }
                Button("Delete everything") {
                    Task {
                        do {
                            try await account.deleteOnServer()
                            try Purge.run(model)
                            account.forget()
                        } catch {
                            failure = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(FilledButtonStyle(fill: Theme.destructive, height: Theme.Size.button))
                .disabled(!confirmed)
                .opacity(confirmed ? 1 : 0.4)
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.top, Theme.Space.l)
        }
        .background(Theme.ground.ignoresSafeArea())
        .navigationTitle("Delete everything")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Could not delete", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct ExportedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

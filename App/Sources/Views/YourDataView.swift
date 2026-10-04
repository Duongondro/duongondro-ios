import SwiftUI
import DuongondroStore

/// Settings › Your data: a full export and a full purge, both self-service
/// (GDPR Articles 15, 17 and 20). Nobody has to email a human.
struct YourDataView: View {
    @EnvironmentObject private var model: AppModel
    @State private var exported: ExportedFile?
    @State private var exportError: String?

    var body: some View {
        List {
            Group {
                Section {
                    Button { export() } label: { Label("Export all my data", systemImage: "square.and.arrow.up") }
                } footer: {
                    Text("One ZIP with every practice, session and streak, readable without this app.")
                }
                Section {
                    NavigationLink { DeleteEverythingView() } label: {
                        Label("Delete everything", systemImage: "trash").foregroundStyle(.red)
                    }
                } footer: {
                    Text("Removes all your data from this phone. It cannot be undone.")
                }
            }
            .themedRows()
        }
        .themedList()
        .navigationTitle("Your data")
        .sheet(item: $exported) { file in ShareSheet(items: [file.url]) }
        .alert("Export failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    private func export() {
        // Anything still in the undo window belongs in the export.
        model.commitPending()
        do {
            // Local mode: no account, so no server half (GET /api/me/export arrives with phase 3).
            let zip = try DataExport.zip(snapshot: model.snapshot, server: nil, covers: Covers.all(),
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
    @State private var typed = ""
    @State private var failure: String?
    private let word = String(localized: "delete", comment: "The word typed to confirm deleting everything; lowercase")

    var body: some View {
        Form {
            Group {
                Section {
                    Text("This deletes every practice, session and streak on this phone, your reminders and any keys the app holds, then returns to the start.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Export first if you want a copy.")
                        .foregroundStyle(Theme.muted)
                }
                Section {
                    TextField(word, text: $typed)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Type \u{201C}\(word)\u{201D} to confirm")
                }
                Section {
                    Button("Delete everything", role: .destructive) {
                        do { try Purge.run(model) } catch { failure = error.localizedDescription }
                    }
                    .disabled(typed.trimmingCharacters(in: .whitespaces).lowercased() != word.lowercased())
                }
            }
            .themedRows()
        }
        .themedList()
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

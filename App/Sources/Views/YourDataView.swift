import SwiftUI
import DuongondroStore

/// Settings › Your data: a full export and a full purge, both self-service
/// (GDPR Articles 15, 17 and 20). Nobody has to email a human.
struct YourDataView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: AccountModel
    @State private var exporting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                CardSection {
                    Button { exporting = true } label: {
                        Label("Export all my data", systemImage: "square.and.arrow.up")
                            .foregroundStyle(Theme.accent)
                            .frame(maxWidth: .infinity, minHeight: Theme.Size.minTap, alignment: .leading)
                    }
                }
                Text("A PDF to read or print, tables for a spreadsheet, or everything as JSON, readable without this app.", tableName: "Export")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.top, -Theme.Space.s)
                    .fixedSize(horizontal: false, vertical: true)
                // With an account, the server and the person's other phones lose it too.
                CardSection(footer: account.status == .none
                            ? LocalizedStringKey("Removes all your data from this phone. It cannot be undone.")
                            : LocalizedStringKey("Deletes your account and its data on the server, and everything on this phone. Your other phones are signed out but keep their copy. It cannot be undone.")) {
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
        .sheet(isPresented: $exporting) { ExportSheet() }
    }
}

/// Typed confirmation, then the purge, then Welcome.
private struct DeleteEverythingView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: AccountModel
    @State private var typed = ""
    @State private var failure: String?
    @State private var running = false
    /// Set once the server confirmed: a retry after a failed local wipe skips it
    /// (the session is gone with the account, so a second delete would fail).
    @State private var serverDeleted = false
    private let word = String(localized: "delete", bundle: .appLanguage, locale: .appLanguage, comment: "The word typed to confirm deleting everything; lowercase")

    var body: some View {
        let confirmed = typed.trimmingCharacters(in: .whitespaces).lowercased() == word.lowercased()
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                CardSection {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text(account.status == .none
                             ? LocalizedStringKey("This deletes every practice, session and streak on this phone, your reminders and any keys the app holds, then returns to the start.")
                             : LocalizedStringKey("This deletes your account and everything stored with it on the server: your encrypted sessions, friends, public streaks, friendship codes, passkeys and sign-ins. Your other phones are signed out and keep their own copy until you delete it there. On this phone it deletes every practice, session and streak, your reminders and the app's keys, then returns to the start."))
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
                    running = true
                    Task {
                        defer { running = false }
                        do {
                            if !serverDeleted {
                                try await account.deleteOnServer()
                                serverDeleted = true
                            }
                            try Purge.run(model)
                            account.forget()
                        } catch {
                            failure = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(FilledButtonStyle(fill: Theme.destructive, height: Theme.Size.button))
                .disabled(!confirmed || running)
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

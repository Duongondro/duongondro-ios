import SwiftUI
import DuongondroSync

/// One friend: their public streaks, whether you hear when they practise, and
/// unfriend, block and report (design: Social › Moderation; the release
/// checklist requires report and block).
struct FriendDetailView: View {
    @EnvironmentObject private var account: AccountModel
    @Environment(\.dismiss) private var dismiss
    let friendID: UUID
    @State private var confirmingUnfriend = false
    @State private var confirmingBlock = false
    @State private var reporting = false
    @State private var reason = ""
    @State private var reported = false

    var body: some View {
        if let f = account.friends.first(where: { $0.userID == friendID }) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    if f.keyChanged {
                        CardSection(footer: "The server now names a different key for this friend than the one this phone first saw, so their streaks are hidden. It may be a new phone without a restore, or someone in between. Meet them, or ask for a new invite: accepting it checks their key again.") {
                            Label("Their key changed", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.destructive)
                                .frame(minHeight: Theme.Size.minTap)
                        }
                    } else {
                        CardSection(header: "Public streaks", footer: "Days practised in the app, signed by them. Counts stay private.") {
                            if f.streaks.isEmpty {
                                SettingsRow("None shared yet")
                            }
                            ForEach(f.streaks, id: \.practice) { s in
                                SettingsRow(LocalizedStringKey(FriendsView.practiceName(s.practice)),
                                            detail: Text("\(s.deadline > Date() ? s.current : 0) days · longest \(s.longest)"))
                            }
                        }
                    }
                    CardSection(header: "Notifications") {
                        Toggle(isOn: Binding(get: { f.notifyDone },
                                             set: { on in Task { await account.setNotifyDone(on, for: f.userID) } })) {
                            Text("Tell me when they practise").foregroundStyle(Theme.ink)
                        }
                        .tint(Theme.accent)
                        .frame(minHeight: Theme.Size.minTap)
                    }
                    CardSection(footer: reported ? "Reported. Thank you." : nil) {
                        Button { confirmingUnfriend = true } label: { SettingsRow("Unfriend") }
                        Button { reporting = true } label: { SettingsRow("Report") }
                        Button { confirmingBlock = true } label: {
                            Text("Block").foregroundStyle(Theme.destructive)
                                .frame(maxWidth: .infinity, minHeight: Theme.Size.minTap, alignment: .leading)
                        }
                    }
                    if let error = account.error {
                        Text(verbatim: error).font(.footnote).foregroundStyle(Theme.destructive)
                            .padding(.horizontal, Theme.Space.l)
                    }
                }
                .padding(.horizontal, Theme.Space.xl)
                .padding(.vertical, Theme.Space.l)
            }
            .buttonStyle(.plain)
            .background(Theme.ground.ignoresSafeArea())
            .navigationTitle(Text(verbatim: f.displayName.isEmpty ? String(localized: "A friend") : f.displayName))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .confirmationDialog("Unfriend?", isPresented: $confirmingUnfriend, titleVisibility: .visible) {
                Button("Unfriend", role: .destructive) { Task { await account.unfriend(f.userID); dismiss() } }
            } message: {
                Text("You stop seeing each other's streaks. An invite can make you friends again.")
            }
            .confirmationDialog("Block?", isPresented: $confirmingBlock, titleVisibility: .visible) {
                Button("Block", role: .destructive) { Task { await account.block(f.userID); dismiss() } }
            } message: {
                Text("Ends the friendship both ways and stops invites and nudges between you.")
            }
            .alert("Report", isPresented: $reporting) {
                TextField("What happened?", text: $reason)
                Button("Send") {
                    Task {
                        await account.report(f.userID, reason: reason)
                        reported = account.error == nil
                        reason = ""
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Reports go to the people who run Duongöndro.")
            }
        }
    }
}

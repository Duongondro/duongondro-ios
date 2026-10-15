import SwiftUI
import DuongondroSync

/// One friend: their public streaks, whether you hear when they practise, and
/// unfriend, block and report (design: Social › Moderation; the release
/// checklist requires report and block).
struct FriendDetailView: View {
    @EnvironmentObject private var account: AccountModel
    @EnvironmentObject private var push: PushModel
    @Environment(\.openURL) private var openURL
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
                        CardSection(footer: "The server now names a different key for this friend than the one this phone first saw, so their streaks are hidden. It may be a new phone without a restore, or someone in between. Meet them, or ask for a new friendship code: accepting it checks their key again.") {
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
                    CardSection(header: "Notifications",
                                footer: f.notifyDone && push.authorization == .denied
                                    ? "Notifications are off for Duongöndro. Turn them on in Settings." : nil) {
                        Toggle(isOn: Binding(get: { f.notifyDone },
                                             set: { on in
                                                 Task {
                                                     await account.setNotifyDone(on, for: f.userID)
                                                     // The reason to ask is this switch.
                                                     if on { await push.ask() }
                                                 }
                                             })) {
                            Text("Tell me when they practise").foregroundStyle(Theme.ink)
                        }
                        .tint(Theme.accent)
                        .frame(minHeight: Theme.Size.minTap)
                        if f.notifyDone && push.authorization == .denied {
                            Button {
                                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                            } label: { AccentRow(title: "Open Settings", chevron: true) }
                        }
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
            .navigationTitle(Text(verbatim: f.displayName.isEmpty ? String(localized: "A friend", bundle: .appLanguage, locale: .appLanguage) : f.displayName))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .confirmationDialog("Unfriend?", isPresented: $confirmingUnfriend, titleVisibility: .visible) {
                Button("Unfriend", role: .destructive) { Task { await account.unfriend(f.userID); dismiss() } }
            } message: {
                Text("You stop seeing each other's streaks. A friendship code can make you friends again.")
            }
            .confirmationDialog("Block?", isPresented: $confirmingBlock, titleVisibility: .visible) {
                Button("Block", role: .destructive) { Task { await account.block(f.userID); dismiss() } }
            } message: {
                Text("Ends the friendship both ways and stops friendship codes and nudges between you.")
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
        } else {
            // Opened from a push before the list knew this friend, or after they left.
            MissingFriend()
        }
    }
}

/// A friend not in the list: the list is fetched again, then either the page
/// appears or this says why it cannot.
private struct MissingFriend: View {
    @EnvironmentObject private var account: AccountModel
    @State private var checked = false

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            if checked {
                Text("You are not friends any more.")
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
            } else {
                ProgressView()
            }
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task {
            await account.refreshFriends()
            checked = true
        }
    }
}

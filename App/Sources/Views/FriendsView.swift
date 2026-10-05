import SwiftUI
import DuongondroCore
import DuongondroSync

/// The mockup's Friends tab: today's news from friends' public streaks, the
/// leaderboard of tracked days, and the invite card.
struct FriendsView: View {
    @EnvironmentObject private var account: AccountModel
    @State private var inviting = false
    @State private var pasting = false
    @State private var pasted: InviteLink?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                Text("Friends")
                    .font(Typography.largeTitle)
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, Theme.Space.xs)
                    .accessibilityAddTraits(.isHeader)
                if account.status != .ready {
                    CardSection(footer: "Friends see your public streaks and nothing else. Set up your account under You to invite them.") {
                        SettingsRow("No account on this phone yet")
                    }
                } else {
                    if !news.isEmpty {
                        CardSection(header: "Today") {
                            ForEach(news, id: \.friend.userID) { item in NewsRow(item: item) }
                        }
                    }
                    if !leaders.isEmpty {
                        CardSection(header: "Leaderboard · tracked in the app") {
                            ForEach(leaders, id: \.key) { row in
                                HStack(spacing: Theme.Space.m) {
                                    Text(verbatim: "\(row.name) · \(Self.practiceName(row.practice))")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Theme.ink)
                                    Spacer(minLength: Theme.Space.s)
                                    Label {
                                        Text(verbatim: "\(row.current)").font(.subheadline.weight(.bold)).foregroundStyle(Theme.ink)
                                    } icon: {
                                        Image(systemName: "flame.fill").foregroundStyle(Theme.flame)
                                    }
                                    .labelStyle(.titleAndIcon)
                                }
                                .frame(minHeight: Theme.Size.minTap)
                            }
                        }
                    }
                    if account.friendsLoaded && account.friends.isEmpty {
                        Text("No friends yet. An invite makes the two of you friends; they see your public streaks, never your counts.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.muted)
                            .padding(.horizontal, Theme.Space.l)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !account.friends.isEmpty {
                        CardSection(header: "Your friends") {
                            ForEach(account.friends) { f in
                                NavigationLink { FriendDetailView(friendID: f.userID) } label: {
                                    HStack(spacing: Theme.Space.m) {
                                        Text(verbatim: f.displayName.isEmpty ? String(localized: "A friend", bundle: .appLanguage, locale: .appLanguage) : f.displayName)
                                            .foregroundStyle(Theme.ink)
                                        Spacer(minLength: Theme.Space.s)
                                        if f.keyChanged {
                                            Label("Key changed", systemImage: "exclamationmark.triangle.fill")
                                                .font(.footnote.weight(.semibold))
                                                .foregroundStyle(Theme.destructive)
                                        }
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
                    }
                    InviteCard { inviting = true }
                    Button("Paste an invite link") { pasting = true }
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, minHeight: Theme.Size.minTap)
                }
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.bottom, Theme.Space.xl)
        }
        .buttonStyle(.plain)
        .background(Theme.ground.ignoresSafeArea())
        .statusBarScrim()
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await account.refreshFriends() }
        .task { await account.refreshFriends() }
        .navigationDestination(isPresented: $inviting) { InviteView() }
        // The accept sheet opens only once this one has gone: UIKit refuses to
        // present while another sheet is still dismissing.
        .sheet(isPresented: $pasting, onDismiss: {
            if let pasted { account.pendingInvite = pasted }
            pasted = nil
        }) { PasteInviteView(pasted: $pasted) }
    }

    struct NewsItem {
        let friend: Social.FriendView
        let streak: Social.FriendStreak
        let doneToday: Bool
    }

    /// One line per friend: the practice they did today, or the streak that is
    /// still waiting for today, whichever is newest.
    private var news: [NewsItem] { Self.news(account.friends) }

    static func news(_ friends: [Social.FriendView], now: Date = Date()) -> [NewsItem] {
        // Decided from the signed deadline, not the day: the friend's day is in
        // their own zone. The deadline is midnight after the day following the
        // last practice day, so more than a day left means they practised on
        // their own today; less means today is still open.
        friends.filter { !$0.keyChanged }.compactMap { f -> NewsItem? in
            let live = f.streaks.filter { $0.current > 0 && $0.deadline > now }
            if let done = live.filter({ $0.deadline.timeIntervalSince(now) > 86400 }).max(by: { $0.seq < $1.seq }) {
                return NewsItem(friend: f, streak: done, doneToday: true)
            }
            if let waiting = live.max(by: { $0.current < $1.current }) {
                return NewsItem(friend: f, streak: waiting, doneToday: false)
            }
            return nil
        }
        .sorted { ($0.doneToday ? 0 : 1, -$0.streak.seq) < ($1.doneToday ? 0 : 1, -$1.streak.seq) }
    }

    private var leaders: [(key: String, name: String, practice: String, current: Int)] {
        account.friends.filter { !$0.keyChanged }.flatMap { f in
            f.streaks.filter { $0.current > 0 && $0.deadline > Date() }.map {
                (key: "\(f.userID)-\($0.practice)", name: f.displayName, practice: $0.practice, current: $0.current)
            }
        }
        .sorted { $0.current > $1.current }
    }

    static func practiceName(_ id: String) -> String {
        Catalogue.builtIn.first { $0.id == id }?.shownName ?? String(localized: "their own practice", bundle: .appLanguage, locale: .appLanguage)
    }
}

struct NewsRow: View {
    @EnvironmentObject private var account: AccountModel
    let item: FriendsView.NewsItem

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Initial(name: item.friend.displayName)
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.s)
            if !item.doneToday {
                let poked = account.isPoked(item.friend.userID)
                Button(poked ? "Poked" : "Poke") { Task { await account.poke(item.friend.userID) } }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(poked ? Theme.muted : Theme.onAccent)
                    .padding(.horizontal, Theme.Space.l)
                    .frame(minHeight: Theme.Size.minTap)
                    .accessibilityLabel(poked ? Text("Poked \(name)") : Text("Poke \(name)"))
                    .background(poked ? Theme.softFill : Theme.accent, in: Capsule())
                    .disabled(poked)
            }
        }
        .padding(.vertical, Theme.Space.m)
    }

    private var practice: String { FriendsView.practiceName(item.streak.practice) }
    private var name: String { item.friend.displayName.isEmpty ? String(localized: "A friend", bundle: .appLanguage, locale: .appLanguage) : item.friend.displayName }

    private var title: String {
        item.doneToday ? Gendered.string("%@ finished %@", for: item.friend.gender, name, practice)
            : Gendered.string("%@ hasn't practised yet", for: item.friend.gender, name)
    }

    private var detail: String {
        if item.doneToday {
            // Streak statements from this app carry their sending time as seq.
            let sent = Date(timeIntervalSince1970: Double(item.streak.seq) / 1000)
            let when = sent <= Date() && sent > Date().addingTimeInterval(-86400)
                ? " · " + sent.formatted(Date.RelativeFormatStyle(presentation: .named, locale: .appLanguage)) : ""
            return String(localized: "Day \(item.streak.current)", bundle: .appLanguage, locale: .appLanguage) + when
        }
        // The deadline in this phone's clock: "at midnight" only when it is this
        // phone's midnight too.
        let deadline = item.streak.deadline
        let parts = Calendar.current.dateComponents([.hour, .minute], from: deadline)
        let ends = parts.hour == 0 && parts.minute == 0 && deadline.timeIntervalSinceNow <= 86400
            ? String(localized: "ends at midnight", bundle: .appLanguage, locale: .appLanguage)
            : String(localized: "ends \(deadline.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(.appLanguage)))", bundle: .appLanguage, locale: .appLanguage)
        return String(localized: "\(practice) streak: \(item.streak.current) days, \(ends)", bundle: .appLanguage, locale: .appLanguage)
    }
}

/// A friend's initial on a soft disc, as in the mockup.
struct Initial: View {
    let name: String

    var body: some View {
        Text(verbatim: name.first.map { String($0).uppercased() } ?? "·")
            .font(.headline)
            .foregroundStyle(Theme.accent)
            .frame(width: Theme.Size.minTap, height: Theme.Size.minTap)
            .background(Theme.track, in: Circle())
            .accessibilityHidden(true)
    }
}

private struct InviteCard: View {
    let invite: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text("Invite a friend").font(.body.weight(.bold)).foregroundStyle(Theme.ink)
                Text("Link or QR code, valid 7 days").font(.footnote).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: Theme.Space.s)
            Button("Invite", action: invite)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, Theme.Space.l + Theme.Space.xs)
                .frame(minHeight: Theme.Size.minTap)
                .background(Theme.card, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.accent, lineWidth: 2))
        }
        .padding(Theme.Space.l)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .strokeBorder(Theme.inputBorder, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
    }
}

/// "Paste invite": the first-install path, when the App Store ate the link.
private struct PasteInviteView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var pasted: InviteLink?
    @State private var text = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                Text("Paste the link your friend sent.")
                    .foregroundStyle(Theme.soft)
                // The system paste button reads the clipboard without the paste prompt.
                PasteButton(payloadType: String.self) { strings in
                    if let first = strings.first { text = first }
                }
                .tint(Theme.accent)
                TextField(text: $text, axis: .vertical) { Text(verbatim: "https://duongondro.app/I/…") }
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(Theme.Space.m)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.inputBorder))
                Spacer(minLength: 0)
                Button("Continue") {
                    pasted = InviteLink(text)
                    dismiss()
                }
                .buttonStyle(FilledButtonStyle())
                .disabled(InviteLink(text) == nil)
                .opacity(InviteLink(text) == nil ? 0.4 : 1)
            }
            .padding(Theme.Space.xl)
            .background(Theme.ground.ignoresSafeArea())
            .navigationTitle("Paste invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

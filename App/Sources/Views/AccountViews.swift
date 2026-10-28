import SwiftUI
import DuongondroAPI
import DuongondroSync

/// Settings' account rows, as Android's AccountSection: who is signed in, the
/// name friends see, the username, the recovery code's state, sync, a passkey,
/// and signing out on this phone. Without an account, the two ways to get one;
/// signed out by the server, the way back. Inviting is for accounts with keys
/// only: an invitation is signed by the account's identity key.
struct AccountSection: View {
    @EnvironmentObject private var account: AccountModel
    @State private var restoring = false
    @State private var naming = false
    @State private var replacingCode = false
    @State private var signingOut = false
    @State private var editingUsername = false
    @State private var name = ""
    @State private var usernameText = ""
    @State private var note: String?
    @State private var finishing = false

    var body: some View {
        Group { rows }
            // Outside the switch: the status changes while a restore runs, and a
            // sheet hung on one branch would vanish with it.
            .sheet(isPresented: $restoring) { RestoreView() }
    }

    @ViewBuilder private var rows: some View {
        switch account.status {
        case .none:
            CardSection(header: "Account", footer: "Only on this phone. An account adds friends, public streaks and sync between phones; your counts stay end-to-end encrypted.") {
                AccountDoorRows()
                #if DEBUG
                Button { Task { await account.signInForDevelopment() } } label: {
                    SettingsRow("Sign in for development", chevron: true)
                }
                #endif
            }
        case .signedOut:
            CardSection(header: "Account", footer: "Signed out. Sign in again to keep syncing.") {
                AccountDoorRows()
            }
        case .needsKeys where account.busy:
            CardSection(header: "Account") {
                HStack(spacing: Theme.Space.s) {
                    ProgressView()
                    Text("Making your keys…").foregroundStyle(Theme.muted)
                }
                .frame(minHeight: Theme.Size.minTap)
            }
        case .needsKeys:
            // No sign-out here: the keys could not come back without a recovery code.
            CardSection(header: "Account", footer: "Your counts are encrypted on this phone before they leave it. Set up keys on your first phone; on a new one, restore them with your recovery code.") {
                Button { finishSetUp() } label: { AccentRow(title: "Finish setting up") }
                    .disabled(finishing)
            }
        case .ready:
            if account.offersPasskeyUnlock || account.offersNewPasskey { PasskeyUnlockCard() }
            CardSection(header: "Account", footer: account.offline ? "The last sync did not finish. Your counts are safe on this phone and sync when the server can be reached." : nil) {
                if let who = account.email ?? account.username {
                    SettingsRow("Signed in as", detail: Text(verbatim: who))
                }
                NavigationLink { InviteView() } label: { AccentRow(title: "Share a friendship code", chevron: true) }
                Button { naming = true } label: {
                    SettingsRow("Your name", detail: account.displayName.isEmpty ? Text("None") : Text(verbatim: account.displayName), chevron: true)
                }
                Button { editingUsername = true } label: {
                    SettingsRow("Username", detail: account.username.map { Text(verbatim: $0) } ?? Text("None"), chevron: true)
                }
                Button { replacingCode = true } label: {
                    SettingsRow("Recovery code",
                                detail: account.recoveryCodeMissing ? Text("Not confirmed") : Text("Make a new one"),
                                detailColor: account.recoveryCodeMissing ? Theme.destructive : Theme.muted,
                                chevron: true)
                }
                .disabled(account.busy)
                // On the row, so the dialog (a popover on newer systems) points at it.
                // A code left unconfirmed this launch is offered again before a new one.
                .confirmationDialog(keptCode ? Text("Recovery code") : Text("Make a new recovery code?"),
                                    isPresented: $replacingCode, titleVisibility: .visible) {
                    if keptCode {
                        Button("Show the code again") { account.showRecoveryCodeAgain() }
                    }
                    Button("Make a new code") { Task { await account.newRecoveryCode() } }
                } message: {
                    // A code left with "Not now" was never written down.
                    if !keptCode { Text(verbatim: Gendered.mine("The code you wrote down stops working.")) }
                }
                Button { Task { await account.syncNow() } } label: {
                    SettingsRow("Sync", detail: syncDetail)
                }
                NavigationLink { PasskeysView() } label: { SettingsRow("Passkeys", chevron: true) }
                if account.canSignOut {
                    Button { signingOut = true } label: {
                        Text("Sign out on this phone")
                            .foregroundStyle(Theme.destructive)
                            .padding(.vertical, Theme.Space.s)
                            .frame(maxWidth: .infinity, minHeight: Theme.Size.minTap, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .confirmationDialog("Sign out on this phone?", isPresented: $signingOut, titleVisibility: .visible) {
                        Button("Sign out on this phone", role: .destructive) { Task { await account.signOut() } }
                    } message: {
                        if account.passkeys.contains(where: \.canUnlock) {
                            Text("Your counts stay on this phone but stop syncing. To sync them again, sign in with your passkey.")
                        } else {
                            Text("Your counts stay on this phone but stop syncing. To sync them again, sign in and enter your recovery code.")
                        }
                    }
                } else {
                    // Signing out forgets the keys: with no passkey to unlock them, first the
                    // recovery code must be stored and confirmed.
                    Button { replacingCode = true } label: {
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            Text("Sign out on this phone").foregroundStyle(Theme.muted)
                            Text("Before signing out here, finish your recovery code: without it, your counts could not come back.")
                                .font(.footnote)
                                .foregroundStyle(Theme.accent)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, Theme.Space.s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                }
            }
            .alert("Your name", isPresented: $naming) {
                TextField("Name", text: $name)
                Button("Save") { Task { await account.setDisplayName(name) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Friends see this name next to your streaks.")
            }
            .alert("Username", isPresented: $editingUsername) {
                TextField("Username", text: $usernameText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save") { saveUsername() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Letters, digits, dots and underscores. Friends don't see it.")
            }
            .onChange(of: naming) { open in if open { name = account.displayName } }
            .onChange(of: editingUsername) { open in if open { usernameText = account.username ?? "" } }
            .task { await account.refreshFriends() }
        }
        if let message = note ?? account.error {
            Text(verbatim: message)
                .font(.footnote)
                .foregroundStyle(note != nil && account.error == nil ? Theme.muted : Theme.destructive)
                .padding(.horizontal, Theme.Space.l)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The code made this launch and not confirmed yet, which Settings can show again.
    private var keptCode: Bool { account.codeToShowAgain != nil }

    /// An unfinished account: set up here, or restore keys made on another phone.
    private func finishSetUp() {
        // A second tap while the first runs does nothing; the key work itself is
        // serialised in AccountModel too.
        guard !finishing else { return }
        finishing = true
        Task {
            defer { finishing = false }
            do {
                switch try await account.standing() {
                case .restore: restoring = true
                case .setUp: await account.setUp()
                case .ready: break
                }
            } catch {
                note = accountError
            }
        }
    }

    private func saveUsername() {
        let cleaned = String(usernameText.lowercased().filter { c in
            (c.isASCII && (c.isLetter || c.isNumber)) || c == "." || c == "_"
        }.prefix(UsernameRule.maxLength))
        note = nil
        guard cleaned.isEmpty || cleaned.count >= UsernameRule.minLength else {
            note = localized("A username has 3 to 32 letters, digits, dots and underscores.")
            return
        }
        Task {
            if !(await account.setUsername(cleaned.isEmpty ? nil : cleaned)) {
                note = localized("That username is taken. Try another.")
            }
        }
    }

    private var syncDetail: Text {
        if account.syncing { return Text("Syncing…") }
        if let last = account.lastSync { return Text(last.formatted(Date.RelativeFormatStyle(presentation: .named, locale: .appLanguage))) }
        return Text("Not yet")
    }
}

/// A row whose title is the section's main action, in the accent colour.
struct AccentRow: View {
    let title: LocalizedStringKey
    var chevron = false

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Text(title).font(.body.weight(.semibold)).foregroundStyle(Theme.accent)
            Spacer(minLength: Theme.Space.s)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Theme.muted)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, Theme.Space.s)
        .frame(minHeight: Theme.Size.minTap)
        .contentShape(Rectangle())
    }
}

/// The ways to an account from local mode, or back after the server signed this
/// phone out; they open the account steps over the app.
struct AccountDoorRows: View {
    @EnvironmentObject private var account: AccountModel

    var body: some View {
        if account.status == .signedOut {
            Button { account.accountFlow = .signIn } label: { AccentRow(title: "Sign in again") }
        } else {
            Button { account.accountFlow = .newAccount } label: { AccentRow(title: "Make an online account") }
            Button { account.accountFlow = .signIn } label: { SettingsRow("I already have an account", chevron: true) }
        }
    }
}

/// The recovery code (mockup: Recovery). The code is Crockford base32 in
/// groups of four, numbered like the mockup's words; "I wrote it down" asks for
/// two groups back before it goes away, "Not now" leaves it unconfirmed.
struct RecoveryCodeView: View {
    @EnvironmentObject private var account: AccountModel
    let code: String
    @State private var checking = false

    private var groups: [String] { RecoveryCode.groups(code) }

    var body: some View {
        if checking {
            RecoveryCheckView(groups: groups) { account.confirmRecoveryCode() } back: { checking = false }
        } else {
            // Scrolls only when it does not fit (large Dynamic Type), so "Not now"
            // stays reachable with the swipe-down disabled; otherwise the buttons
            // sit at the bottom as before.
            ViewThatFits(in: .vertical) {
                page
                ScrollView { page }
            }
            .background(Theme.ground.ignoresSafeArea())
            .interactiveDismissDisabled()
        }
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text("Write down your recovery code")
                .font(Typography.headingBold(30, relativeTo: .largeTitle))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("If you lose this phone, this code is the only way back to your counts. Nobody else has it, not even us.")
                .foregroundStyle(Theme.soft)
                .fixedSize(horizontal: false, vertical: true)
            CodeGrid(groups: groups)
            Text("Next we'll ask for two of these groups, to make sure.")
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
            Spacer(minLength: 0)
            Button(Gendered.mine("I wrote it down")) { checking = true }
                .buttonStyle(FilledButtonStyle())
            // Leaves it unconfirmed: Settings shows the same code again, and
            // signing out waits for it. Never by a swipe, only on purpose.
            Button("Not now") { account.leaveRecoveryCode() }
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity, minHeight: Theme.Size.aboutButton)
        }
        .padding(.horizontal, Theme.Space.xl + Theme.Space.xs)
        .padding(.top, Theme.Space.xl)
        .padding(.bottom, Theme.Space.xxl)
    }
}

/// Numbered groups in two columns, read down the first column, then the second.
struct CodeGrid: View {
    let groups: [String]

    var body: some View {
        let half = (groups.count + 1) / 2
        HStack(alignment: .top, spacing: Theme.Space.l) {
            column(0..<half)
            column(half..<groups.count)
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func column(_ range: Range<Int>) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            ForEach(range, id: \.self) { i in
                HStack(spacing: Theme.Space.s) {
                    Text(verbatim: "\(i + 1)").foregroundStyle(Theme.muted)
                    Text(verbatim: groups[i]).foregroundStyle(Theme.ink)
                }
                .font(.body.monospaced())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Asks for two groups of the code, picked at random, before letting it go.
/// `framed` for a screen of its own; inside the onboarding the steps' frame is used.
struct RecoveryCheckView: View {
    let groups: [String]
    var framed = true
    let done: () -> Void
    let back: () -> Void
    @State private var asked: [Int] = []
    @State private var answers = ["", ""]
    @State private var wrong = false
    @FocusState private var focus: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text("Check your recovery code")
                .font(Typography.headingBold(30, relativeTo: .largeTitle))
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(asked.enumerated()), id: \.offset) { n, i in
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("Group \(i + 1)").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.soft)
                    TextField("", text: $answers[n])
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($focus, equals: n)
                        // VoiceOver reads which group the field wants, as the label above says.
                        .accessibilityLabel(Text("Group \(i + 1)"))
                        .submitLabel(n + 1 < asked.count ? .next : .done)
                        .onSubmit { focus = n + 1 < asked.count ? n + 1 : nil }
                        .padding(.horizontal, Theme.Space.m)
                        .frame(height: Theme.Size.field)
                        // The whole box takes the tap, not only the line of text in
                        // it: a tap above or below that line used to leave the
                        // previous field focused, so the second group went there.
                        // The tap is caught behind the field, so the field's own
                        // caret placement and paste menu are untouched.
                        .background(FieldBox { focus = n })
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                            .strokeBorder(Theme.inputBorder)
                            .allowsHitTesting(false))
                }
            }
            if wrong {
                Text("That does not match. Look at the code again.")
                    .font(.footnote)
                    .foregroundStyle(Theme.destructive)
            }
            Spacer(minLength: 0)
            Button("Done") {
                if RecoveryCode.answersMatch(answers, groups: groups, asked: asked) { done() } else { wrong = true }
            }
            .buttonStyle(FilledButtonStyle())
            Button("Show the code again", action: back)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity, minHeight: Theme.Size.aboutButton)
        }
        .padding(.horizontal, framed ? Theme.Space.xl + Theme.Space.xs : 0)
        .padding(.top, Theme.Space.xl)
        .padding(.bottom, framed ? Theme.Space.xxl : Theme.Space.xl)
        .background(Theme.ground.ignoresSafeArea())
        .interactiveDismissDisabled()
        .onAppear {
            if asked.isEmpty { asked = Array(groups.indices.shuffled().prefix(2)).sorted() }
        }
    }
}

/// A new phone: type the recovery code to bring the keys back.
struct RestoreView: View {
    @EnvironmentObject private var account: AccountModel
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text("Restore with your recovery code")
                .font(Typography.headingBold(30, relativeTo: .largeTitle))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: Gendered.mine("The code you wrote down when you set up your first phone. Spaces and dashes do not matter."))
                .foregroundStyle(Theme.soft)
                .fixedSize(horizontal: false, vertical: true)
            TextField("", text: $code, axis: .vertical)
                .font(.body.monospaced())
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .padding(Theme.Space.m)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.inputBorder))
            if let error = account.error {
                Text(verbatim: error).font(.footnote).foregroundStyle(Theme.destructive)
            }
            Spacer(minLength: 0)
            Button {
                working = true
                Task {
                    if await account.restore(code: code) { dismiss() }
                    working = false
                }
            } label: {
                if working { ProgressView().tint(Theme.onAccent) } else { Text("Restore") }
            }
            .buttonStyle(FilledButtonStyle())
            .disabled(working || RecoveryCode.decode(code) == nil)
            Button("Cancel") { dismiss() }
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity, minHeight: Theme.Size.aboutButton)
        }
        .padding(.horizontal, Theme.Space.xl + Theme.Space.xs)
        .padding(.top, Theme.Space.xl)
        .padding(.bottom, Theme.Space.xxl)
        .background(Theme.ground.ignoresSafeArea())
    }
}

/// The filled box behind a text field, which focuses the field when tapped
/// anywhere the field itself does not cover.
struct FieldBox: View {
    let focus: () -> Void

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .fill(Theme.card)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .onTapGesture(perform: focus)
    }
}

/// A username names the account's passkeys; optional, set only in Settings.
enum UsernameRule {
    static let minLength = 3
    static let maxLength = 32
}

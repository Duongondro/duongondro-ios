import SwiftUI
import DuongondroAPI
import DuongondroSync

/// Settings' account rows (the mockup's "Recovery code" and "This device").
/// Release builds have no way to sign in yet (passkeys, Sign in with Apple and
/// magic links come with the account screens), so outside DEBUG the section
/// shows only once an account exists.
struct AccountSection: View {
    @EnvironmentObject private var account: AccountModel
    @State private var restoring = false
    @State private var naming = false
    @State private var replacingCode = false
    @State private var name = ""

    var body: some View {
        Group { rows }
            // Outside the switch: the status changes while a restore runs, and a
            // sheet hung on one branch would vanish with it.
            .sheet(isPresented: $restoring) { RestoreView() }
    }

    @ViewBuilder private var rows: some View {
        switch account.status {
        case .none:
            #if DEBUG
            CardSection(header: "Account", footer: "Development builds only: a new account on this Mac's development server.") {
                Button { Task { await account.signInForDevelopment() } } label: {
                    SettingsRow("Sign in for development", chevron: true)
                }
            }
            #else
            EmptyView()
            #endif
        case .needsKeys where account.busy:
            CardSection(header: "Account") {
                HStack(spacing: Theme.Space.s) {
                    ProgressView()
                    Text("Making your keys…").foregroundStyle(Theme.muted)
                }
                .frame(minHeight: Theme.Size.minTap)
            }
        case .needsKeys:
            CardSection(header: "Account", footer: "Your counts are encrypted on this phone before they leave it. Set up keys on your first phone; on a new one, restore them with your recovery code.") {
                Button { Task { await account.setUp() } } label: { SettingsRow("Set up encryption", chevron: true) }
                Button { restoring = true } label: { SettingsRow("Restore with a recovery code", chevron: true) }
            }
        case .ready:
            CardSection(header: "Account") {
                Button { naming = true } label: {
                    SettingsRow("Your name", detail: Text(verbatim: account.displayName), chevron: true)
                }
                Button { replacingCode = true } label: {
                    SettingsRow("Recovery code", detail: account.recoveryUnconfirmed ? Text("Not confirmed") : Text("Make a new one"),
                                chevron: true)
                }
                .disabled(account.busy)
                .confirmationDialog("Make a new recovery code?", isPresented: $replacingCode, titleVisibility: .visible) {
                    Button("Make a new code") { Task { await account.newRecoveryCode() } }
                } message: {
                    Text("The code you wrote down stops working.")
                }
                Button { Task { await account.syncNow() } } label: {
                    SettingsRow("Sync", detail: syncDetail)
                }
            }
            CardSection(header: "This device") {
                SettingsRow("Device key", detail: Text(tierName))
                if let n = account.deviceCount {
                    SettingsRow("Your devices", detail: Text(verbatim: "\(n)"))
                }
            }
            .alert("Your name", isPresented: $naming) {
                TextField("Name", text: $name)
                Button("Save") { Task { await account.setDisplayName(name) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Friends see this name next to your streaks.")
            }
            .onChange(of: naming) { open in if open { name = account.displayName } }
            .task { await account.refreshFriends() }
        }
        if let error = account.error {
            Text(verbatim: error)
                .font(.footnote)
                .foregroundStyle(Theme.destructive)
                .padding(.horizontal, Theme.Space.l)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var syncDetail: Text {
        if account.syncing { return Text("Syncing…") }
        if let last = account.lastSync { return Text(last.formatted(.relative(presentation: .named))) }
        return Text("Not yet")
    }

    private var tierName: LocalizedStringKey {
        switch account.deviceTier {
        case .hardware: "Secure Enclave"
        case .tee: "Trusted environment"
        case .software: "Keychain"
        case nil: "None"
        }
    }
}

/// The recovery code, shown once (mockup: Recovery). The code is Crockford
/// base32 in groups of four, numbered like the mockup's words; "I wrote it
/// down" asks for two groups back before it goes away.
struct RecoveryCodeView: View {
    @EnvironmentObject private var account: AccountModel
    let code: String
    @State private var checking = false

    private var groups: [String] { code.split(separator: "-").map(String.init) }

    var body: some View {
        if checking {
            RecoveryCheckView(groups: groups) { account.confirmRecoveryCode() } back: { checking = false }
        } else {
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
                Button("I wrote it down") { checking = true }
                    .buttonStyle(FilledButtonStyle())
            }
            .padding(.horizontal, Theme.Space.xl + Theme.Space.xs)
            .padding(.top, Theme.Space.xl)
            .padding(.bottom, Theme.Space.xxl)
            .background(Theme.ground.ignoresSafeArea())
            .interactiveDismissDisabled()
        }
    }
}

/// Numbered groups in two columns, read down the first column, then the second.
private struct CodeGrid: View {
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
private struct RecoveryCheckView: View {
    let groups: [String]
    let done: () -> Void
    let back: () -> Void
    @State private var asked: [Int] = []
    @State private var answers = ["", ""]
    @State private var wrong = false

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
                        .padding(.horizontal, Theme.Space.m)
                        .frame(height: Theme.Size.field)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                            .strokeBorder(Theme.inputBorder))
                }
            }
            if wrong {
                Text("That does not match. Look at the code again.")
                    .font(.footnote)
                    .foregroundStyle(Theme.destructive)
            }
            Spacer(minLength: 0)
            Button("Done") {
                let ok = zip(asked, answers).allSatisfy { i, a in
                    RecoveryCode.normalise(a) == RecoveryCode.normalise(groups[i])
                }
                if ok { done() } else { wrong = true }
            }
            .buttonStyle(FilledButtonStyle())
            Button("Show the code again", action: back)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity, minHeight: Theme.Size.aboutButton)
        }
        .padding(.horizontal, Theme.Space.xl + Theme.Space.xs)
        .padding(.top, Theme.Space.xl)
        .padding(.bottom, Theme.Space.xxl)
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
            Text("The code you wrote down when you set up your first phone. Spaces and dashes do not matter.")
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

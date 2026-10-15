import SwiftUI
import DuongondroAPI
import DuongondroCore
import DuongondroSync

// Onboarding v2's account steps (design: 07-onboarding-offline), after the
// practice questions or from Settings: where the practice lives, consent, a
// passkey that makes the account (or an emailed link instead), then a name and
// gender, both skippable, and the recovery code; or, for an existing account,
// signing in and restoring. Nothing personal is required: a passkey is enough.

// MARK: - Building blocks

/// Localised from the app's language, for messages kept as state.
func localized(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .appLanguage, locale: .appLanguage)
}

/// The message for any failure of a call to the server.
var accountError: String { localized("Something went wrong. Check your connection and try again.") }

/// A sign-up refused because the server makes no accounts without an invitation
/// now (open sign-up off, or turned off since the sign-up began).
var invitationNeeded: String { localized("New accounts can't be made right now. Try again later, or keep practising on this phone.") }

/// The 429 of the limits on sign-ups without an invitation from one network
/// (accounts made, and sign-up mails requested).
var tooManyAccounts: String {
    localized("Too many sign-ups from this network in the last hour. Try again later, or open a friend's friendship link.")
}

/// The friendship link held for a sign-up no longer works: the next tap makes the
/// account without it.
var heldLinkGone: String {
    localized("This friendship link no longer works. Continue to make the account without it.")
}

/// One call in flight: buttons disable while it runs, `failed` says it did not finish.
@MainActor
final class StepCall: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var failed = false

    func run(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        failed = false
        Task {
            do { try await work() } catch { failed = true }
            busy = false
        }
    }
}

/// A screen of the account steps: a title and a line of detail, then the body,
/// with the actions pinned at the bottom. `centered` puts the block in the middle
/// of the free space, as the question screens do. Scrolls when a translation or
/// a large font does not fit.
struct AccountPage<Content: View, Actions: View, Top: View>: View {
    let title: LocalizedStringKey
    var detail: Text?
    var centered = false
    @ViewBuilder var top: Top
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.xl) {
                        top
                        Text(title)
                            .font(Typography.headingBold(30, relativeTo: .largeTitle))
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        if let detail {
                            detail
                                .font(.body)
                                .foregroundStyle(Theme.soft)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        content
                    }
                    .padding(.top, centered ? 0 : Theme.Space.xl)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: centered ? .leading : .topLeading)
                }
                .scrollDismissesKeyboard(.interactively)
                .plainBottomEdge()
            }
            VStack(spacing: Theme.Space.m) { actions }
                .padding(.top, Theme.Space.l)
                .padding(.bottom, Theme.Space.xl)
        }
    }
}

extension AccountPage where Top == EmptyView {
    init(title: LocalizedStringKey, detail: Text? = nil, centered: Bool = false,
         @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.init(title: title, detail: detail, centered: centered, top: { EmptyView() }, content: content, actions: actions)
    }
}

extension AccountPage where Top == EmptyView, Content == EmptyView {
    init(title: LocalizedStringKey, detail: Text? = nil, centered: Bool = false, @ViewBuilder actions: () -> Actions) {
        self.init(title: title, detail: detail, centered: centered, top: { EmptyView() }, content: { EmptyView() }, actions: actions)
    }
}

/// A label above a box, with a line of hint (or the error) below it.
struct LabelledField: View {
    let label: LocalizedStringKey
    @Binding var text: String
    var hint: LocalizedStringKey?
    var error: String?
    var code = false
    var keyboard: UIKeyboardType = .default
    var capitalization: TextInputAutocapitalization = .sentences
    var contentType: UITextContentType?
    var submit: (() -> Void)?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(label)
                .font(.footnote.weight(.bold))
                .foregroundStyle(error != nil ? Theme.destructive : Theme.accent)
                .padding(.leading, Theme.Space.xs)
            // Bound to what was typed, as typed: a binding that reshapes each
            // keystroke (grouping a code in fours) loses characters typed quickly.
            // Codes are read leniently from it instead (CodeEntry.normalise).
            TextField("", text: $text)
                .font(code ? .title3.monospaced() : .body)
                .foregroundStyle(Theme.ink)
                .keyboardType(keyboard)
                .textInputAutocapitalization(code ? .characters : capitalization)
                .autocorrectionDisabled(code || keyboard != .default)
                .textContentType(contentType)
                .submitLabel(.done)
                .onSubmit { submit?() }
                .focused($focused)
                .padding(.horizontal, Theme.Space.m)
                .frame(minHeight: Theme.Size.button)
                // The whole box takes the tap, not only the line of text in it,
                // caught behind the field so its caret and paste menu are untouched.
                .background(FieldBox { focused = true })
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(error != nil ? Theme.destructive : Theme.inputBorder, lineWidth: 1)
                    .allowsHitTesting(false))
                .accessibilityLabel(Text(label))
            if let error {
                Text(verbatim: error).font(.footnote).foregroundStyle(Theme.destructive)
                    .padding(.horizontal, Theme.Space.xs)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let hint {
                Text(hint).font(.footnote).foregroundStyle(Theme.muted)
                    .padding(.horizontal, Theme.Space.xs)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The characters of a code as typed or pasted: case, spaces, dashes and
/// look-alikes forgiven, a pasted link read from its last slash.
func codeCharacters(_ typed: String) -> String { CodeEntry.normalise(typed, maxLength: .max) }

/// A quiet text button under the main ones.
struct TextAction: View {
    let title: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.accent)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: Theme.Size.minTap)
        }
        .buttonStyle(.plain)
    }
}

/// The main action of a step; dimmed while it cannot be used.
struct StepButton: View {
    let title: LocalizedStringKey
    var enabled = true
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if busy { ProgressView().tint(Theme.onAccent) } else { Text(title) }
        }
        .buttonStyle(FilledButtonStyle(height: Theme.Size.button))
        .disabled(!enabled || busy)
        .opacity(enabled ? 1 : 0.4)
    }
}

struct OutlinedStepButton: View {
    let title: LocalizedStringKey
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) { Text(title) }
            .buttonStyle(OutlinedButtonStyle(height: Theme.Size.button))
            .disabled(!enabled)
    }
}

struct ErrorLine: View {
    let text: String?

    var body: some View {
        if let text {
            Text(verbatim: text)
                .font(.footnote)
                .foregroundStyle(Theme.destructive)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Routing

@MainActor
private enum Route {
    /// After any sign-in or sign-up: a new account gives its name next; an
    /// existing one sets up, restores, or is done.
    static func signedIn(created: Bool, flow: OnboardingFlow, account: AccountModel) async throws {
        if created {
            flow.signingIn = false
            account.accountCreated()
            flow.signedUp(next: .name)
            return
        }
        switch try await account.standing() {
        case .ready: flow.finishOnline()
        case .setUp: flow.go(.recovery)
        case .restore: flow.go(.restore)
        }
    }

    /// A redemption's answer: signed in, or the reason it was not, for under the field.
    static func redeemed(_ result: AccountModel.Redeem, flow: OnboardingFlow, account: AccountModel) async throws -> String? {
        switch result {
        case .signedIn(let created):
            try await signedIn(created: created, flow: flow, account: account)
            return nil
        case .wrong: return localized("That code doesn't match. Check the email and try again.")
        case .noAccount:
            // A sign-up's link refused at redemption: sign-up closed since it was sent.
            guard flow.signingIn else { return invitationNeeded }
            return localized("No account uses this email. Check the address, or go back and make an account.")
        case .inviteGone:
            // The friendship link that went with the sign-up is gone: the next
            // request goes without it.
            account.dropHeldInvite()
            return heldLinkGone
        case .tooMany: return localized("Too many tries. Wait a few minutes and try again.")
        case .passkeyFailed: return localized("That passkey did not work. Try again, or use your email instead.")
        case .otherAccountData:
            flow.otherAccount = true
            return nil
        }
    }
}

/// "This phone holds practice from another account": erase it here and go on
/// with the sign-in, or cancel, which ends the new session with nothing uploaded.
private struct OtherAccountDialog: ViewModifier {
    @EnvironmentObject private var flow: OnboardingFlow
    @EnvironmentObject private var account: AccountModel
    @ObservedObject var call: StepCall
    var onContinue: ((Bool) async throws -> Void)?

    func body(content: Content) -> some View {
        content.alert("This phone holds practice from another account", isPresented: $flow.otherAccount) {
            Button("Erase and continue", role: .destructive) {
                call.run {
                    let created = try account.eraseOtherAccountAndContinue()
                    if let onContinue {
                        try await onContinue(created)
                    } else {
                        try await Route.signedIn(created: created, flow: flow, account: account)
                    }
                }
            }
            Button("Cancel", role: .cancel) { Task { await account.abandonHeldSignIn() } }
        } message: {
            Text("Erase it here and continue? Whatever of it was synced stays in that account.")
        }
    }
}

// MARK: - Steps

/// The screen that asks whether the account exists at all.
struct WhereStep: View {
    @EnvironmentObject private var flow: OnboardingFlow
    @EnvironmentObject private var account: AccountModel

    var body: some View {
        AccountPage(title: "Keep it on this phone, or online?",
                    detail: Text("An account adds friends, public streaks and sync between phones. Counts are end-to-end encrypted either way: the server never sees them."),
                    centered: true) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                ForEach(["Friends see your streaks, never your counts",
                         "A new phone picks up where this one left off",
                         "You can make one later in Settings"], id: \.self) { line in
                    HStack(alignment: .top, spacing: Theme.Space.m) {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.bold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: Theme.Size.checkbox)
                            .accessibilityHidden(true)
                        Text(LocalizedStringKey(line))
                            .font(.subheadline)
                            .foregroundStyle(Theme.soft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(Theme.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        } actions: {
            StepButton(title: "Make an online account") {
                flow.signingIn = false
                flow.go(.consent)
            }
            OutlinedStepButton(title: "Only on this phone") {
                account.forgetHeldInvite()
                flow.finishLocal()
            }
        }
    }
}

/// GDPR Article 9: an account in a Buddhist practice app says something about
/// beliefs, so storing it needs explicit consent.
struct ConsentStep: View {
    @EnvironmentObject private var flow: OnboardingFlow

    var body: some View {
        AccountPage(title: "Before we store anything",
                    detail: Text("An account in a Buddhist practice app says something about your beliefs, which the GDPR treats as special. The server keeps your account: your passkeys, and your email if you add one; the name friends see; your username and gender if you give them; your friends; and your public streaks. Your counts stay encrypted on your phones."),
                    centered: true) {
            Button { flow.consented.toggle() } label: {
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    Image(systemName: flow.consented ? "checkmark.square.fill" : "square")
                        .font(.title3)
                        .foregroundStyle(flow.consented ? Theme.accent : Theme.inputBorder)
                        .frame(width: Theme.Size.checkbox)
                    Text("I agree that Duongöndro stores this to run my account. I can export or delete it all in Settings.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(Theme.Space.l)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(flow.consented ? .isSelected : [])
            Link(destination: URL(string: "https://duongondro.app/privacy/")!) {
                Text("Privacy policy")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.accent)
                    .frame(minHeight: Theme.Size.minTap)
                    .padding(.horizontal, Theme.Space.xs)
            }
        } actions: {
            StepButton(title: "Continue", enabled: flow.consented) { flow.go(.passkey) }
        }
    }
}

struct EmailStep: View {
    @EnvironmentObject private var flow: OnboardingFlow
    @EnvironmentObject private var account: AccountModel
    @StateObject private var call = StepCall()
    @State private var problem: String?

    private var valid: Bool {
        flow.email.trimmingCharacters(in: .whitespaces).range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil
    }

    var body: some View {
        AccountPage(title: "What's your email?", detail: Text("We send a sign-in link there. Nobody else sees it.")) {
            LabelledField(label: "Email", text: Binding(get: { flow.email }, set: { flow.email = $0; problem = nil }),
                          error: problem, keyboard: .emailAddress, capitalization: .never, contentType: .emailAddress,
                          submit: { if valid { send() } })
        } actions: {
            ErrorLine(text: call.failed ? accountError : nil)
            StepButton(title: "Continue", enabled: valid, busy: call.busy) { send() }
        }
    }

    /// Signing in, or the sign-up for a phone that cannot make a passkey.
    private func send() {
        call.run {
            if !flow.signingIn { await account.holdPendingInvite() }
            switch try await account.requestMagicLink(email: flow.email.trimmingCharacters(in: .whitespaces),
                                                      signUpWithConsent: flow.signUpConsent) {
            case .sent: flow.go(.checkEmail)
            case .unknownInvite:
                account.dropHeldInvite()
                problem = heldLinkGone
            case .tooMany: problem = localized("Too many tries. Wait a few minutes and try again.")
            case .tooManyAccounts: problem = tooManyAccounts
            case .invitationNeeded: problem = invitationNeeded
            }
        }
    }
}

/// The 8-character code from the mail, or the link in it opened on this phone:
/// redeemed only here, and only within 15 minutes of this phone's own request.
struct CheckEmailStep: View {
    @EnvironmentObject private var flow: OnboardingFlow
    @EnvironmentObject private var account: AccountModel
    @StateObject private var call = StepCall()
    @State private var code = ""
    @State private var problem: String?
    @State private var again = false

    private var address: String { flow.email.trimmingCharacters(in: .whitespaces) }
    private var complete: Bool { codeCharacters(code).count == CodeEntry.signInLength }

    var body: some View {
        AccountPage(title: "Check your email",
                    detail: Text("We sent a link to \(address). Open it on this phone, or type the code from the email.")) {
            LabelledField(label: "Code", text: Binding(get: { code }, set: { code = $0; problem = nil }),
                          hint: "Eight letters and digits, as in the email. Case doesn't matter; O and 0, I and 1 count as the same. Works for 15 minutes.",
                          error: problem, code: true, keyboard: .asciiCapable, contentType: .oneTimeCode,
                          submit: { if complete { submit() } })
        } actions: {
            ErrorLine(text: call.failed ? accountError : nil)
            StepButton(title: "Continue", enabled: complete, busy: call.busy) { submit() }
            TextAction(title: again ? "Sent again" : "Send it again") {
                guard !call.busy, !again else { return }
                call.run {
                    switch try await account.requestMagicLink(email: address, signUpWithConsent: flow.signUpConsent) {
                    case .sent: again = true
                    case .tooMany: problem = localized("Too many tries. Wait a few minutes and try again.")
                    case .tooManyAccounts: problem = tooManyAccounts
                    case .unknownInvite:
                        account.dropHeldInvite()
                        problem = heldLinkGone
                    case .invitationNeeded: problem = invitationNeeded
                    }
                }
            }
        }
        .modifier(OtherAccountDialog(call: call))
        .onAppear { redeemLink(account.magicToken) }
        .onChange(of: account.magicToken) { redeemLink($0) }
        .onChange(of: call.busy) { busy in if !busy { redeemLink(account.magicToken) } }
        // A link that arrives after leaving this step is never redeemed.
        .onDisappear { account.magicToken = nil }
    }

    private func submit() {
        call.run {
            problem = try await Route.redeemed(try await account.redeemCode(email: address, code: codeCharacters(code)),
                                               flow: flow, account: account)
        }
    }

    /// While a code is being redeemed the token waits in AccountModel, and is
    /// taken once that call ends; it is cleared only when its redemption starts.
    private func redeemLink(_ token: String?) {
        guard let token, !call.busy else { return }
        account.magicToken = nil
        call.run {
            if let result = try await account.redeemLink(token: token) {
                problem = try await Route.redeemed(result, flow: flow, account: account)
            }
        }
    }
}

/// The name friends see. The server gives an account made without one a random
/// "Adjective Animal", shown here to keep, change or clear (an empty name shows
/// as "A friend").
struct NameStep: View {
    @EnvironmentObject private var flow: OnboardingFlow
    @EnvironmentObject private var account: AccountModel
    @State private var loading = false
    @State private var failed = false

    /// Continue saves an edit of the name the server holds, so it waits for it.
    private var loaded: Bool { flow.serverName != nil }

    var body: some View {
        AccountPage(title: "What should we call you?",
                    detail: flow.serverName?.isEmpty == false
                        ? Text("A random name, so friends can tell you apart. Keep it or change it.")
                        : Text("Friends see this name next to your streaks.")) {
            LabelledField(label: "Name", text: Binding(get: { flow.displayName }, set: { flow.displayName = String($0.prefix(64)) }),
                          capitalization: .words, contentType: .givenName,
                          submit: { if loaded { flow.go(.gender) } })
        } actions: {
            ErrorLine(text: failed ? accountError : nil)
            if failed {
                StepButton(title: "Try again", busy: loading) { Task { await load() } }
            } else {
                StepButton(title: "Continue", enabled: loaded, busy: loading) { flow.go(.gender) }
            }
            // Skip keeps whatever the server holds, loaded or not.
            TextAction(title: "Skip") {
                flow.displayName = flow.serverName ?? ""
                flow.go(.gender)
            }
        }
        .task { if !loaded { await load() } }
    }

    private func load() async {
        loading = true
        failed = false
        if let name = await account.serverDisplayName() {
            flow.serverName = name
            if flow.displayName.isEmpty { flow.displayName = name }
        } else {
            failed = true
        }
        loading = false
    }
}

struct GenderStep: View {
    @EnvironmentObject private var flow: OnboardingFlow
    @EnvironmentObject private var account: AccountModel
    @StateObject private var call = StepCall()

    var body: some View {
        AccountPage(title: "Your gender",
                    detail: Text("Some languages use different verb endings for men and women. If you skip this step or choose \u{201C}Non-binary,\u{201D} the app will use gender-neutral forms wherever possible.")) {
            EmptyView()
        } actions: {
            ErrorLine(text: call.failed ? accountError : nil)
            OutlinedStepButton(title: "Male", enabled: !call.busy) { pick(.male) }
            OutlinedStepButton(title: "Female", enabled: !call.busy) { pick(.female) }
            OutlinedStepButton(title: "Non-binary", enabled: !call.busy) { pick(.nonbinary) }
            TextAction(title: "Skip") { if !call.busy { pick(nil) } }
        }
    }

    private func pick(_ gender: Gender?) {
        flow.gender = gender
        // Kept on the phone either way, so the app conjugates without the server.
        UserDefaults.standard.set(gender?.rawValue ?? "", forKey: Gender.storageKey)
        // The account exists (passkey or emailed link): it takes the name, if
        // changed, and the gender now.
        let edited = flow.serverName.map { flow.displayName != $0 } ?? !flow.displayName.isEmpty
        // An account made by email has one already; a passkey account is offered one.
        // `email` is set only by an address that signs in (a magic-link sign-up,
        // or GET /api/me), never by one merely asked for.
        let next: OnboardingStep = account.email == nil ? .addEmail : .recovery
        // Nothing to send: on without a call.
        guard edited || gender != nil else { return flow.go(next) }
        call.run {
            try await account.setProfile(name: edited ? flow.displayName : nil, gender: gender)
            // Saved: the server holds this name now, so going back and on again
            // sends nothing more.
            if edited {
                flow.displayName = AccountModel.trimmedName(flow.displayName)
                flow.serverName = flow.displayName
            }
            flow.go(next)
        }
    }
}

/// After a passkey sign-up: an email as a second way to sign in (a new phone
/// without the passkey, say), confirmed by a mailed code. Skippable.
struct AddEmailStep: View {
    @EnvironmentObject private var flow: OnboardingFlow
    @EnvironmentObject private var account: AccountModel
    @StateObject private var call = StepCall()

    private var address: String { flow.newEmail.trimmingCharacters(in: .whitespaces) }
    private var valid: Bool { address.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil }

    var body: some View {
        AccountPage(title: "Add an email?", detail: Text("A second way to sign in, for example on a new phone.")) {
            LabelledField(label: "Email", text: Binding(get: { flow.newEmail }, set: { flow.newEmail = $0; flow.newEmailProblem = nil }),
                          error: flow.newEmailProblem, keyboard: .emailAddress, capitalization: .never, contentType: .emailAddress,
                          submit: { if valid { send() } })
        } actions: {
            ErrorLine(text: call.failed ? accountError : nil)
            StepButton(title: "Continue", enabled: valid, busy: call.busy) { send() }
            TextAction(title: "Skip") { if !call.busy { flow.go(.recovery) } }
        }
    }

    private func send() {
        call.run {
            switch try await account.requestEmail(address) {
            case .sent: flow.go(.confirmEmail)
            case .invalid: flow.newEmailProblem = localized("That doesn't look like an email address.")
            case .tooMany: flow.newEmailProblem = localized("Too many tries. Wait a few minutes and try again.")
            }
        }
    }
}

/// The 8-character code mailed for the address, typed as a sign-in code is.
struct ConfirmEmailStep: View {
    @EnvironmentObject private var flow: OnboardingFlow
    @EnvironmentObject private var account: AccountModel
    @StateObject private var call = StepCall()
    @State private var code = ""
    @State private var problem: String?
    @State private var again = false

    private var address: String { flow.newEmail.trimmingCharacters(in: .whitespaces) }
    private var complete: Bool { codeCharacters(code).count == CodeEntry.signInLength }

    var body: some View {
        AccountPage(title: "Check your email", detail: Text("Type the code we sent to \(address).")) {
            LabelledField(label: "Code", text: Binding(get: { code }, set: { code = $0; problem = nil }),
                          hint: "Eight letters and digits, as in the email. Case doesn't matter; O and 0, I and 1 count as the same. Works for 15 minutes.",
                          error: problem, code: true, keyboard: .asciiCapable, contentType: .oneTimeCode,
                          submit: { if complete { submit() } })
        } actions: {
            ErrorLine(text: call.failed ? accountError : nil)
            StepButton(title: "Continue", enabled: complete, busy: call.busy) { submit() }
            TextAction(title: again ? "Sent again" : "Send it again") {
                guard !call.busy, !again else { return }
                call.run {
                    switch try await account.requestEmail(address) {
                    case .sent: again = true
                    case .invalid: problem = localized("That doesn't look like an email address.")
                    case .tooMany: problem = localized("Too many tries. Wait a few minutes and try again.")
                    }
                }
            }
            TextAction(title: "Skip") { if !call.busy { flow.go(.recovery) } }
        }
    }

    private func submit() {
        call.run {
            switch try await account.confirmEmail(address, code: codeCharacters(code)) {
            case .added: flow.go(.recovery)
            case .wrong: problem = localized("That code doesn't match. Check the email and try again.")
            case .tooMany: problem = localized("Too many tries. Wait a few minutes and try again.")
            case .taken:
                // Back to the address, to change it or skip.
                flow.newEmailProblem = localized("This email belongs to another account.")
                flow.back()
            }
        }
    }
}

/// Makes the account (design: onboarding, passkey first): consent given, nothing
/// else needed. A phone or password manager that cannot make a passkey uses an
/// emailed link instead.
struct PasskeyStep: View {
    @EnvironmentObject private var flow: OnboardingFlow
    @EnvironmentObject private var account: AccountModel
    @StateObject private var call = StepCall()
    @State private var problem: String?

    var body: some View {
        AccountPage(title: "Save a passkey",
                    detail: Text("Next time you sign in with Face ID or Touch ID. iCloud Keychain keeps it, so a new iPhone has it too."),
                    centered: true) {
            Circle()
                .fill(Theme.softFill)
                .frame(width: Theme.Size.passkeyBadge, height: Theme.Size.passkeyBadge)
                .overlay(Image(systemName: "person.badge.key.fill")
                    .font(.system(size: Theme.Size.passkeyIcon))
                    .foregroundStyle(Theme.accent))
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
        } content: {
            EmptyView()
        } actions: {
            ErrorLine(text: problem ?? (call.failed ? accountError : nil))
            StepButton(title: "Save a passkey", busy: call.busy) { save() }
            TextAction(title: "Use email instead") { if !call.busy { flow.go(.email) } }
        }
        .modifier(OtherAccountDialog(call: call) { created in
            if created { account.accountCreated() }
            flow.signedUp(next: .name)
        })
    }

    private func save() {
        problem = nil
        call.run {
            // A friendship link opened earlier goes with the sign-up as its proof.
            await account.holdPendingInvite()
            do {
                switch try await account.createPasskey(profile: nil, consent: flow.consented) {
                case .saved:
                    account.accountCreated()
                    flow.signedUp(next: .name)
                case .cancelled: break
                case .inviteGone:
                    // The link's code is gone: the next try goes without it.
                    account.dropHeldInvite()
                    problem = heldLinkGone
                case .invitationNeeded: problem = invitationNeeded
                case .tooManyAccounts: problem = tooManyAccounts
                case .tooMany: problem = localized("Too many tries. Wait a few minutes and try again.")
                case .usernameTaken: problem = accountError
                case .otherAccountData: flow.otherAccount = true
                }
            } catch Passkeys.Failure.refused {
                problem = localized("This phone could not save a passkey for Duongöndro.")
            }
        }
    }
}

/// Keys are made here, silently, and the recovery code shown once (resumed
/// with the same code after an interruption).
struct RecoveryStep: View {
    @EnvironmentObject private var flow: OnboardingFlow
    @EnvironmentObject private var account: AccountModel
    @StateObject private var setUp = StepCall()

    var body: some View {
        AccountPage(title: "Write down your recovery code",
                    detail: Text("If you lose this phone, this code is the only way back to your counts. Nobody else has it, not even us.")) {
            if let code = account.shownCode {
                CodeGrid(groups: code.split(separator: "-").map(String.init))
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: Theme.Size.passkeyBadge)
            }
            // A resumed run whose keys exist makes a new code: the old one is gone.
            if flow.newCodeOnResume, account.shownCode != nil {
                Text("This is a new recovery code. Any code you wrote down earlier no longer works.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Next we'll ask for two of these groups, to make sure. O and 0, I and 1 count as the same.")
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        } actions: {
            ErrorLine(text: setUp.failed ? accountError : nil)
            if setUp.failed {
                StepButton(title: "Try again", busy: setUp.busy) { makeKeys() }
            } else {
                StepButton(title: LocalizedStringKey(Gendered.mine("I wrote it down")),
                           enabled: account.shownCode != nil) {
                    flow.go(.recoveryCheck)
                }
            }
            // Into the app with the account ready and the code unconfirmed:
            // Settings shows the same code again, and signing out waits for it.
            if account.shownCode != nil {
                TextAction(title: "Not now") { flow.finishOnline() }
            } else if flow.newCodeOnResume, setUp.failed {
                // Keys exist, so the app works without a code: in now, and
                // Settings asks for a new one.
                TextAction(title: "Not now") {
                    account.leaveWithoutCode()
                    flow.finishOnline()
                }
            }
        }
        .onAppear {
            // Made at sign-up already, normally: this waits for the same work.
            if account.shownCode == nil { makeKeys() }
        }
    }

    /// AccountModel runs the work one at a time and keeps the code, so showing
    /// this step again waits for the same set-up and shows the same code.
    private func makeKeys() {
        setUp.run { _ = try await account.setUpKeys() }
    }
}

struct RecoveryCheckStep: View {
    @EnvironmentObject private var flow: OnboardingFlow
    @EnvironmentObject private var account: AccountModel

    var body: some View {
        // The code the step before showed: the account's own, never another's.
        RecoveryCheckView(groups: RecoveryCode.groups(account.shownCode ?? ""), framed: false) {
            account.confirmRecoveryCode()
            flow.finishOnline()
        } back: {
            flow.back()
        }
    }
}

/// A new phone, without the old one: the recovery code brings the keys back.
struct RestoreStep: View {
    @EnvironmentObject private var flow: OnboardingFlow
    @EnvironmentObject private var account: AccountModel
    @StateObject private var call = StepCall()
    @State private var code = ""
    @State private var wrong = false

    private var complete: Bool { codeCharacters(code).count == CodeEntry.recoveryLength }

    var body: some View {
        AccountPage(title: "Restore with your recovery code",
                    detail: Text(verbatim: Gendered.mine("The code you wrote down when you set up your first phone. Spaces and dashes do not matter."))) {
            LabelledField(label: "Recovery code", text: Binding(get: { code }, set: { code = $0; wrong = false }),
                          error: wrong ? localized("That recovery code does not open this account.") : nil,
                          code: true, keyboard: .asciiCapable, submit: { if complete { submit() } })
        } actions: {
            ErrorLine(text: call.failed ? accountError : nil)
            StepButton(title: "Continue", enabled: complete, busy: call.busy) { submit() }
        }
    }

    private func submit() {
        call.run {
            if try await account.restoreKeys(code: codeCharacters(code)) { flow.finishOnline() } else { wrong = true }
        }
    }
}

struct SignInStep: View {
    @EnvironmentObject private var flow: OnboardingFlow
    @EnvironmentObject private var account: AccountModel
    @StateObject private var call = StepCall()
    @State private var problem: String?

    var body: some View {
        AccountPage(title: "Welcome back",
                    detail: Text("Your phone offers the passkey you saved. No passkey on this phone? We email you a link and a code."),
                    centered: true) {
            ErrorLine(text: problem ?? (call.failed ? accountError : nil))
            StepButton(title: "Sign in with a passkey", busy: call.busy) {
                problem = nil
                call.run {
                    do {
                        if let result = try await account.signInWithPasskey() {
                            problem = try await Route.redeemed(result, flow: flow, account: account)
                        } else {
                            problem = localized("No passkey for Duongöndro on this phone. Use your email instead.")
                        }
                    } catch Passkeys.Failure.refused {
                        problem = localized("No passkey for Duongöndro on this phone. Use your email instead.")
                    }
                }
            }
            OutlinedStepButton(title: "Email me a link", enabled: !call.busy) { flow.go(.email) }
        }
        .modifier(OtherAccountDialog(call: call))
        // Signing in instead of up: a friendship link held for the sign-up is dropped.
        .onAppear { account.forgetHeldInvite() }
    }
}

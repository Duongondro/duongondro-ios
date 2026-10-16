import SwiftUI
import DuongondroAPI

/// Settings › Passkeys (design: Settings › Passkeys, decision 25), as Android's:
/// one row per passkey with its name (the person's, else its password
/// manager's), when it was added and last used, and whether it unlocks the
/// counts on a new phone; Add a passkey; Rename; Remove, confirmed, which the
/// server refuses for the last way to sign in.
struct PasskeysView: View {
    @EnvironmentObject private var account: AccountModel
    @State private var adding = false
    @State private var note: String?
    @State private var renaming: Passkey?
    @State private var newName = ""
    @State private var removing: Passkey?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                Text("Each passkey signs you in to this account. Names are only for you.")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, Theme.Space.l)
                    .fixedSize(horizontal: false, vertical: true)
                if account.offersPasskeyUnlock { PasskeyUnlockCard() }
                if !account.passkeys.isEmpty {
                    CardSection {
                        ForEach(account.passkeys) { passkey in
                            PasskeyRow(passkey: passkey,
                                       rename: { newName = passkey.name ?? ""; renaming = passkey },
                                       remove: { removing = passkey })
                        }
                    }
                } else if !account.passkeysLoaded {
                    ProgressView().frame(maxWidth: .infinity)
                }
                StepButton(title: "Add a passkey", busy: adding) { add() }
                if let note {
                    Text(verbatim: note)
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, Theme.Space.l)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.top, Theme.Space.l)
        }
        .buttonStyle(.plain)
        .background(Theme.ground.ignoresSafeArea())
        .navigationTitle("Passkeys")
        .navigationBarTitleDisplayMode(.inline)
        .task { await account.refreshPasskeys() }
        .alert("Rename passkey", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(text: $newName, prompt: Text(verbatim: renaming.map(Self.name) ?? "")) { Text("Name") }
            Button("Save") {
                guard let passkey = renaming else { return }
                Task { if await !account.renamePasskey(passkey, to: newName) { note = accountError } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave it empty to use the password manager's name.")
        }
        .confirmationDialog(Text("Remove “\(removing.map(Self.name) ?? "")”?"),
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { passkey in
            Button("Remove", role: .destructive) { remove(passkey) }
            // Removing is not revocation: a passkey that could unlock the counts
            // may have opened them already (docs/crypto.md › Passkey unlock).
            if passkey.canUnlock {
                Button("Remove and replace the unlock key", role: .destructive) { remove(passkey, replacingUnlockKey: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { passkey in
            let removal = passkey.current
                ? Text("It can no longer sign you in, and anywhere it is signed in now is signed out, this phone included. The passkey itself stays in your password manager until you delete it there.")
                : Text("It can no longer sign you in, and anywhere it is signed in now is signed out. The passkey itself stays in your password manager until you delete it there.")
            if passkey.canUnlock {
                removal + Text(verbatim: "\n\n")
                    + Text("Replacing the unlock key too: other phones are signed out, and this passkey can no longer unlock your counts on a new phone. A phone it already unlocked keeps what it has. Your other passkeys then need setting up again.")
            } else {
                removal
            }
        }
    }

    /// The person's name for it, its password manager's, or "Passkey".
    static func name(_ passkey: Passkey) -> String {
        passkey.displayName ?? localized("Passkey")
    }

    private func add() {
        guard !adding else { return }
        adding = true
        note = nil
        Task {
            defer { adding = false }
            do {
                // Signed in, this only adds a passkey: no sign-up, so no consent goes with it.
                if case .saved = try await account.createPasskey(profile: nil, consent: false) {
                    note = localized("Passkey saved.")
                }
            } catch Passkeys.Failure.refused {
                note = localized("This phone could not save a passkey for Duongöndro.")
            } catch {
                note = accountError
            }
        }
    }

    private func remove(_ passkey: Passkey, replacingUnlockKey: Bool = false) {
        note = nil
        Task {
            switch await account.removePasskey(passkey, replacingUnlockKey: replacingUnlockKey) {
            case .removed: break
            case .lastWayToSignIn:
                note = localized("This is the only way to sign in to your account, so it stays. Add another passkey or an email first.")
            case .failed: note = accountError
            }
        }
    }
}

private struct PasskeyRow: View {
    let passkey: Passkey
    let rename: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(verbatim: PasskeysView.name(passkey)).foregroundStyle(Theme.ink)
                Text(verbatim: used).font(.subheadline).foregroundStyle(Theme.muted)
                if passkey.canUnlock {
                    Label("Unlocks your counts on a new phone", systemImage: "key")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                }
            }
            .padding(.vertical, Theme.Space.s)
            Spacer(minLength: Theme.Space.s)
            Button(action: rename) {
                Image(systemName: "pencil").frame(width: Theme.Size.minTap, height: Theme.Size.minTap)
            }
            .foregroundStyle(Theme.muted)
            .accessibilityLabel(Text("Rename \(PasskeysView.name(passkey))"))
            Button(action: remove) {
                Image(systemName: "trash").frame(width: Theme.Size.minTap, height: Theme.Size.minTap)
            }
            .foregroundStyle(Theme.muted)
            .accessibilityLabel(Text("Remove \(PasskeysView.name(passkey))"))
        }
    }

    /// "Added on 7 Oct 2026 · last used today": each half its own string, so
    /// "today" never lands after a preposition made for a date.
    private var used: String {
        let created = passkey.createdAt
        let added = Self.isToday(created) ? localized("Added today") : localized("Added on \(Self.day(created))")
        guard let last = passkey.lastUsedAt else { return added }
        let used = Self.isToday(last) ? localized("last used today") : localized("last used \(Self.day(last))")
        return added + " · " + used
    }

    private static func isToday(_ date: Date) -> Bool { Calendar.current.isDateInToday(date) }

    private static func day(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: .appLanguage))
    }
}

/// The calm card for an account made before passkey unlock, or a passkey that
/// gave no PRF output when it was made: one ceremony, whichever passkey answers.
/// Only in Settings, never over a count.
struct PasskeyUnlockCard: View {
    @EnvironmentObject private var account: AccountModel
    @State private var working = false
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Let your passkey unlock your counts on a new phone")
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("Signing in with it on a new phone then brings your counts back without the recovery code.")
                .font(.footnote)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let note {
                Text(verbatim: note)
                    .font(.footnote)
                    .foregroundStyle(Theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button { run() } label: {
                HStack(spacing: Theme.Space.s) {
                    Text("Use my passkey").font(.body.weight(.semibold)).foregroundStyle(Theme.accent)
                    if working { ProgressView() }
                }
                .frame(minHeight: Theme.Size.minTap)
                .contentShape(Rectangle())
            }
            .disabled(working)
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private func run() {
        working = true
        note = nil
        Task {
            defer { working = false }
            switch await account.letPasskeyUnlock() {
            case .saved, .cancelled: break
            case .noPRF:
                note = localized("This passkey can't unlock your counts. Keep your recovery code, or add a new passkey in Passkeys.")
            case .waiting:
                note = localized("Another of your phones is setting this up. Try again after it has synced.")
            case .otherAccount:
                note = localized("That passkey belongs to another account.")
            case .failed:
                note = accountError
            }
        }
    }
}

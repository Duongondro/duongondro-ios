import SwiftUI
import DuongondroAPI
import DuongondroQR
import DuongondroSync

/// The mockup's Invite screen: the link as a round burgundy badge around a QR
/// code (dot modules, rounded eyes, nothing over the code), and a share button.
/// "Show my add-friend code" swaps in a ten-minute code for showing in person.
struct InviteView: View {
    @EnvironmentObject private var account: AccountModel
    @Environment(\.dismiss) private var dismiss
    @State private var kind = InviteLink.Kind.invite
    @State private var invite: (link: InviteLink, expiresAt: Date)?
    @State private var failed = false

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            Spacer(minLength: 0)
            QRBadge(text: invite?.link.string)
            VStack(spacing: Theme.Space.xs) {
                Text("Scan with any phone camera")
                    .font(Typography.title)
                    .foregroundStyle(Theme.ink)
                Text(kind == .invite ? "Anyone with this code can join · expires in 7 days"
                                     : "Show this in person · expires in 10 minutes")
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
            }
            if failed {
                Text(verbatim: account.error ?? "")
                    .font(.footnote)
                    .foregroundStyle(Theme.destructive)
            }
            Spacer(minLength: 0)
            VStack(spacing: Theme.Space.s) {
                if let invite {
                    ShareLink(item: invite.link.url,
                              message: Text("Practise with me on Duongöndro: \(invite.link.string)")) {
                        Text("Share invite link")
                    }
                    .buttonStyle(FilledButtonStyle())
                } else {
                    Button("Share invite link") {}.buttonStyle(FilledButtonStyle()).disabled(true).opacity(0.4)
                }
                Button(kind == .invite ? "Show my add-friend code" : "Show the invite code") {
                    kind = kind == .invite ? .friend : .invite
                }
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity, minHeight: Theme.Size.aboutButton)
            }
        }
        .padding(.horizontal, Theme.Space.xl + Theme.Space.xs)
        .padding(.bottom, Theme.Space.xl)
        .background(Theme.ground.ignoresSafeArea())
        .navigationTitle("Invite a friend")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .task(id: kind) {
            // An add-friend code lasts ten minutes: a fresh one replaces it a
            // minute before it expires, for as long as the screen is open.
            repeat {
                invite = nil
                failed = false
                invite = await account.createInvite(kind)
                failed = invite == nil
                guard let expiresAt = invite?.expiresAt, kind == .friend else { return }
                let wait = max(5, expiresAt.timeIntervalSinceNow - 60)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            } while !Task.isCancelled
        }
    }
}

/// A 300 pt burgundy disc with a white tile holding the code, and a small gold
/// vajra above it, outside the code's quiet zone.
struct QRBadge: View {
    let text: String?

    var body: some View {
        ZStack {
            Circle().fill(Theme.hero)
            RoundedRectangle(cornerRadius: Theme.Radius.bigButton, style: .continuous)
                .fill(Theme.qrGround)
                .frame(width: 196, height: 196)
            if let text, let code = try? QRCode.encode(text, ecc: .medium) {
                // Four modules of white all round (the spec's quiet zone): 29 + 8
                // modules across the 196 pt tile.
                QRModules(code: code)
                    .frame(width: 196 * CGFloat(code.size) / CGFloat(code.size + 8),
                           height: 196 * CGFloat(code.size) / CGFloat(code.size + 8))
                    .accessibilityLabel(Text("QR code of the invite link"))
            } else {
                ProgressView()
            }
            Vajra()
                .stroke(Theme.gold, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .frame(width: 16, height: 26)
                .offset(y: -150 + 29)
                .accessibilityHidden(true)
        }
        .frame(width: 300, height: 300)
    }
}

/// The modules as dots, the three finder patterns as rounded squares. Always
/// burgundy on white in both themes: a camera needs the contrast.
private struct QRModules: View {
    let code: QRCode

    var body: some View {
        Canvas { context, size in
            let m = size.width / CGFloat(code.size)
            let ink = Theme.qrInk
            for y in 0..<code.size {
                for x in 0..<code.size where code[x, y] && !code.isFinderModule(x: x, y: y) {
                    let r = CGRect(x: CGFloat(x) * m, y: CGFloat(y) * m, width: m, height: m).insetBy(dx: m * 0.08, dy: m * 0.08)
                    context.fill(Path(ellipseIn: r), with: .color(ink))
                }
            }
            for (fx, fy) in [(0, 0), (code.size - 7, 0), (0, code.size - 7)] {
                let outer = CGRect(x: CGFloat(fx) * m, y: CGFloat(fy) * m, width: 7 * m, height: 7 * m)
                context.stroke(Path(roundedRect: outer.insetBy(dx: m / 2, dy: m / 2), cornerRadius: m * 1.6),
                               with: .color(ink), lineWidth: m)
                let inner = CGRect(x: CGFloat(fx + 2) * m, y: CGFloat(fy + 2) * m, width: 3 * m, height: 3 * m)
                context.fill(Path(roundedRect: inner, cornerRadius: m * 0.9), with: .color(ink))
            }
        }
    }
}

/// The mockup's small vajra: a hub with two prongs above and two below.
private struct Vajra: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 16, sy = rect.height / 26
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy) }
        var path = Path()
        path.addEllipse(in: CGRect(origin: p(6, 11), size: CGSize(width: 4 * sx, height: 4 * sy)))
        path.move(to: p(8, 11)); path.addLine(to: p(8, 2))
        path.move(to: p(8, 11)); path.addCurve(to: p(4, 4.5), control1: p(8, 8), control2: p(4, 7))
        path.addCurve(to: p(6, 2.2), control1: p(4, 3.4), control2: p(5, 2.6))
        path.move(to: p(8, 11)); path.addCurve(to: p(12, 4.5), control1: p(8, 8), control2: p(12, 7))
        path.addCurve(to: p(10, 2.2), control1: p(12, 3.4), control2: p(11, 2.6))
        path.move(to: p(8, 15)); path.addLine(to: p(8, 24))
        path.move(to: p(8, 15)); path.addCurve(to: p(4, 21.5), control1: p(8, 18), control2: p(4, 19))
        path.addCurve(to: p(6, 23.8), control1: p(4, 22.6), control2: p(5, 23.4))
        path.move(to: p(8, 15)); path.addCurve(to: p(12, 21.5), control1: p(8, 18), control2: p(12, 19))
        path.addCurve(to: p(10, 23.8), control1: p(12, 22.6), control2: p(11, 23.4))
        return path
    }
}

/// An invite opened from a link or pasted: checked first (the inviter's key, by
/// the link's secret), then accepted.
struct AcceptInviteView: View {
    @EnvironmentObject private var account: AccountModel
    @Environment(\.dismiss) private var dismiss
    let link: InviteLink
    @State private var checked: Social.CheckedInvite?
    @State private var problem: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(link.kind == .invite ? "You're invited" : "Add a friend")
                .font(Typography.headingBold(30, relativeTo: .largeTitle))
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Text("Accepting makes the two of you friends: each sees the other's public streaks, never counts.")
                .foregroundStyle(Theme.soft)
                .fixedSize(horizontal: false, vertical: true)
            if let problem {
                Text(verbatim: problem).font(.subheadline).foregroundStyle(Theme.destructive)
            } else if checked == nil {
                ProgressView()
            } else if account.status != .ready {
                Text("Set up your account under You first, then open the link again.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
            Button {
                guard let checked else { return }
                working = true
                Task {
                    do {
                        try await account.accept(checked)
                        dismiss()
                    } catch Social.Failure.ownInvite {
                        problem = String(localized: "This is your own invite. Send it to a friend instead.")
                    } catch APIError.notFound {
                        problem = String(localized: "This invite cannot be used: it may have expired or been withdrawn.")
                    } catch {
                        problem = String(localized: "Could not reach Duongöndro. Check the connection and try again.")
                    }
                    working = false
                }
            } label: {
                if working { ProgressView().tint(Theme.onAccent) } else { Text("Accept") }
            }
            .buttonStyle(FilledButtonStyle())
            .disabled(checked == nil || account.status != .ready || working)
            .opacity(checked == nil || account.status != .ready ? 0.4 : 1)
            Button("Not now") {
                account.pendingInvite = nil
                dismiss()
            }
            .font(.subheadline.weight(.bold))
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity, minHeight: Theme.Size.aboutButton)
        }
        .padding(.horizontal, Theme.Space.xl + Theme.Space.xs)
        .padding(.top, Theme.Space.xl)
        .padding(.bottom, Theme.Space.xxl)
        .background(Theme.ground.ignoresSafeArea())
        .task {
            do {
                checked = try await account.check(link)
            } catch Social.Failure.expired {
                problem = String(localized: "This invite has expired. Ask for a new one.")
            } catch Social.Failure.notAuthentic {
                problem = String(localized: "This invite does not check out, so it was not accepted. Ask your friend to send it again.")
            } catch APIError.notFound {
                problem = String(localized: "This invite cannot be used: it may have expired or been withdrawn.")
            } catch {
                problem = String(localized: "Could not reach Duongöndro. Check the connection and try again.")
            }
        }
    }
}

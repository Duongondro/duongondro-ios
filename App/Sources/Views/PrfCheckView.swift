import SwiftUI

/// Settings › About › long press on Version: the passkey PRF check
/// (`PrfCheck`). It sends nothing to the server and keeps nothing; it shows
/// whether a PRF output came back and a short fingerprint of it, never the
/// output. English only, as text not in the string catalog: a diagnostic, not
/// part of the app.
struct PrfCheckView: View {
    @StateObject private var check = PrfCheck()
    @State private var lines: [String] = []
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                VStack(spacing: Theme.Space.s) {
                    Button { run("sign-in") { try await check.signIn() } } label: {
                        Text(verbatim: "Sign in with a passkey")
                    }
                    .buttonStyle(FilledButtonStyle())
                    Button { run("creation") { try await check.create() } } label: {
                        Text(verbatim: "Create a test passkey")
                    }
                    .buttonStyle(OutlinedButtonStyle())
                }
                .disabled(busy)
                Text(verbatim: "Sign in twice with the same passkey: the two fingerprints must match. Nothing is sent to the server or kept on this phone. Delete \"PRF check\" from Passwords after creating one.")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.Space.m)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                }
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.top, Theme.Space.l)
        }
        .background(Theme.ground.ignoresSafeArea())
        .navigationTitle(Text(verbatim: "Passkey PRF check"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func run(_ label: String, _ ceremony: @escaping () async throws -> PrfCheck.Result) {
        busy = true
        Task {
            let line: String
            do {
                let r = try await ceremony()
                var parts = ["passkey …\(r.credentialID.base64EncodedString().suffix(6))"]
                if let supported = r.supported { parts.append("prf supported=\(supported)") }
                parts.append(r.output.map { "PRF output, fingerprint \(PrfCheck.fingerprint($0))" } ?? "no PRF output")
                line = parts.joined(separator: "; ")
            } catch PrfCheck.Failure.unsupportedSystem {
                line = "needs iOS 18 (this is \(UIDevice.current.systemVersion))"
            } catch {
                line = "failed: \(error)"
            }
            lines.insert("\(label) — \(line)", at: 0)
            busy = false
        }
    }
}

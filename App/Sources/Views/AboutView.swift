import SwiftUI

/// Settings › About: what is running, so anyone can match the app to its source.
struct AboutSection: View {
    @EnvironmentObject private var account: AccountModel
    private let build = BuildIdentity.current

    var body: some View {
        CardSection(header: "About", footer: "Tap Source to open this exact commit on GitHub.") {
            SettingsRow("Version", detail: Text(verbatim: build.version))
            SourceRow(build: build)
            if let server = account.serverVersion {
                // The server's commit, linked like the app's.
                Button {
                    if server.revision != "unknown",
                       let url = URL(string: "https://github.com/Duongondro/duongondro-api/commit/\(server.revision)") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    SettingsRow("Server", detail: Text(verbatim: server.short).font(.system(.subheadline, design: .monospaced)))
                }
            }
            NavigationLink { FeedbackView() } label: {
                SettingsRow("Feedback", chevron: true)
            }
            NavigationLink { AboutView() } label: {
                SettingsRow("About and contributors", chevron: true)
            }
        }
        .task(id: account.status) { await account.loadServerVersion() }
    }
}

/// The short commit, `-dirty` on development builds. Tap opens the commit on
/// GitHub, a long press copies the full hash.
private struct SourceRow: View {
    let build: BuildIdentity

    var body: some View {
        Button {
            if let url = build.commitURL { UIApplication.shared.open(url) }
        } label: {
            HStack(spacing: Theme.Space.s) {
                Text("Source").foregroundStyle(Theme.ink)
                Spacer(minLength: Theme.Space.s)
                Text(verbatim: build.shortRevision)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(Theme.accent)
                Image(systemName: "arrow.up.right.square")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, Theme.Space.s)
            .frame(minHeight: Theme.Size.minTap)
            .contentShape(Rectangle())
        }
        .contextMenu {
            Button { UIPasteboard.general.string = build.revision } label: { Label("Copy full hash", systemImage: "doc.on.doc") }
        }
    }
}

/// Settings › About and contributors: the name, what is running, the humans who made it.
struct AboutView: View {
    private let build = BuildIdentity.current
    private let contributors = Contributors.load()
    @State private var showingLicences = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.l) {
                VStack(spacing: Theme.Space.s) {
                    Text("Duongöndro")
                        .font(Typography.headingBold(30, relativeTo: .title))
                        .foregroundColor(Theme.accent)
                    (Text(verbatim: build.version + " \u{00B7} ")
                        + Text(verbatim: build.shortRevision).font(.system(.subheadline, design: .monospaced)).foregroundColor(Theme.accent))
                        .font(.subheadline)
                        .foregroundColor(Theme.muted)
                    Text("End-to-end encrypted and fully open source.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, Theme.Space.xl)

                if !contributors.isEmpty {
                    CardSection(header: "Made by",
                                footer: "Everyone who committed to the app, server, design or Android repositories, most commits first. Generated from the git history when the app is built.") {
                        ForEach(contributors, id: \.self) { name in
                            Text(verbatim: name)
                                .foregroundStyle(Theme.ink)
                                .frame(maxWidth: .infinity, minHeight: Theme.Size.minTap, alignment: .leading)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Space.xl)
        }
        .background(Theme.ground.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: Theme.Space.m) {
                Button("Source code") { openURL(Self.repository) }
                Button("Licences") { showingLicences = true }
            }
            .buttonStyle(OutlinedButtonStyle(height: Theme.Size.aboutButton))
            .padding(.horizontal, Theme.Space.xl)
            .padding(.vertical, Theme.Space.m)
            .background(Theme.ground)
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingLicences) {
            NavigationStack {
                LicencesView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingLicences = false } } }
            }
        }
    }

    private static let repository = URL(string: "https://github.com/Duongondro/duongondro-ios")!
}

private struct LicencesView: View {
    var body: some View {
        ScrollView {
            CardSection {
                LicenceRow(name: "Duongöndro for iOS", licence: "BSD-3-Clause", url: "https://github.com/Duongondro/duongondro-ios/blob/main/LICENSE")
                LicenceRow(name: "GRDB.swift", licence: "MIT", url: "https://github.com/groue/GRDB.swift/blob/master/LICENSE")
                LicenceRow(name: "IBM Plex Sans", licence: "SIL Open Font License 1.1", url: "https://github.com/IBM/plex/blob/master/LICENSE.txt")
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.top, Theme.Space.l)
        }
        .background(Theme.ground.ignoresSafeArea())
        .navigationTitle("Licences")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LicenceRow: View {
    let name: String
    let licence: String
    let url: String

    var body: some View {
        Link(destination: URL(string: url)!) {
            VStack(alignment: .leading) {
                Text(verbatim: name).foregroundStyle(Theme.ink)
                Text(verbatim: licence).font(.footnote).foregroundStyle(Theme.muted)
            }
            .padding(.vertical, Theme.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Settings › About › Feedback (design: Settings › Feedback): an e-mail that
/// starts with what is running, or a public GitHub issue. Never counts or practices.
struct FeedbackView: View {
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system
    @Environment(\.openURL) private var openURL

    static let address = "duongondro@moroz.dev"
    private static let issues = URL(string: "https://github.com/Duongondro/duongondro-ios/issues")!

    var body: some View {
        let header = Self.header(language: language)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                CardSection {
                    Button { if let url = Self.mailURL(header: header) { openURL(url) } } label: {
                        row(title: "Write an email", detail: Text(verbatim: Self.address), systemImage: "envelope")
                    }
                    Button { openURL(Self.issues) } label: {
                        row(title: "Report a bug on GitHub", detail: Text("Public, needs a GitHub account"),
                            systemImage: "arrow.up.right.square")
                    }
                }
                CardSection(header: "The email starts with",
                            footer: "You can delete it before sending. No counts or practices are added.") {
                    Text(verbatim: header)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, Theme.Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.top, Theme.Space.l)
            .padding(.bottom, Theme.Space.xl)
        }
        .buttonStyle(.plain)
        .background(Theme.ground.ignoresSafeArea())
        .navigationTitle("Feedback")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(title: LocalizedStringKey, detail: Text, systemImage: String) -> some View {
        HStack(spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(title).foregroundStyle(Theme.ink)
                detail.font(.footnote).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: Theme.Space.s)
            Image(systemName: systemImage)
                .font(.footnote)
                .foregroundStyle(Theme.muted)
                .accessibilityHidden(true)
        }
        .padding(.vertical, Theme.Space.s)
        .frame(minHeight: Theme.Size.minTap)
        .contentShape(Rectangle())
    }

    /// The three lines the e-mail starts with, in English for whoever reads it:
    /// "Duongöndro 0.5 (12) · 1a2b3c4", "iOS 17.1 · iPhone15,2", "Language: polski".
    static func header(language: AppLanguage, build: BuildIdentity = .current) -> String {
        let name = AppLanguage(rawValue: language.localization())?.nativeName ?? "English"
        return [
            "Duongöndro \(build.version) \u{00B7} \(build.shortRevision)",
            "iOS \(UIDevice.current.systemVersion) \u{00B7} \(modelIdentifier)",
            "Language: \(name)",
        ].joined(separator: "\n")
    }

    /// The model identifier, such as "iPhone15,2" (the simulated one in the Simulator).
    static var modelIdentifier: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// mailto: with the subject and the header, then a blank line to write under.
    static func mailURL(header: String) -> URL? {
        // Query values are encoded whole: no `&`, `=`, `+` or `#` left as they are.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        return URL(string: "mailto:\(address)?subject=\(encode("Duongöndro feedback"))&body=\(encode(header + "\n\n"))")
    }
}

/// Reads BuildInfo.plist written by Scripts/build-info.sh.
struct BuildIdentity {
    let version: String
    let revision: String
    let dirty: Bool

    var shortRevision: String {
        let short = revision == "unknown" ? revision : String(revision.prefix(7))
        return dirty ? short + "-dirty" : short
    }

    /// A dirty build's hash still names its parent commit, which exists on GitHub once pushed.
    var commitURL: URL? {
        guard revision != "unknown" else { return nil }
        return URL(string: "https://github.com/Duongondro/duongondro-ios/commit/\(revision)")
    }

    static let current: BuildIdentity = {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
        guard let url = Bundle.main.url(forResource: "BuildInfo", withExtension: "plist"),
              let dict = NSDictionary(contentsOf: url) as? [String: Any]
        else { return BuildIdentity(version: version, revision: "unknown", dirty: false) }
        return BuildIdentity(version: version,
                             revision: dict["Revision"] as? String ?? "unknown",
                             dirty: dict["Dirty"] as? Bool ?? false)
    }()
}

/// Contributors.json, generated at build time by Scripts/build-info.sh.
enum Contributors {
    static func load() -> [String] {
        guard let url = Bundle.main.url(forResource: "Contributors", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let names = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return names
    }
}

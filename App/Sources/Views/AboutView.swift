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
            NavigationLink { AboutView() } label: {
                SettingsRow("About and contributors", chevron: true)
            }
        }
        .task { await account.loadServerVersion() }
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

import SwiftUI

/// Settings › About: what is running, so anyone can match the app to its
/// source, and the humans who made it.
struct AboutSection: View {
    private let build = BuildIdentity.current

    var body: some View {
        Section("About") {
            LabeledContent("Version", value: build.version)
            SourceRow(build: build)
            Link(destination: URL(string: "https://github.com/Duongondro/duongondro-ios")!) {
                LabeledContent("Source code", value: "BSD-3-Clause")
            }
            NavigationLink("Contributors") { ContributorsView() }
            NavigationLink("Licences") { LicencesView() }
        }
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
            LabeledContent("Source", value: build.shortRevision)
        }
        .foregroundStyle(.primary)
        .contextMenu {
            Button { UIPasteboard.general.string = build.revision } label: { Label("Copy full hash", systemImage: "doc.on.doc") }
        }
    }
}

struct ContributorsView: View {
    private let contributors = Contributors.load()

    var body: some View {
        List {
            Section {
                ForEach(contributors, id: \.self) { Text(verbatim: $0) }
            } footer: {
                Text("Everyone with a commit in the app, server, design or Android repositories, most commits first. Generated from git history when this build was made.")
            }
        }
        .navigationTitle("Contributors")
    }
}

private struct LicencesView: View {
    var body: some View {
        List {
            LicenceRow(name: "Duongöndro for iOS", licence: "BSD-3-Clause", url: "https://github.com/Duongondro/duongondro-ios/blob/main/LICENSE")
            LicenceRow(name: "GRDB.swift", licence: "MIT", url: "https://github.com/groue/GRDB.swift/blob/master/LICENSE")
            LicenceRow(name: "IBM Plex Sans", licence: "SIL Open Font License 1.1", url: "https://github.com/IBM/plex/blob/master/LICENSE.txt")
        }
        .navigationTitle("Licences")
    }
}

private struct LicenceRow: View {
    let name: String
    let licence: String
    let url: String

    var body: some View {
        Link(destination: URL(string: url)!) {
            VStack(alignment: .leading) {
                Text(verbatim: name).foregroundStyle(.primary)
                Text(verbatim: licence).font(.footnote).foregroundStyle(Theme.muted)
            }
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

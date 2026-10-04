import SwiftUI
import DuongondroStore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    private let build = BuildIdentity.current

    var body: some View {
        List {
            Section("General") {
                Button {
                    // Per-app language lives in the system Settings app on iOS.
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    LabeledContent("Language", value: Locale.current.localizedString(forLanguageCode: Locale.current.language.languageCode?.identifier ?? "en") ?? "")
                }
                Picker("A mala counts as", selection: Binding(get: { model.preferences.malaSize }, set: { v in model.update { $0.malaSize = v } })) {
                    Text(verbatim: "100").tag(100)
                    Text(verbatim: "108").tag(108)
                }
            }
            Section("About") {
                LabeledContent("Version", value: build.version)
                if let url = build.commitURL {
                    Link(destination: url) {
                        LabeledContent("Source", value: build.shortRevision)
                    }
                } else {
                    LabeledContent("Source", value: build.shortRevision)
                }
            }
        }
        .navigationTitle("Settings")
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

    var commitURL: URL? {
        guard revision != "unknown", !dirty else { return nil }
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

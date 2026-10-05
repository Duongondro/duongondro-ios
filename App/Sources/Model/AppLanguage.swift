import Foundation
import DuongondroCore

/// The app's interface language (Settings → Language), as in CodeShare: System (follow
/// the phone, or iOS's per-app language) or one of our nine localizations.
///
/// Applied in two ways, and every string or formatted value must go through one of
/// them, so no screen ends up half in one language:
/// - SwiftUI: DuongondroApp sets `.environment(\.locale, …)` at the root, so `Text` and
///   `LocalizedStringKey` lookups follow it.
/// - Everything else (computed strings, notifications, formatting):
///   `String(localized: "…", bundle: .appLanguage, locale: .appLanguage)` and
///   `Locale.appLanguage`. Plain `String(localized:)` or `Locale.current` would follow
///   the phone instead.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case german = "de"
    case russian = "ru"
    case ukrainian = "uk"
    case polish = "pl"
    case czech = "cs"
    case slovak = "sk"
    case hungarian = "hu"
    case spanish = "es"

    /// UserDefaults key (`@AppStorage`).
    static let storageKey = "appLanguage"

    /// Our localizations, as in Localizable.xcstrings and the built .lproj folders.
    static let localizations = allCases.filter { $0 != .system }.map(\.rawValue)

    var id: String { rawValue }

    /// The language's name in itself, from the platform's CLDR data (design:
    /// Localisation › Language picker), never a hard-coded list; nil for System.
    var nativeName: String? {
        guard self != .system else { return nil }
        let name = Locale(identifier: rawValue).localizedString(forLanguageCode: rawValue) ?? rawValue
        return name.prefix(1).uppercased(with: Locale(identifier: rawValue)) + name.dropFirst()
    }

    /// `nativeName` tagged with its own language, so VoiceOver reads each in its voice.
    var spokenNativeName: AttributedString? {
        guard let nativeName else { return nil }
        var name = AttributedString(nativeName)
        name.languageIdentifier = rawValue
        return name
    }

    /// The localization in use: the chosen one, or for System whichever of ours iOS
    /// picked from the phone's languages.
    func localization(preferred: [String] = Bundle.main.preferredLocalizations) -> String {
        guard self == .system else { return rawValue }
        return preferred.first(where: Self.localizations.contains) ?? "en"
    }

    /// The language the strings are in, with the phone's region, so a screen never
    /// mixes languages and still uses the person's conventions. System on a phone in
    /// one of our languages is the phone's own locale, with its overrides.
    func locale(system: Locale = .autoupdatingCurrent,
                preferred: [String] = Bundle.main.preferredLocalizations) -> Locale {
        let language = localization(preferred: preferred)
        if self == .system, system.language.languageCode?.identifier == language { return system }
        guard let region = system.region?.identifier else { return Locale(identifier: language) }
        return Locale(identifier: "\(language)_\(region)")
    }

    /// Where to look strings up outside SwiftUI: the chosen language's .lproj, or the
    /// main bundle for System.
    func bundle(in main: Bundle = .main) -> Bundle {
        guard self != .system,
              let path = main.path(forResource: rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else { return main }
        return bundle
    }

    /// The stored choice, for code outside the view tree.
    static func stored(in defaults: UserDefaults = .standard) -> AppLanguage {
        defaults.string(forKey: storageKey).flatMap(AppLanguage.init(rawValue:)) ?? .system
    }
}

extension Bundle {
    /// The chosen interface language's strings.
    static var appLanguage: Bundle { AppLanguage.stored().bundle() }
}

extension Locale {
    /// The chosen interface language's locale, for formatting outside SwiftUI views.
    static var appLanguage: Locale { AppLanguage.stored().locale() }
}

extension Practice {
    /// A built-in practice's name as each country's practice books have it (table
    /// Practices.xcstrings, filled only from practitioners' sources; design:
    /// Localisation › Practice names). Falls back to the English name. Custom
    /// practices show what the person typed.
    var shownName: String { Self.shown(name, custom: isCustom) }

    var shownSecondName: String? { secondName.map { Self.shown($0, custom: isCustom) } }

    private static func shown(_ text: String, custom: Bool) -> String {
        guard !custom else { return text }
        return String(localized: String.LocalizationValue(text), table: "Practices", bundle: .appLanguage, locale: .appLanguage)
    }
}

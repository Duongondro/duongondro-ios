import DuongondroCore
import Foundation

extension Gender {
    /// UserDefaults key (`@AppStorage`) for this person's own gender, kept on the phone
    /// so it works without an account; absent or "" when not given.
    static let storageKey = "gender"

    static func stored(in defaults: UserDefaults = .standard) -> Gender? {
        defaults.string(forKey: storageKey).flatMap(Gender.init(rawValue:))
    }

    /// The table with this gender's forms (Male.xcstrings, Female.xcstrings); nil for
    /// the neutral forms, which are Localizable's own.
    fileprivate var table: String? {
        switch self {
        case .male: "Male"
        case .female: "Female"
        case .nonbinary: nil
        }
    }
}

/// Strings that conjugate for someone's grammatical gender (design: Localisation ›
/// Grammatical gender). Localizable holds the neutral forms ("Zapísal(a) som si ho");
/// Male and Female hold the same keys, filled only for languages that conjugate, and
/// win when the person gave that gender. Keys used here are marked manual in the
/// catalogs, since they are looked up by string, not extracted from `Text`.
enum Gendered {
    /// The string for `key`, conjugated for `gender`, formatted with `args`.
    static func string(_ key: String, for gender: Gender?, _ args: CVarArg...) -> String {
        format(key, for: gender, args)
    }

    /// The same, for the person using the phone.
    static func mine(_ key: String, _ args: CVarArg...) -> String {
        format(key, for: Gender.stored(), args)
    }

    private static func format(_ key: String, for gender: Gender?, _ args: [CVarArg]) -> String {
        var format = Bundle.appLanguage.localizedString(forKey: key, value: nil, table: nil)
        // Only the language's own folder: the main bundle would fall back to another
        // language's table where this one has no variant.
        let language = AppLanguage.stored().localization()
        if let table = gender?.table,
           let path = Bundle.main.path(forResource: language, ofType: "lproj"),
           let folder = Bundle(path: path) {
            let missing = "\u{1}"
            let variant = folder.localizedString(forKey: key, value: missing, table: table)
            if variant != missing { format = variant }
        }
        return args.isEmpty ? format : String(format: format, locale: .appLanguage, arguments: args)
    }
}

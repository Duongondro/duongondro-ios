import Foundation

/// A display name as the server reads it (duongondro-api names.Clean): white space
/// and invisible format characters (Cf: zero-width spaces, direction marks) trimmed
/// at both ends, and "" for a name with no letter, number or symbol left, which
/// would show as blank and so counts as none ("A friend").
public enum DisplayName {
    public static func clean(_ name: String) -> String {
        let scalars = name.unicodeScalars
        func blank(_ s: Unicode.Scalar) -> Bool { s.properties.isWhitespace || s.properties.generalCategory == .format }
        guard let start = scalars.firstIndex(where: { !blank($0) }),
              let end = scalars.lastIndex(where: { !blank($0) }) else { return "" }
        let trimmed = String(scalars[start...end])
        let visible = trimmed.unicodeScalars.contains { s in
            switch s.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber,
                 .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol: true
            default: false
            }
        }
        return visible ? trimmed : ""
    }
}

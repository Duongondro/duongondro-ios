import SwiftUI

/// All colours, radii and spacing. No literals in views.
enum Theme {
    static let accent = Color(light: 0x7A1F2E, dark: 0xE8909C)
    static let gold = Color(light: 0xD4A72C, dark: 0xE3B341)
    static let ground = Color(light: 0xF7F3F1, dark: 0x120A0C)
    static let card = Color(light: 0xFFFFFF, dark: 0x2B1C20)
    static let cardBorder = Color(light: 0xFFFFFF, dark: 0x46323A)
    static let muted = Color(light: 0x6B5A60, dark: 0xC2B2B7)

    /// Small, platform-specific corner radii (design: Look).
    enum Radius {
        static let small: CGFloat = 4
        static let card: CGFloat = 6
        static let bigButton: CGFloat = 8
        static let sheet: CGFloat = 12
    }
}

/// Headings use IBM Plex Sans (SemiBold, Bold; registered in project.yml as
/// UIAppFonts). Prose, buttons and labels keep the system font. Both scale with
/// Dynamic Type. Codes and recovery words use `.monospaced`, never a bundled face.
/// PostScript names are read from the font files: the SemiBold file's is `IBMPlexSans-SmBld`.
enum Typography {
    static let semiBold = "IBMPlexSans-SmBld"
    static let bold = "IBMPlexSans-Bold"

    static func heading(_ size: CGFloat, relativeTo style: Font.TextStyle = .title2) -> Font {
        .custom(semiBold, size: size, relativeTo: style)
    }

    static func headingBold(_ size: CGFloat, relativeTo style: Font.TextStyle = .title2) -> Font {
        .custom(bold, size: size, relativeTo: style)
    }

    static var largeTitle: Font { headingBold(34, relativeTo: .largeTitle) }
    static var title: Font { heading(22, relativeTo: .title2) }
    static var headline: Font { heading(17, relativeTo: .headline) }
    /// Big numbers such as the +mala button.
    static var count: Font { headingBold(40, relativeTo: .largeTitle) }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

extension View {
    /// Modern feedback where available, plain haptics on iOS 16. One layout per
    /// screen; availability lives in helpers like this, never in forked screens.
    @ViewBuilder
    func countTapFeedback<T: Equatable>(trigger: T) -> some View {
        if #available(iOS 17.0, *) {
            sensoryFeedback(.increase, trigger: trigger)
        } else {
            onChange(of: trigger) { _ in UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        }
    }

    func cardStyle() -> some View {
        padding(16)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).stroke(Theme.cardBorder, lineWidth: 1))
    }
}

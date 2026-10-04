import SwiftUI

/// All colours, radii and spacing. No literals in views.
enum Theme {
    /// Spacing steps, so views carry no layout literals either.
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 32
        /// Between the onboarding step dashes.
        static let dash: CGFloat = 6
    }

    static let accent = Color(light: 0x7A1F2E, dark: 0xE8909C)
    static let gold = Color(light: 0xD4A72C, dark: 0xE3B341)
    static let ground = Color(light: 0xF7F3F1, dark: 0x120A0C)
    static let card = Color(light: 0xFFFFFF, dark: 0x2B1C20)
    static let cardBorder = Color(light: 0xFFFFFF, dark: 0x46323A)
    static let muted = Color(light: 0x6B5A60, dark: 0xC2B2B7)
    /// Body text, and the darker secondary text of questions and forms.
    static let ink = Color(light: 0x22151A, dark: 0xF4ECEE)
    static let soft = Color(light: 0x4E3F44, dark: 0xC2B2B7)
    /// Hairlines between rows, segmented tracks and soft-filled buttons.
    static let line = Color(light: 0xEFE7E4, dark: 0x46323A)
    static let softFill = Color(light: 0xEFE7E4, dark: 0x3A2A2E)
    /// Input borders and the onboarding step dashes not yet reached.
    static let inputBorder = Color(light: 0xDCCDD1, dark: 0x46323A)
    /// Progress bars' track.
    static let track = Color(light: 0xF1E4E6, dark: 0x4A363B)
    /// The headline streak card on Today: solid burgundy, white text.
    static let hero = Color(light: 0x7A1F2E, dark: 0x4A1C27)
    static let heroInk = Color(light: 0xFFFFFF, dark: 0xF4ECEE)
    /// The Undo toast: inverted against the ground.
    static let toast = Color(light: 0x22151A, dark: 0xF4ECEE)
    static let toastInk = Color(light: 0xFFFFFF, dark: 0x22151A)
    static let toastTrack = Color(light: 0x5A4A4F, dark: 0xC9B9BD)
    /// Streak flames are gold, never orange.
    static let flame = Color(light: 0xC9952B, dark: 0xE3B341)
    /// Streak numbers as text: gold only reads on dark (2.7:1 on white), so burgundy in light mode.
    static let flameText = Color(light: 0x7A1F2E, dark: 0xE3B341)
    /// Welcome follows the system appearance: warm off-white with a burgundy
    /// button, or near-black burgundy with a gold one (design: Look).
    static let welcomeGround = Color(light: 0xF7F3F1, dark: 0x1E0C11)
    static let welcomePrimary = Color(light: 0x7A1F2E, dark: 0xD4A72C)
    static let welcomePrimaryInk = Color(light: 0xFFFFFF, dark: 0x2A1A06)
    static let welcomeTitle = Color(light: 0x7A1F2E, dark: 0xFFFFFF)
    static let welcomeSoft = Color(light: 0x4E3F44, dark: 0xE9D7DB)
    /// The "end-to-end encrypted" line: a text-safe gold on either ground.
    static let welcomeGoldText = Color(light: 0x7A5410, dark: 0xE3B341)
    static let welcomeOutline = Color(light: 0x7A1F2E, dark: 0x6E4A54)
    static let welcomeOutlineInk = Color(light: 0x7A1F2E, dark: 0xFFFFFF)
    /// Destructive actions and warnings.
    /// QR codes stay burgundy on white in both themes: a camera needs the contrast.
    static let qrInk = Color(light: 0x7A1F2E, dark: 0x7A1F2E)
    static let qrGround = Color(light: 0xFFFFFF, dark: 0xFFFFFF)
    static let destructive = Color(light: 0xB3261E, dark: 0xF2827A)
    /// Text and icons on an accent-filled button.
    static let onAccent = Color(light: 0xFFFFFF, dark: 0x120A0C)

    /// Fixed control sizes.
    enum Size {
        /// The +mala button's minimum height.
        static let bigButton: CGFloat = 88
        /// Full-width buttons in onboarding.
        static let button: CGFloat = 50
        /// Welcome's two door buttons, and its emblem.
        static let welcomeButton: CGFloat = 56
        static let emblem: CGFloat = 220
        /// The smallest tap target (Apple's 44 pt).
        static let minTap: CGFloat = 44
        /// Onboarding answers (Yes / Not yet) and its Continue.
        static let answer: CGFloat = 60
        static let field: CGFloat = 48
        static let secondary: CGFloat = 52
        /// About's side-by-side buttons.
        static let aboutButton: CGFloat = 48
        /// Progress bars: on Today's cards, and on the practice screen.
        static let barThin: CGFloat = 6
        static let barThick: CGFloat = 10
        /// The onboarding progress dashes.
        static let stepDash = CGSize(width: 28, height: 4)
        static let checkBadge: CGFloat = 30
        static let heroFlame: CGFloat = 34
        /// The entry part of a number field.
        static let numberField: CGFloat = 120
    }

    /// Small, platform-specific corner radii (design: Look).
    enum Radius {
        static let small: CGFloat = 4
        static let dash: CGFloat = 2
        static let card: CGFloat = 6
        static let bigButton: CGFloat = 8
        static let sheet: CGFloat = 12
        static let bar: CGFloat = 3
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
    /// Lists and forms on the warm ground with card-coloured rows.
    func themedList() -> some View {
        scrollContentBackground(.hidden)
            .background(Theme.ground.ignoresSafeArea())
    }

    /// Card-coloured rows; apply to a Group around a list's sections.
    func themedRows() -> some View {
        listRowBackground(Theme.card)
    }

    func cardStyle() -> some View {
        padding(Theme.Space.l)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).stroke(Theme.cardBorder, lineWidth: 1))
    }
}

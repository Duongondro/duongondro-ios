import Foundation

/// Where a practice sits on the path. The path only gates ngöndro (after short
/// refuge) and the 8th Karmapa (after ngöndro); short refuge itself stays open to
/// everyone, since returning to it is nobody's business but the practitioner's.
public enum PracticeGroup: String, Codable, Sendable {
    case beforeNgondro
    case ngondro
    case afterNgondro
    case anyTime
}

/// A practice in the catalogue. The catalogue is data, so new practices ship
/// without migrations and users can add their own.
public struct Practice: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    /// Shown first: the Tibetan or Sanskrit name where practitioners use one.
    public var name: String
    /// The second line, usually the English name.
    public var secondName: String?
    public var group: PracticeGroup
    /// Count target per round; nil for open-ended practices.
    public var target: Int?
    /// Whether the practice may be tracked by streak alone (never for ngöndro).
    public var streakOnlyAllowed: Bool
    /// Per-practice mala size; nil means the global default.
    public var malaSize: Int?
    public var isCustom: Bool

    public init(id: String, name: String, secondName: String? = nil, group: PracticeGroup,
                target: Int?, streakOnlyAllowed: Bool, malaSize: Int? = nil, isCustom: Bool = false) {
        self.id = id
        self.name = name
        self.secondName = secondName
        self.group = group
        self.target = target
        self.streakOnlyAllowed = group == .ngondro ? false : streakOnlyAllowed
        self.malaSize = malaSize
        self.isCustom = isCustom
    }

    public func effectiveMalaSize(default globalDefault: Int) -> Int { malaSize ?? globalDefault }

    /// Practices without a target (the Karmapa meditations) start as streak-only.
    public var streakOnlyByDefault: Bool { streakOnlyAllowed && target == nil }
}

public enum Catalogue {
    public static let builtIn: [Practice] = [
        Practice(id: "short-refuge", name: "Short refuge", group: .beforeNgondro, target: 11_111, streakOnlyAllowed: false),
        Practice(id: "refuge", name: "Refuge and the Enlightened Attitude", secondName: "Prostrations", group: .ngondro, target: 111_111, streakOnlyAllowed: false),
        Practice(id: "dorje-sempa", name: "Dorje Sempa", secondName: "Diamond Mind", group: .ngondro, target: 111_111, streakOnlyAllowed: false),
        Practice(id: "mandala", name: "Mandala offering", group: .ngondro, target: 111_111, streakOnlyAllowed: false),
        Practice(id: "guru-yoga", name: "Meditation on the Lama", secondName: "Guru Yoga", group: .ngondro, target: 111_111, streakOnlyAllowed: false),
        Practice(id: "8th-karmapa", name: "8th Karmapa Meditation", group: .afterNgondro, target: nil, streakOnlyAllowed: true),
        Practice(id: "16th-karmapa", name: "Meditation on the 16th Karmapa", group: .anyTime, target: nil, streakOnlyAllowed: true),
        Practice(id: "chenrezig", name: "Chenrezig", secondName: "Loving Eyes", group: .anyTime, target: 1_000_000, streakOnlyAllowed: true),
        Practice(id: "amitabha", name: "Amitabha", secondName: "Meditation on the Buddha of Limitless Light", group: .anyTime, target: 500_000, streakOnlyAllowed: true),
    ]

    /// Practices available given the onboarding answers.
    public static func available(finishedNgondro: Bool, finishedShortRefuge: Bool) -> [Practice] {
        builtIn.filter { p in
            switch p.group {
            case .anyTime: return true
            case .afterNgondro: return finishedNgondro
            case .ngondro: return finishedNgondro || finishedShortRefuge
            case .beforeNgondro: return true
            }
        }
    }
}

/// Rounds of a counted practice: personal, never published.
public struct RoundProgress: Equatable, Sendable {
    public let round: Int          // 1-based
    public let inRound: Int        // count within the current round
    public let lifetime: Int

    public init(lifetime: Int, target: Int) {
        precondition(target > 0)
        self.lifetime = lifetime
        self.round = lifetime / target + 1
        self.inRound = lifetime % target
    }
}

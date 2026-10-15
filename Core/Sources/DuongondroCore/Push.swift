import Foundation

/// The server's push loc-keys (duongondro-api internal/service/nudges.go), and the
/// phone's own variants of them (design: Social › Nudges, Localisation › Localised
/// pushes). Every key is a string in Localizable.xcstrings in all nine languages: the
/// system renders the server's keys from there when the notification service
/// extension does not run, so their strings never name the practice (the server sends
/// its id, and Discreet notifications may be on): they leave that argument unused.
public enum PushKey: String, CaseIterable, Sendable {
    // Sent by the server, in the variant for the sender's grammatical gender.
    /// Args: name, practice id (unused in the string), day count.
    case friendDone = "FRIEND_DONE"
    case friendDoneMale = "FRIEND_DONE_MALE"
    case friendDoneFemale = "FRIEND_DONE_FEMALE"
    /// Args: name.
    case poke = "POKE"
    case pokeMale = "POKE_MALE"
    case pokeFemale = "POKE_FEMALE"
    /// For a sender without a display name: FRIEND_DONE without the name. Args:
    /// practice id (unused in the string), day count.
    case friendDoneUnnamed = "FRIEND_DONE_UNNAMED"
    case friendDoneUnnamedMale = "FRIEND_DONE_UNNAMED_MALE"
    case friendDoneUnnamedFemale = "FRIEND_DONE_UNNAMED_FEMALE"
    /// POKE for a sender without a display name. No args.
    case pokeUnnamed = "POKE_UNNAMED"
    case pokeUnnamedMale = "POKE_UNNAMED_MALE"
    case pokeUnnamedFemale = "POKE_UNNAMED_FEMALE"
    /// Args: practice id (unused in the string), day count.
    case streakAtRisk = "STREAK_AT_RISK"

    // The phone's own, which the extension shows in place of the server's key.
    /// FRIEND_DONE naming the practice: args name, practice name, day count.
    case friendDoneNamed = "FRIEND_DONE_NAMED"
    case friendDoneNamedMale = "FRIEND_DONE_NAMED_MALE"
    case friendDoneNamedFemale = "FRIEND_DONE_NAMED_FEMALE"
    /// FRIEND_DONE_UNNAMED naming the practice: args practice name, day count.
    case friendDoneUnnamedNamed = "FRIEND_DONE_UNNAMED_NAMED"
    case friendDoneUnnamedNamedMale = "FRIEND_DONE_UNNAMED_NAMED_MALE"
    case friendDoneUnnamedNamedFemale = "FRIEND_DONE_UNNAMED_NAMED_FEMALE"
    /// STREAK_AT_RISK naming the practice: args practice name, day count.
    case streakAtRiskNamed = "STREAK_AT_RISK_NAMED"
    /// Discreet notifications: no practice names on the lock screen. No args.
    case friendDoneDiscreet = "FRIEND_DONE_DISCREET"
    case streakAtRiskDiscreet = "STREAK_AT_RISK_DISCREET"

    /// The keys the server sends.
    public static let server: [PushKey] = [.friendDone, .friendDoneMale, .friendDoneFemale,
                                           .poke, .pokeMale, .pokeFemale,
                                           .friendDoneUnnamed, .friendDoneUnnamedMale, .friendDoneUnnamedFemale,
                                           .pokeUnnamed, .pokeUnnamedMale, .pokeUnnamedFemale, .streakAtRisk]

    /// How many arguments the key is formatted with (loc-args, or the extension's).
    public var argumentCount: Int {
        switch self {
        case .friendDone, .friendDoneMale, .friendDoneFemale,
             .friendDoneNamed, .friendDoneNamedMale, .friendDoneNamedFemale: 3
        case .poke, .pokeMale, .pokeFemale: 1
        case .streakAtRisk, .streakAtRiskNamed,
             .friendDoneUnnamed, .friendDoneUnnamedMale, .friendDoneUnnamedFemale,
             .friendDoneUnnamedNamed, .friendDoneUnnamedNamedMale, .friendDoneUnnamedNamedFemale: 2
        case .friendDoneDiscreet, .streakAtRiskDiscreet, .pokeUnnamed, .pokeUnnamedMale, .pokeUnnamedFemale: 0
        }
    }

    /// The arguments its strings use, %1$@ … %n$@: all but the practice id for the
    /// server's keys. Foundation formats around an unused positional object argument.
    public var usedArguments: Set<Int> {
        switch self {
        case .friendDone, .friendDoneMale, .friendDoneFemale: [1, 3]
        case .streakAtRisk, .friendDoneUnnamed, .friendDoneUnnamedMale, .friendDoneUnnamedFemale: [2]
        default: Set((0..<argumentCount).map { $0 + 1 })
        }
    }

    /// The variant naming the practice, keeping the sender's gender.
    var named: PushKey? {
        switch self {
        case .friendDone: .friendDoneNamed
        case .friendDoneMale: .friendDoneNamedMale
        case .friendDoneFemale: .friendDoneNamedFemale
        case .friendDoneUnnamed: .friendDoneUnnamedNamed
        case .friendDoneUnnamedMale: .friendDoneUnnamedNamedMale
        case .friendDoneUnnamedFemale: .friendDoneUnnamedNamedFemale
        case .streakAtRisk: .streakAtRiskNamed
        default: nil
        }
    }

    /// What the extension shows when it cannot render a server key that may name a
    /// practice: the discreet text, so a failure never shows more than Discreet would.
    public var failSafe: PushKey? {
        switch self {
        case .friendDone, .friendDoneMale, .friendDoneFemale,
             .friendDoneUnnamed, .friendDoneUnnamedMale, .friendDoneUnnamedFemale: .friendDoneDiscreet
        case .streakAtRisk: .streakAtRiskDiscreet
        default: nil
        }
    }

    /// The key without the name, for a named key whose name came empty (a server
    /// from before the UNNAMED keys): "A friend" rather than a sentence with a gap.
    var unnamed: PushKey? {
        switch self {
        case .friendDone: .friendDoneUnnamed
        case .friendDoneMale: .friendDoneUnnamedMale
        case .friendDoneFemale: .friendDoneUnnamedFemale
        case .poke: .pokeUnnamed
        case .pokeMale: .pokeUnnamedMale
        case .pokeFemale: .pokeUnnamedFemale
        default: nil
        }
    }
}

/// A server push rendered in the phone's language: the key to look up and the
/// arguments to format it with, practice ids replaced by names and day counts
/// formatted for the locale.
public struct PushText: Equatable, Sendable {
    public let key: PushKey
    public let arguments: [String]

    /// `practiceName` names a practice id (nil when this phone has no name for it);
    /// `number` formats a day count. Nil for a key this version does not know, or
    /// arguments of the wrong shape: the system's own rendering then stands.
    public static func render(locKey: String, args: [String], discreet: Bool,
                              practiceName: (String) -> String?, number: (Int) -> String) -> PushText? {
        guard var key = PushKey(rawValue: locKey), PushKey.server.contains(key),
              args.count == key.argumentCount else { return nil }
        var args = args
        if let unnamed = key.unnamed, DisplayName.clean(args[0]).isEmpty {
            key = unnamed
            args.removeFirst()
        }
        func day(_ s: String) -> String { Int(s).map(number) ?? s }
        switch key {
        case .friendDone, .friendDoneMale, .friendDoneFemale:
            // Lock screens are seen by others: no practice and no name (design:
            // Social › Nudges).
            if discreet { return PushText(key: .friendDoneDiscreet, arguments: []) }
            // A practice this phone has no name for (a friend's own): the server's
            // key, whose string leaves it out.
            guard let name = practiceName(args[1]) else {
                return PushText(key: key, arguments: [args[0], args[1], day(args[2])])
            }
            return PushText(key: key.named!, arguments: [args[0], name, day(args[2])])
        case .friendDoneUnnamed, .friendDoneUnnamedMale, .friendDoneUnnamedFemale:
            if discreet { return PushText(key: .friendDoneDiscreet, arguments: []) }
            guard let name = practiceName(args[0]) else {
                return PushText(key: key, arguments: [args[0], day(args[1])])
            }
            return PushText(key: key.named!, arguments: [name, day(args[1])])
        case .streakAtRisk:
            if discreet { return PushText(key: .streakAtRiskDiscreet, arguments: []) }
            guard let name = practiceName(args[0]) else {
                return PushText(key: key, arguments: [args[0], day(args[1])])
            }
            return PushText(key: key.named!, arguments: [name, day(args[1])])
        default:
            return PushText(key: key, arguments: args)
        }
    }

    /// The text, from the key's format string in the chosen language.
    public func string(format: String, locale: Locale) -> String {
        arguments.isEmpty ? format : String(format: format, locale: locale, arguments: arguments.map { $0 as CVarArg })
    }
}

/// Where tapping a push leads.
public enum PushRoute: Equatable, Sendable {
    /// A friend's page: done today and pokes, whose thread is the sender's user id.
    case friend(UUID)
    /// Today, where the practice whose streak is at risk is.
    case today

    /// From the notification's `aps` dictionary: its loc-key and thread-id.
    public init?(userInfo: [AnyHashable: Any]) {
        guard let aps = userInfo["aps"] as? [String: Any],
              let alert = aps["alert"] as? [String: Any],
              let locKey = alert["loc-key"] as? String,
              let key = PushKey(rawValue: locKey)
        else { return nil }
        switch key {
        case .streakAtRisk, .streakAtRiskDiscreet:
            self = .today
        default:
            guard let thread = aps["thread-id"] as? String, let friend = UUID(uuidString: thread) else { return nil }
            self = .friend(friend)
        }
    }
}

/// The APNs device token as the API takes it: lower-case hexadecimal.
public enum PushToken {
    public static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }
}

/// Which APNs environment a token belongs to, as the API names it: tokens from a
/// development-signed app only work against the sandbox. Decided by how this copy of
/// the app was signed rather than by the build configuration: `make device` installs a
/// Release build with a development profile, whose tokens are sandbox tokens.
public enum PushPlatform {
    public static let production = "apns"
    public static let sandbox = "apns-sandbox"

    /// `profile` is the app's embedded.mobileprovision (absent from App Store and
    /// TestFlight builds, which are production); the simulator is always the sandbox.
    public static func of(profile: Data?, simulator: Bool) -> String {
        if simulator { return sandbox }
        guard let profile else { return production }
        return apsEnvironment(inProfile: profile) == "production" ? production : sandbox
    }

    /// The aps-environment entitlement of a provisioning profile: a property list
    /// inside a CMS envelope, read without verifying the signature (the system has).
    public static func apsEnvironment(inProfile data: Data) -> String? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil),
              let entitlements = (plist as? [String: Any])?["Entitlements"] as? [String: Any]
        else { return nil }
        return entitlements["aps-environment"] as? String
    }
}

/// What the app shares with its notification service extension, which renders pushes
/// but cannot open the database: UserDefaults in the app group, written by the app.
public enum PushShared {
    public static let appGroup = "group.app.duongondro.ios"
    /// Settings › Discreet notifications; absent means discreet.
    public static let discreet = "discreetNotifications"
    /// The language chosen in Settings › Language ("pl"); absent for System, when the
    /// extension follows the phone.
    public static let localization = "localization"
    /// The person's own practices' names by id, for STREAK_AT_RISK of a custom practice.
    public static let practiceNames = "practiceNames"
}

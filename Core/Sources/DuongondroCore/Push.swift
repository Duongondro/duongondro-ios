import Foundation

/// The server's push loc-keys (duongondro-api internal/service/nudges.go), and the
/// phone's own variants of them (design: Social › Nudges, Localisation › Localised
/// pushes). Every key is a string in Localizable.xcstrings in all nine languages: the
/// system renders it from there when the notification service extension does not run.
public enum PushKey: String, CaseIterable, Sendable {
    // Sent by the server, in the variant for the sender's grammatical gender.
    /// Args: name, practice id, day count.
    case friendDone = "FRIEND_DONE"
    case friendDoneMale = "FRIEND_DONE_MALE"
    case friendDoneFemale = "FRIEND_DONE_FEMALE"
    /// Args: name.
    case poke = "POKE"
    case pokeMale = "POKE_MALE"
    case pokeFemale = "POKE_FEMALE"
    /// Args: practice id, day count.
    case streakAtRisk = "STREAK_AT_RISK"

    // The phone's own: shown in place of the server's key.
    /// FRIEND_DONE for a practice this phone has no name for (a friend's own):
    /// args name, day count.
    case friendDoneOwn = "FRIEND_DONE_OWN"
    case friendDoneOwnMale = "FRIEND_DONE_OWN_MALE"
    case friendDoneOwnFemale = "FRIEND_DONE_OWN_FEMALE"
    /// Discreet notifications: no practice names on the lock screen. No args.
    case friendDoneDiscreet = "FRIEND_DONE_DISCREET"
    case streakAtRiskDiscreet = "STREAK_AT_RISK_DISCREET"

    /// The keys the server sends.
    public static let server: [PushKey] = [.friendDone, .friendDoneMale, .friendDoneFemale,
                                           .poke, .pokeMale, .pokeFemale, .streakAtRisk]

    /// How many arguments the key's format string takes (%1$@ … %n$@).
    public var argumentCount: Int {
        switch self {
        case .friendDone, .friendDoneMale, .friendDoneFemale: 3
        case .poke, .pokeMale, .pokeFemale: 1
        case .streakAtRisk, .friendDoneOwn, .friendDoneOwnMale, .friendDoneOwnFemale: 2
        case .friendDoneDiscreet, .streakAtRiskDiscreet: 0
        }
    }

    var isFriendDone: Bool { [.friendDone, .friendDoneMale, .friendDoneFemale].contains(self) }

    /// The variant without the practice, keeping the sender's gender.
    var own: PushKey? {
        switch self {
        case .friendDone: .friendDoneOwn
        case .friendDoneMale: .friendDoneOwnMale
        case .friendDoneFemale: .friendDoneOwnFemale
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
        guard let key = PushKey(rawValue: locKey), PushKey.server.contains(key),
              args.count == key.argumentCount else { return nil }
        func day(_ s: String) -> String { Int(s).map(number) ?? s }
        switch key {
        case .friendDone, .friendDoneMale, .friendDoneFemale:
            // Lock screens are seen by others: no practice and no name (design:
            // Social › Nudges).
            if discreet { return PushText(key: .friendDoneDiscreet, arguments: []) }
            guard let name = practiceName(args[1]) else {
                return PushText(key: key.own!, arguments: [args[0], day(args[2])])
            }
            return PushText(key: key, arguments: [args[0], name, day(args[2])])
        case .streakAtRisk:
            guard !discreet, let name = practiceName(args[0]) else {
                return PushText(key: .streakAtRiskDiscreet, arguments: [])
            }
            return PushText(key: key, arguments: [name, day(args[1])])
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
    /// Settings › Discreet notifications.
    public static let discreet = "discreetNotifications"
    /// The localization the app shows (Settings › Language, resolved): "pl".
    public static let localization = "localization"
    /// The person's own practices' names by id, for STREAK_AT_RISK of a custom practice.
    public static let practiceNames = "practiceNames"
}

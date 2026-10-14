import DuongondroAPI
import DuongondroCrypto
import Foundation

/// The code a sign-up starts from (design: Onboarding v2, Invitation): 24
/// Crockford characters for a friend's invitation (the link's 8-character id,
/// then its 16-character secret), 16 for an admission code. The length tells
/// them apart; people only ever see "invitation code".
public enum Invitation: Equatable, Sendable {
    case invite(InviteLink)
    case admission(String)

    public static let inviteLength = 24
    public static let admissionLength = 16

    /// Reads a typed or opened code; nil for any other length or a character
    /// outside the alphabet.
    public static func parse(_ code: String) -> Invitation? {
        let cleaned = CodeEntry.normalise(code, maxLength: .max)
        switch cleaned.count {
        case inviteLength:
            guard let id = Crockford.decode(String(cleaned.prefix(8))),
                  let secret = Crockford.decode(String(cleaned.dropFirst(8))), secret.count == 10 else { return nil }
            return .invite(InviteLink(kind: .invite, id: Crockford.encode(id), secret: secret))
        case admissionLength:
            guard Crockford.decode(cleaned) != nil else { return nil }
            return .admission(cleaned)
        default:
            return nil
        }
    }

    /// The 24 characters of an opened link, for the invitation step's field.
    public static func code(of link: InviteLink) -> String { link.id + Crockford.encode(link.secret) }

    /// What the server checks: for an invite, only auth derived from the secret.
    public var proof: SignUpProof {
        switch self {
        case .invite(let link): .invite(id: link.id, auth: E2EE.inviteKeys(secret: link.secret).auth)
        case .admission(let code): .admission(code)
        }
    }
}

/// Typing rules for the codes people copy by hand: Crockford base32, forgiving
/// about case, look-alikes and spacing.
public enum CodeEntry {
    /// The magic link's code.
    public static let signInLength = 8
    public static let recoveryLength = 26
    public static let group = 4

    /// Upper case, O read as 0 and I or L as 1, everything but letters and digits
    /// dropped. A pasted link keeps only what follows its last slash or equals sign.
    public static func normalise(_ raw: String, maxLength: Int) -> String {
        var tail = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        if let slash = tail.lastIndex(of: "/") { tail = tail[tail.index(after: slash)...] }
        if let equals = tail.lastIndex(of: "=") { tail = tail[tail.index(after: equals)...] }
        var out = ""
        for c in tail.uppercased() {
            switch c {
            case "O": out.append("0")
            case "I", "L": out.append("1")
            case "0"..."9", "A"..."Z": out.append(c)
            default: break
            }
            if out.count == maxLength { break }
        }
        return out
    }

    /// "7K2MQ9XA" as "7K2M Q9XA".
    public static func grouped(_ code: String) -> String {
        stride(from: 0, to: code.count, by: group).map { i in
            let start = code.index(code.startIndex, offsetBy: i)
            return String(code[start..<(code.index(start, offsetBy: group, limitedBy: code.endIndex) ?? code.endIndex)])
        }.joined(separator: " ")
    }
}

/// A link that opens the app (Universal Links on duongondro.app): an invitation
/// or friend code, `/I/<id>#<secret>`, or a magic link, `/m#<token>`. The secret
/// and the token travel in the fragment, which never reaches a server.
public enum AppLink: Equatable, Sendable {
    case invite(InviteLink)
    case magic(token: String)

    public init?(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "duongondro.app" else { return nil }
        let path = components.path.lowercased()
        if path == "/m" || path == "/m/" {
            guard let token = components.fragment, !token.isEmpty, token.count <= 128 else { return nil }
            self = .magic(token: token)
        } else if let link = InviteLink(url.absoluteString) {
            self = .invite(link)
        } else {
            return nil
        }
    }
}

/// When this phone last asked for a magic link: an opened link is redeemed only
/// within its 15 minutes, so a link someone else sent cannot sign this phone in
/// to their account (and upload its practice there).
public struct LinkWindow: Equatable, Sendable {
    public static let lifetime: TimeInterval = 15 * 60
    public private(set) var requestedAt: Date?

    public init(requestedAt: Date? = nil) { self.requestedAt = requestedAt }

    public mutating func requested(at now: Date = Date()) { requestedAt = now }
    public mutating func close() { requestedAt = nil }

    /// Whether an opened link may be redeemed now.
    public func expects(at now: Date = Date()) -> Bool {
        guard let requestedAt else { return false }
        let age = now.timeIntervalSince(requestedAt)
        return age >= 0 && age <= Self.lifetime
    }
}

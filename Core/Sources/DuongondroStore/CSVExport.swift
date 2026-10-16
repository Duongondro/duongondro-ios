import Foundation
import DuongondroCore

/// RFC 4180 tables: UTF-8, a header row, CRLF line ends, fields quoted when they
/// hold a comma, a quote or a line break. A text cell a spreadsheet would run as a
/// formula (starting with `=`, `+`, `-`, `@`, tab or CR) gets a leading `'`
/// (design: Data export and deletion › Export). Numbers are never guarded or
/// formatted: they are typed cells, written as plain digits.
public enum CSV {
    public enum Cell: Equatable, Sendable {
        case text(String)
        case int(Int)
        case bool(Bool)
        case empty
    }

    static let formulaStarts: Set<Character> = ["=", "+", "-", "@", "\t", "\r"]

    /// One field as written: guarded, then quoted where RFC 4180 needs it.
    public static func field(_ cell: Cell) -> String {
        switch cell {
        case .int(let n): return String(n)
        case .bool(let b): return b ? "true" : "false"
        case .empty: return ""
        case .text(var s):
            // "\r\n" is one Character in Swift, so look at the first scalar.
            if let first = s.unicodeScalars.first, formulaStarts.contains(Character(first)) { s = "'" + s }
            guard s.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return s }
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
    }

    /// The table's bytes: the header row, then every row, each ended by CRLF. With
    /// a UTF-8 byte order mark, so spreadsheets do not read Cyrillic or Polish as Latin-1.
    public static func table(header: [String], rows: [[Cell]]) -> Data {
        var out = "\u{FEFF}"
        for row in [header.map(Cell.text)] + rows {
            out += row.map(field).joined(separator: ",") + "\r\n"
        }
        return Data(out.utf8)
    }
}

/// The CSV export: a ZIP of tables, one per kind of data. Headers come in the
/// app's language through `header`; the file names stay English.
public enum CSVExport {
    public enum Column: String, CaseIterable, Sendable {
        // practices
        case practice, secondName, target, malaSize, streakOnly, archived
        // sessions
        case dayCounted, start, timeZone, count, round, chosenDay
        // friends
        case displayName, friendsSince
        // invites
        case code, kind, created, expires, revoked, redemptions
        // blocks and reports
        case person, reason
        // devices
        case device, keyStorage

        /// The English header, for tests and as a fallback.
        public var english: String {
            switch self {
            case .practice: "Practice"
            case .secondName: "Second name"
            case .target: "Target"
            case .malaSize: "Mala size"
            case .streakOnly: "Streak only"
            case .archived: "Archived"
            case .dayCounted: "Day counted"
            case .start: "Start"
            case .timeZone: "Time zone"
            case .count: "Count"
            case .round: "Round"
            case .chosenDay: "Day chosen after midnight"
            case .displayName: "Display name"
            case .friendsSince: "Friends since"
            case .code: "Friendship code"
            case .kind: "Made or redeemed"
            case .created: "Created"
            case .expires: "Expires"
            case .revoked: "Revoked"
            case .redemptions: "Redeemed"
            case .person: "Person"
            case .reason: "Reason"
            case .device: "Device"
            case .keyStorage: "Key storage"
            }
        }
    }

    public struct Table: Sendable {
        public var name: String
        public var columns: [Column]
        public var rows: [[CSV.Cell]]
    }

    /// The tables of `content`. Friends need an account; invites, blocks, reports
    /// and devices exist only on the server, so they are left out without its part.
    /// `practiceName` gives a practice's names as the app shows them.
    public static func tables(_ content: ExportContent,
                              practiceName: (Practice) -> (name: String, second: String?) = { ($0.name, $0.secondName) })
        -> [Table] {
        let zone = content.timeZone
        func time(_ d: Date?, in tz: TimeZone? = nil) -> CSV.Cell { d.map { .text(stamp($0, in: tz ?? zone)) } ?? .empty }
        func opt(_ n: Int?) -> CSV.Cell { n.map(CSV.Cell.int) ?? .empty }
        let names = Dictionary(content.practices.map { ($0.id, practiceName($0.practice)) }, uniquingKeysWith: { a, _ in a })

        var out = [
            Table(name: "practices", columns: [.practice, .secondName, .target, .malaSize, .streakOnly, .archived],
                  rows: content.practices.map { p in
                      let n = practiceName(p.practice)
                      return [.text(n.name), n.second.map(CSV.Cell.text) ?? .empty, opt(p.practice.target),
                              .int(p.malaSize), .bool(p.streakOnly), .bool(p.archived)]
                  }),
            Table(name: "sessions", columns: [.practice, .dayCounted, .start, .timeZone, .count, .round, .chosenDay],
                  rows: content.sessions.map { x in
                      [.text(names[x.practiceID]?.name ?? x.practiceID), .text(x.day.description), time(x.start, in: x.timeZone),
                       .text(x.timeZone.identifier), .int(x.count), opt(x.round), x.dayChosen ? .text(x.day.description) : .empty]
                  }),
        ]
        if content.serverPart != .local {
            out.append(Table(name: "friends", columns: [.displayName, .friendsSince],
                             rows: content.friends.map { [.text($0.displayName), time($0.since)] }))
        }
        if content.serverPart == .included {
            out += [
                Table(name: "invites", columns: [.code, .kind, .created, .expires, .revoked, .redemptions],
                      rows: content.invites.map { i in
                          [.text(i.id), .text(i.made ? "made" : "redeemed"), time(i.createdAt), time(i.expiresAt),
                           time(i.revokedAt), i.made ? .int(i.redemptions) : .empty]
                      }),
                Table(name: "blocks", columns: [.person, .created],
                      rows: content.blocks.map { [.text($0.who), time($0.createdAt)] }),
                Table(name: "reports", columns: [.person, .reason, .created],
                      rows: content.reports.map { [.text($0.about), .text($0.reason), time($0.createdAt)] }),
                Table(name: "devices", columns: [.device, .keyStorage, .created],
                      rows: (content.account?.devices ?? []).map { [.text($0.id), .text($0.tier), time($0.createdAt)] }),
            ]
        }
        return out
    }

    /// The ZIP: one `<name>.csv` per table.
    public static func zip(_ content: ExportContent, header: (Column) -> String = { $0.english },
                           practiceName: (Practice) -> (name: String, second: String?) = { ($0.name, $0.secondName) }) -> Data {
        var zip = ZipWriter()
        for t in tables(content, practiceName: practiceName) {
            zip.add("\(t.name).csv", CSV.table(header: t.columns.map(header), rows: t.rows), modified: content.exportedAt)
        }
        return zip.finish()
    }

    /// "2026-10-13 06:40:00", local to `timeZone`: a form spreadsheets read as a date.
    static func stamp(_ date: Date, in timeZone: TimeZone) -> String {
        let c = Calendar.gregorian(in: timeZone).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }
}

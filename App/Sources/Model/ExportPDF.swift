import SwiftUI
import UIKit
import DuongondroCore
import DuongondroStore

/// The PDF export (design: Data export and deletion › Export), drawn as CodeShare's
/// ExportPDF is: A4, IBM Plex Sans for headings and figures with tabular numbers,
/// the light theme's tokens for print. A header with the title, export time and
/// build, a footer with duongondro.app/privacy and "Page n of N"; sections Account,
/// Practices, every session by practice and day, Friends, and what the server
/// keeps. Pages are broken by `PageFlow` (Core), so table headers repeat and a
/// day's sessions stay together where they fit. Strings come from Export.xcstrings
/// in the app's language; numbers and dates in its locale.
struct ExportPDF {
    let content: ExportContent
    var locale: Locale = .appLanguage
    var bundle: Bundle = .appLanguage
    /// "0.4 (123) · 3f9c2e1".
    var build: String

    static let page = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
    private static let side: CGFloat = 44
    private static let top: CGFloat = 40
    /// Where the content starts and ends on every page.
    private static let contentTop: CGFloat = 100
    private static let contentBottom: CGFloat = page.height - 52
    private var width: CGFloat { Self.page.width - 2 * Self.side }

    // Theme tokens, light: a PDF is printed on white.
    private static func light(_ color: Color) -> UIColor {
        UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
    }
    private static let ink = light(Theme.ink), muted = light(Theme.muted), accent = light(Theme.accent)
    private static let line = light(Theme.line), band = light(Theme.ground)

    /// IBM Plex Sans with tabular figures.
    private static func plex(_ name: String, _ size: CGFloat) -> UIFont {
        let base = UIFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: .semibold)
        return UIFont(descriptor: base.fontDescriptor.addingAttributes([.featureSettings: [[
            UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
            UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector,
        ]]]), size: size)
    }
    private static let titleFont = plex(Typography.bold, 22)
    private static let sectionFont = plex(Typography.semiBold, 13)
    private static let figureFont = plex(Typography.semiBold, 9.5)
    private static let bodyFont = UIFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
    private static let labelFont = UIFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .semibold)
    private static let smallFont = UIFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular)

    private func l(_ key: String.LocalizationValue) -> String {
        String(localized: key, table: "Export", bundle: bundle, locale: locale)
    }

    // MARK: - Blocks

    private struct Column {
        let title: String
        let weight: CGFloat
        var right = false
        /// Figures: IBM Plex Sans SemiBold.
        var figure = false
    }

    private struct Table {
        let columns: [Column]
        /// "Dorje Sempa (continued)", above the header where the table carries on on a new page.
        var continued: String
        /// The header band, as tall as its longest title wraps.
        var height: CGFloat = 18
        /// The continuation line above it.
        var continuedHeight: CGFloat = 0
    }

    private struct Item {
        var block: PageFlow.Block
        var draw: (CGFloat) -> Void
    }

    /// The PDF's bytes.
    func data() -> Data {
        var items: [Item] = []
        var tables: [Int: Table] = [:]
        build(&items, &tables)
        let available = Double(Self.contentBottom - Self.contentTop)
        let headerHeights = tables.mapValues { Double($0.continuedHeight + $0.height) }
        let pages = PageFlow.paginate(items.map(\.block), available: available, headers: headerHeights)

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: l("Duongöndro: your data"),
            kCGPDFContextCreator as String: "Duongöndro \(build)",
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: Self.page, format: format)
        return renderer.pdfData { context in
            for (n, placements) in pages.enumerated() {
                context.beginPage()
                drawFrame(context.cgContext, page: n + 1, of: pages.count)
                for p in placements {
                    switch p {
                    case let .block(i, y): items[i].draw(Self.contentTop + CGFloat(y))
                    case let .header(t, y): if let table = tables[t] { drawHeader(table, at: Self.contentTop + CGFloat(y), continued: true) }
                    }
                }
            }
        }
    }

    // MARK: - Drawing primitives

    @discardableResult
    private func text(_ string: String, _ font: UIFont, _ color: UIColor, x: CGFloat, y: CGFloat, w: CGFloat,
                      align: NSTextAlignment = .left, draw: Bool = true) -> CGFloat {
        let attributed = NSAttributedString(string: string, attributes: Self.attributes(font, color, align))
        return Self.render(attributed, x: x, y: y, w: w, draw: draw)
    }

    private static func attributes(_ font: UIFont, _ color: UIColor, _ align: NSTextAlignment) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.alignment = align
        style.lineHeightMultiple = 1.15
        return [.font: font, .foregroundColor: color, .paragraphStyle: style]
    }

    private static func render(_ attributed: NSAttributedString, x: CGFloat, y: CGFloat, w: CGFloat, draw: Bool) -> CGFloat {
        let options: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let height = ceil(attributed.boundingRect(with: CGSize(width: w, height: 10_000), options: options, context: nil).height)
        if draw { attributed.draw(with: CGRect(x: x, y: y, width: w, height: height), options: options, context: nil) }
        return height
    }

    private func rule(_ y: CGFloat, color: UIColor, width lineWidth: CGFloat) {
        guard let cg = UIGraphicsGetCurrentContext() else { return }
        cg.setStrokeColor(color.cgColor)
        cg.setLineWidth(lineWidth)
        cg.move(to: CGPoint(x: Self.side, y: y))
        cg.addLine(to: CGPoint(x: Self.page.width - Self.side, y: y))
        cg.strokePath()
    }

    private func drawFrame(_ cg: CGContext, page: Int, of total: Int) {
        var y = Self.top
        y += text(l("Duongöndro: your data"), Self.titleFont, Self.accent, x: Self.side, y: y, w: width)
        let exported = content.exportedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale,
                                                                       timeZone: content.timeZone))
        y += text(l("Exported \(exported) · iPhone \(build)"), Self.smallFont, Self.muted, x: Self.side, y: y, w: width)
        rule(y + 6, color: Self.accent, width: 1.5)

        let footer = Self.page.height - 40
        rule(footer - 6, color: Self.line, width: 0.5)
        text("duongondro.app/privacy", Self.smallFont, Self.muted, x: Self.side, y: footer, w: width)
        let pageText = l("Page \(page) of \(total)")
        text(pageText, Self.smallFont, Self.muted, x: Self.side, y: footer, w: width, align: .right)
    }

    private func drawHeader(_ table: Table, at top: CGFloat, continued: Bool = false) {
        var y = top
        if continued {
            text(table.continued, Self.smallFont, Self.muted, x: Self.side, y: y, w: width)
            y += table.continuedHeight
        }
        if let cg = UIGraphicsGetCurrentContext() {
            cg.setFillColor(Self.band.cgColor)
            cg.fill(CGRect(x: Self.side, y: y, width: width, height: table.height))
        }
        layout(table.columns) { _, column, x, w in
            text(column.title, Self.labelFont, Self.muted, x: x + 4, y: y + 4, w: w - 8, align: column.right ? .right : .left)
        }
    }

    private func layout(_ columns: [Column], _ body: (Int, Column, CGFloat, CGFloat) -> Void) {
        let total = columns.reduce(0) { $0 + $1.weight }
        var x = Self.side
        for (i, column) in columns.enumerated() {
            let w = column.weight / total * width
            body(i, column, x, w)
            x += w
        }
    }

    // MARK: - Building blocks

    /// The detail ("69 sessions") is measured first, on one line at the right; the
    /// title wraps in the width left of it, so a long practice name never runs under it.
    private func heading(_ title: String, detail: String? = nil, into items: inout [Item]) {
        let detailWidth = detail.map {
            ceil(NSAttributedString(string: $0, attributes: Self.attributes(Self.smallFont, Self.muted, .right))
                .boundingRect(with: CGSize(width: width, height: 100), options: [.usesLineFragmentOrigin], context: nil).width) + 12
        } ?? 0
        let titleWidth = width - detailWidth
        let h = text(title, Self.sectionFont, Self.ink, x: 0, y: 0, w: titleWidth, draw: false) + 8
        items.append(Item(block: PageFlow.Block(height: Double(h), keepWithNext: true)) { y in
            text(title, Self.sectionFont, Self.ink, x: Self.side, y: y, w: titleWidth)
            if let detail {
                text(detail, Self.smallFont, Self.muted, x: Self.side + titleWidth, y: y + 4, w: detailWidth, align: .right)
            }
        })
    }

    private func gap(_ h: CGFloat, into items: inout [Item]) {
        items.append(Item(block: PageFlow.Block(height: Double(h), collapsible: true)) { _ in })
    }

    private func paragraph(_ string: String, color: UIColor = Self.muted, keep: Bool = false, bullet: Bool = false,
                           into items: inout [Item]) {
        let indent: CGFloat = bullet ? 12 : 0
        let h = text(string, Self.bodyFont, color, x: 0, y: 0, w: width - indent, draw: false) + 4
        items.append(Item(block: PageFlow.Block(height: Double(h), keepWithNext: keep)) { y in
            if bullet { text("•", Self.bodyFont, color, x: Self.side + 2, y: y, w: indent) }
            text(string, Self.bodyFont, color, x: Self.side + indent, y: y, w: width - indent)
        })
    }

    private func pair(_ label: String, _ value: String, into items: inout [Item]) {
        let labelWidth: CGFloat = 130
        let h = max(text(label, Self.bodyFont, Self.muted, x: 0, y: 0, w: labelWidth, draw: false),
                    text(value, Self.bodyFont, Self.ink, x: 0, y: 0, w: width - labelWidth, draw: false)) + 4
        items.append(Item(block: PageFlow.Block(height: Double(h))) { y in
            text(label, Self.bodyFont, Self.muted, x: Self.side, y: y, w: labelWidth)
            text(value, Self.bodyFont, Self.ink, x: Self.side + labelWidth, y: y, w: width - labelWidth)
        })
    }

    /// A cell: one line, or a first line with a muted second.
    private struct Cell {
        var main: String
        var second: String?
        init(_ main: String, _ second: String? = nil) { self.main = main; self.second = second }
    }

    private func attributed(_ cell: Cell, _ column: Column) -> NSAttributedString {
        let align: NSTextAlignment = column.right ? .right : .left
        let out = NSMutableAttributedString(string: cell.main,
                                            attributes: Self.attributes(column.figure ? Self.figureFont : Self.bodyFont, Self.ink, align))
        if let second = cell.second, !second.isEmpty {
            out.append(NSAttributedString(string: "\n" + second, attributes: Self.attributes(Self.smallFont, Self.muted, align)))
        }
        return out
    }

    private func table(_ id: Int, continued name: String, _ columns: [Column], rows: [(cells: [Cell], group: Int?)],
                       into items: inout [Item], tables: inout [Int: Table]) {
        var table = Table(columns: columns, continued: l("\(name) (continued)"))
        table.continuedHeight = text(table.continued, Self.smallFont, Self.muted, x: 0, y: 0, w: width, draw: false) + 4
        var titles: CGFloat = 0
        layout(columns) { _, column, _, w in
            titles = max(titles, text(column.title, Self.labelFont, Self.muted, x: 0, y: 0, w: w - 8, draw: false))
        }
        table.height = titles + 8
        tables[id] = table
        items.append(Item(block: PageFlow.Block(height: Double(table.height), keepWithNext: true)) { [table] y in
            drawHeader(table, at: y)
        })
        for row in rows {
            var h: CGFloat = 0
            layout(columns) { i, column, _, w in
                h = max(h, Self.render(attributed(row.cells[i], column), x: 0, y: 0, w: w - 8, draw: false))
            }
            let rowHeight = h + 8
            items.append(Item(block: PageFlow.Block(height: Double(rowHeight), table: id, group: row.group)) { y in
                layout(columns) { i, column, x, w in
                    _ = Self.render(attributed(row.cells[i], column), x: x + 4, y: y + 4, w: w - 8, draw: true)
                }
                rule(y + rowHeight, color: Self.line, width: 0.5)
            })
        }
        gap(18, into: &items)
    }

    // MARK: - Content

    private func number(_ n: Int) -> String { n.formatted(.number.locale(locale)) }

    private func date(_ d: Date?, time: Bool = false) -> String {
        guard let d else { return "–" }
        return d.formatted(Date.FormatStyle(date: .abbreviated, time: time ? .shortened : .omitted, locale: locale,
                                            timeZone: content.timeZone))
    }

    private func day(_ day: CivilDate, in tz: TimeZone) -> String {
        let noon = day.startOfDay(in: tz).addingTimeInterval(12 * 3600)
        var style = Date.FormatStyle(locale: locale, timeZone: tz).weekday(.abbreviated).day().month(.abbreviated).year()
        style.locale = locale
        return noon.formatted(style)
    }

    private func names(_ p: Practice) -> Cell { Cell(p.shownName, p.shownSecondName) }

    private func gender(_ raw: String?) -> String {
        switch raw.flatMap(Gender.init(rawValue:)) {
        case .male: l("Male")
        case .female: l("Female")
        case .nonbinary: l("Non-binary")
        case nil: l("Not given")
        }
    }

    private func tier(_ raw: String) -> String {
        switch raw {
        case "hardware": l("Hardware key")
        case "tee": l("Trusted execution environment key")
        case "software": l("Software key")
        default: raw
        }
    }

    private func build(_ items: inout [Item], _ tables: inout [Int: Table]) {
        // 1. Account
        heading("1. " + l("Account"), into: &items)
        if let a = content.account {
            if content.serverPart == .missing {
                paragraph(l("This phone has an account, but the server could not be reached, so this section and Friends hold only what the phone knows. Export again when you are connected."),
                          keep: true, into: &items)
            }
            pair(l("Display name"), a.displayName.isEmpty ? l("A friend") : a.displayName, into: &items)
            pair(l("Username"), a.username ?? "–", into: &items)
            pair(l("Gender"), gender(a.gender), into: &items)
            pair(l("E-mail"), a.emails.isEmpty ? "–" : a.emails.joined(separator: "\n"), into: &items)
            if content.serverPart == .included {
                pair(l("Account created"), date(a.createdAt, time: true), into: &items)
                let passkeys = a.passkeys.map { p in
                    p.lastUsedAt.map { l("Added \(date(p.createdAt)), last used \(date($0))") } ?? l("Added \(date(p.createdAt))")
                }
                pair(l("Passkeys"), ([l("\(a.passkeys.count) passkeys")] + passkeys).joined(separator: "\n"), into: &items)
                let devices = a.devices.map { "\(tier($0.tier)) · " + l("Added \(date($0.createdAt))") }
                pair(l("Devices"), ([l("\(a.devices.count) devices")] + devices).joined(separator: "\n"), into: &items)
            }
        } else {
            paragraph(l("No online account: everything below is on this phone only."), color: Self.ink, into: &items)
        }
        gap(18, into: &items)

        // 2. Practices
        heading("2. " + l("Practices"), detail: l("\(content.practices.count) practices"), into: &items)
        table(0, continued: l("Practices"), [
            Column(title: l("Practice"), weight: 2.4),
            Column(title: l("Total"), weight: 1.1, right: true, figure: true),
            Column(title: l("Target"), weight: 1.0, right: true, figure: true),
            Column(title: l("Round"), weight: 0.8, right: true, figure: true),
            Column(title: l("Streak"), weight: 1.0, right: true, figure: true),
            Column(title: l("Longest"), weight: 1.1, right: true, figure: true),
            Column(title: l("Public"), weight: 1.0, right: true),
        ], rows: content.practices.map { p in
            var name = names(p.practice)
            if p.archived { name.second = [name.second, l("Archived")].compactMap { $0 }.joined(separator: " · ") }
            let counted = !p.streakOnly
            return ([
                name,
                Cell(counted ? number(p.total) : l("Streak only")),
                Cell(counted ? p.practice.target.map(number) ?? "–" : "–"),
                Cell(p.round.map(number) ?? "–", p.inRound.map(number)),
                Cell(l("\(p.currentStreak) days")),
                Cell(l("\(p.longestStreak) days")),
                Cell(p.isPublic ? l("Yes") : l("No")),
            ], nil)
        }, into: &items, tables: &tables)

        // 3. Sessions, by practice and then by day
        var tableID = 1
        var group = 0
        for p in content.practices {
            let days = content.sessionDays(of: p.id)
            guard !days.isEmpty else { continue }
            let count = days.reduce(0) { $0 + $1.sessions.count }
            heading("3. " + l("Sessions") + " · " + p.practice.shownName, detail: l("\(count) sessions"), into: &items)
            var rows: [(cells: [Cell], group: Int?)] = []
            for d in days {
                group += 1
                for (k, x) in d.sessions.enumerated() {
                    let started = x.start.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: x.timeZone))
                    rows.append(([
                        Cell(k == 0 ? day(d.day, in: x.timeZone) : ""),
                        Cell(started),
                        Cell(p.streakOnly || x.count == 0 ? l("Done") : number(x.count)),
                        Cell(x.round.map(number) ?? "–"),
                        Cell(x.day != x.startDay ? day(x.day, in: x.timeZone) : ""),
                    ], group))
                }
            }
            table(tableID, continued: p.practice.shownName, [
                Column(title: l("Day"), weight: 1.6),
                Column(title: l("Started"), weight: 0.9),
                Column(title: l("Count"), weight: 0.9, right: true, figure: true),
                Column(title: l("Round"), weight: 0.7, right: true, figure: true),
                Column(title: l("Counted for"), weight: 1.6),
            ], rows: rows, into: &items, tables: &tables)
            tableID += 1
        }
        if content.sessions.isEmpty {
            heading("3. " + l("Sessions"), into: &items)
            paragraph(l("No sessions yet."), into: &items)
            gap(18, into: &items)
        }
        if content.unreadable > 0 {
            paragraph(l("\(content.unreadable) sealed sessions could not be opened on this phone, so they are only in the JSON export."),
                      into: &items)
            gap(18, into: &items)
        }

        // 4. Friends
        heading("4. " + l("Friends"), detail: content.account == nil ? nil : l("\(content.friends.count) friends"), into: &items)
        if content.account == nil {
            paragraph(l("No online account"), into: &items)
            gap(18, into: &items)
        } else if content.friends.isEmpty {
            paragraph(l("No friends yet."), into: &items)
            gap(18, into: &items)
        } else {
            table(tableID, continued: l("Friends"), [
                Column(title: l("Name"), weight: 2), Column(title: l("Friends since"), weight: 1),
            ], rows: content.friends.map { ([Cell($0.displayName.isEmpty ? l("A friend") : $0.displayName), Cell(date($0.since))], nil) },
            into: &items, tables: &tables)
        }

        // 5. What the server keeps (the privacy page's lists)
        heading("5. " + l("What the server keeps"), into: &items)
        if content.account == nil {
            paragraph(l("Nothing: this phone has no online account."), color: Self.ink, into: &items)
            return
        }
        // Word for word the privacy page's three lists (duongondro-landing
        // src/pages/privacy.astro, sections "sealed", "encrypted" and "plain", as of
        // landing PR #7); a change there is a change here, in every language.
        let lists: [(title: String, intro: String?, entries: [String], outro: [String])] = [
            (l("What is end-to-end encrypted"),
             l("These are sealed on your device before they are uploaded. The server stores them and cannot read them:"), [
                l("practice sessions, including the day, the duration and your notes"),
                l("counts, rounds and totals"),
                l("targets"),
                l("imported streak seeds"),
             ], [l("The keys that open them stay on your devices. The server never receives a plaintext count or a key, and signing in does not give it one.")]),
            (l("What the server encrypts"),
             l("The server has to read these to do its job, for example to show your name to your friends or to send a notification. It keeps them encrypted in its database, with a key held outside the database, so a copy of the database or a backup does not reveal them:"), [
                l("your display name, and your grammatical gender if you give it"),
                l("your e-mail address, if you sign in with one; an account with only a passkey has none"),
                l("your username, if you chose one; it names your passkey and friends do not see it"),
                l("the Apple or Google account your sign-in is linked to"),
                l("your streaks, only for practices where you chose to publish them"),
                l("the public keys of your account, your devices and your passkeys"),
                l("push notification tokens"),
                l("the text of any report you send"),
             ], [l("Unlike your practice data, these can be read by the running server while it works with them.")]),
            (l("What the server stores in plain form"), nil, [
                l("that your account exists, as a random number"),
                l("which accounts are friends, and who invited, blocked, poked or reported whom, as links between those numbers"),
                l("for each friend, whether you asked to hear when they practise"),
                l("whether and when you set up a recovery key"),
                l("which kinds of sign-in, notification service and device key storage you use, for example a passkey on an Android phone"),
                l("for a streak you publish, when it runs out, so the server can remind you in time, and how many times it has been updated"),
                l("when each thing was written and last changed, and how large each sealed blob is; for a practice session, also when your phone logged it and last changed or deleted it, by the phone's clock, even if it synced later"),
             ], [l("The last item is a real limit. These times and sizes can show when you practise, even for a private streak."),
                 l("Cover photos for practices never leave your phone.")]),
        ]
        for list in lists {
            paragraph(list.title, color: Self.ink, keep: true, into: &items)
            if let intro = list.intro { paragraph(intro, keep: true, into: &items) }
            for e in list.entries { paragraph(e, bullet: true, into: &items) }
            for o in list.outro { paragraph(o, into: &items) }
            gap(10, into: &items)
        }
    }
}

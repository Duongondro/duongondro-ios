import Foundation

/// Page breaking for the PDF export, apart from the drawing so it can be tested:
/// blocks of measured height flow down pages; a heading never ends a page; a table
/// repeats its header after a page break; and rows of one group (a day's sessions)
/// stay together where they fit on a page.
public enum PageFlow {
    public struct Block: Equatable, Sendable {
        public var height: Double
        /// Stays on the page of the block after it (a heading, a table's header).
        public var keepWithNext: Bool
        /// The table this row belongs to, whose header repeats after a break.
        public var table: Int?
        /// Rows with the same group move to the next page together, where they fit on one.
        public var group: Int?
        /// Space between sections: dropped where a page breaks, at the top of a page
        /// and at the very end, so it never makes a blank page.
        public var collapsible: Bool

        public init(height: Double, keepWithNext: Bool = false, table: Int? = nil, group: Int? = nil,
                    collapsible: Bool = false) {
            self.height = height
            self.keepWithNext = keepWithNext
            self.table = table
            self.group = group
            self.collapsible = collapsible
        }
    }

    public enum Placement: Equatable, Sendable {
        /// The block at this index, at `y` from the content top.
        case block(Int, y: Double)
        /// The header of a table, repeated at the top of a continuation page.
        case header(table: Int, y: Double)
    }

    /// Pages of placements. `available` is the content height of a page;
    /// `headers` the heights of tables' repeated headers.
    public static func paginate(_ blocks: [Block], available: Double, headers: [Int: Double] = [:]) -> [[Placement]] {
        var pages: [[Placement]] = [[]]
        var y = 0.0
        var i = 0

        func newPage(continuing table: Int?) {
            pages.append([])
            y = 0
            if let table, let h = headers[table] {
                pages[pages.count - 1].append(.header(table: table, y: 0))
                y = h
            }
        }

        func hasBlock() -> Bool { pages[pages.count - 1].contains { if case .block = $0 { true } else { false } } }

        while i < blocks.count {
            if blocks[i].collapsible {
                if hasBlock(), y + blocks[i].height <= available {
                    pages[pages.count - 1].append(.block(i, y: y))
                    y += blocks[i].height
                }
                i += 1
                continue
            }
            // The unit that moves as one: a run of keep-with-next blocks (headings, a
            // table's header) with the block they keep to, and the rest of a row's group.
            var end = i
            while end < blocks.count - 1, blocks[end].keepWithNext { end += 1 }
            let head = blocks[i...end].reduce(0) { $0 + $1.height }
            if let g = blocks[end].group, let t = blocks[end].table {
                while end + 1 < blocks.count, blocks[end + 1].group == g, blocks[end + 1].table == t { end += 1 }
            }
            let unit = blocks[i...end].reduce(0) { $0 + $1.height }
            // A unit that starts with a row continues its table on the next page.
            let continuing = blocks[i].keepWithNext ? nil : blocks[i].table
            let fresh = available - (continuing.flatMap { headers[$0] } ?? 0)
            if hasBlock(), y + unit > available, unit <= fresh || y + head > available {
                newPage(continuing: continuing)
            }
            // Block by block: a unit taller than a page breaks inside it.
            for k in i...end {
                if y + blocks[k].height > available, hasBlock() {
                    newPage(continuing: blocks[k].keepWithNext ? nil : blocks[k].table)
                }
                pages[pages.count - 1].append(.block(k, y: y))
                y += blocks[k].height
            }
            i = end + 1
        }
        // Nothing but space at the end.
        while let last = pages[pages.count - 1].last, case let .block(k, _) = last, blocks[k].collapsible {
            pages[pages.count - 1].removeLast()
        }
        if pages.count > 1, !hasBlock() { pages.removeLast() }
        return pages
    }
}

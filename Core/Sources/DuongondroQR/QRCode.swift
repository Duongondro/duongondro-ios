import Foundation

/// A QR Code symbol (ISO/IEC 18004, versions 1-10).
///
/// Written because CIQRCodeGenerator only emits byte mode, which pushes an
/// invite link from version 3 to version 4; mixed segments keep it small
/// enough for a phone camera to read across a table.
public struct QRCode: Sendable {
    public let version: Int
    public let ecc: ECC
    public let mask: Int
    /// Modules per side: 17 + 4 * version.
    public let size: Int
    private let modules: [Bool]

    /// True for a dark module; (0, 0) is the top-left corner.
    public subscript(x: Int, y: Int) -> Bool { modules[y * size + x] }

    /// True inside the three 7x7 finder patterns, so the app can draw them as
    /// rounded eyes and the rest as dots. Separators are not included.
    public func isFinderModule(x: Int, y: Int) -> Bool {
        let near = { (v: Int) in v < 7 }
        let far = { (v: Int) in v >= self.size - 7 }
        return (near(x) && near(y)) || (far(x) && near(y)) || (near(x) && far(y))
    }

    public static let maxVersion = 10

    public static func encode(_ text: String, ecc: ECC = .medium, minVersion: Int = 1) throws -> QRCode {
        try encode(segments: Segment.split(text), ecc: ecc, minVersion: minVersion)
    }

    public static func encode(segments: [Segment], ecc: ECC, minVersion: Int = 1) throws -> QRCode {
        for version in max(1, minVersion)...maxVersion {
            let capacity = dataCodewords(version, ecc) * 8
            guard let used = bitLength(segments, version), used <= capacity else { continue }
            let data = padded(segments, version: version, capacityBits: capacity)
            return QRCode(version: version, ecc: ecc, codewords: interleaved(data, version, ecc))
        }
        throw QRError.tooLong
    }

    // MARK: Capacity tables (versions 1-10, index = version - 1)

    private static let eccPerBlock: [ECC: [Int]] = [
        .low: [7, 10, 15, 20, 26, 18, 20, 24, 30, 18],
        .medium: [10, 16, 26, 18, 24, 16, 18, 22, 22, 26],
        .quality: [13, 22, 18, 26, 18, 24, 18, 22, 20, 24],
        .high: [17, 28, 22, 16, 22, 28, 26, 26, 24, 28],
    ]
    private static let blockCount: [ECC: [Int]] = [
        .low: [1, 1, 1, 1, 1, 2, 2, 2, 2, 4],
        .medium: [1, 1, 1, 2, 2, 4, 4, 4, 5, 5],
        .quality: [1, 1, 2, 2, 4, 4, 6, 6, 8, 8],
        .high: [1, 1, 2, 4, 4, 4, 5, 6, 8, 8],
    ]
    private static let alignmentCentres: [[Int]] = [
        [], [6, 18], [6, 22], [6, 26], [6, 30], [6, 34], [6, 22, 38], [6, 24, 42], [6, 26, 46], [6, 28, 50],
    ]

    /// Modules left for data and ECC once function patterns are removed.
    private static func rawModules(_ version: Int) -> Int {
        var n = (16 * version + 128) * version + 64
        if version >= 2 {
            let a = version / 7 + 2
            n -= (25 * a - 10) * a - 55
            if version >= 7 { n -= 36 }
        }
        return n
    }

    private static func dataCodewords(_ version: Int, _ ecc: ECC) -> Int {
        rawModules(version) / 8 - eccPerBlock[ecc]![version - 1] * blockCount[ecc]![version - 1]
    }

    // MARK: Bit stream

    /// Total bits of all segments at this version, or nil if a count overflows its field.
    private static func bitLength(_ segments: [Segment], _ version: Int) -> Int? {
        var total = 0
        for s in segments {
            let width = s.mode.countBits(version: version)
            if s.count >= 1 << width { return nil }
            total += 4 + width + s.bits.count
        }
        return total
    }

    /// Mode headers, data, terminator and the alternating 0xEC/0x11 pad bytes.
    private static func padded(_ segments: [Segment], version: Int, capacityBits: Int) -> [UInt8] {
        var bits: [Bool] = []
        for s in segments {
            Segment.appendBits(&bits, s.mode.indicator, 4)
            Segment.appendBits(&bits, s.count, s.mode.countBits(version: version))
            bits += s.bits
        }
        bits += [Bool](repeating: false, count: min(4, capacityBits - bits.count))
        while bits.count % 8 != 0 { bits.append(false) }
        var bytes = stride(from: 0, to: bits.count, by: 8).map { i in
            bits[i..<i + 8].reduce(UInt8(0)) { $0 << 1 | ($1 ? 1 : 0) }
        }
        var pad: UInt8 = 0xEC
        while bytes.count < capacityBits / 8 {
            bytes.append(pad)
            pad = pad == 0xEC ? 0x11 : 0xEC
        }
        return bytes
    }

    // MARK: Reed-Solomon over GF(256), polynomial 0x11D

    private static func gfMultiply(_ x: UInt8, _ y: UInt8) -> UInt8 {
        var z = 0
        for i in stride(from: 7, through: 0, by: -1) {
            z = (z << 1) ^ ((z >> 7) * 0x11D)
            z ^= ((Int(y) >> i) & 1) * Int(x)
        }
        return UInt8(z)
    }

    /// Coefficients (without the leading 1) of the product of (x - 2^i).
    private static func generator(_ degree: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: degree - 1) + [1]
        var root: UInt8 = 1
        for _ in 0..<degree {
            for j in 0..<degree {
                result[j] = gfMultiply(result[j], root)
                if j + 1 < degree { result[j] ^= result[j + 1] }
            }
            root = gfMultiply(root, 2)
        }
        return result
    }

    private static func remainder(_ data: [UInt8], _ divisor: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: divisor.count)
        for b in data {
            let factor = b ^ result.removeFirst()
            result.append(0)
            for (i, c) in divisor.enumerated() { result[i] ^= gfMultiply(c, factor) }
        }
        return result
    }

    /// Splits data into blocks, appends ECC to each and interleaves them so a
    /// local scratch damages many blocks a little instead of one a lot.
    private static func interleaved(_ data: [UInt8], _ version: Int, _ ecc: ECC) -> [UInt8] {
        let blocks = blockCount[ecc]![version - 1]
        let eccLen = eccPerBlock[ecc]![version - 1]
        let total = rawModules(version) / 8
        let shortBlocks = blocks - total % blocks
        let shortLen = total / blocks
        let divisor = generator(eccLen)

        var datas: [[UInt8]] = []
        var eccs: [[UInt8]] = []
        var k = 0
        for i in 0..<blocks {
            let len = shortLen - eccLen + (i < shortBlocks ? 0 : 1)
            let d = Array(data[k..<k + len])
            k += len
            datas.append(d)
            eccs.append(remainder(d, divisor))
        }
        var out: [UInt8] = []
        for i in 0..<(shortLen - eccLen + 1) {
            for d in datas where i < d.count { out.append(d[i]) }
        }
        for i in 0..<eccLen { for e in eccs { out.append(e[i]) } }
        return out
    }

    // Test seams for the spec's worked example.
    static func testPadded(_ s: [Segment], version: Int, ecc: ECC) -> [UInt8] {
        padded(s, version: version, capacityBits: dataCodewords(version, ecc) * 8)
    }
    static func testInterleaved(_ d: [UInt8], version: Int, ecc: ECC) -> [UInt8] { interleaved(d, version, ecc) }

    // MARK: Matrix

    private init(version: Int, ecc: ECC, codewords: [UInt8]) {
        var m = Matrix(version: version)
        m.drawFunctionPatterns(ecc: ecc)
        m.placeCodewords(codewords)

        var best = (mask: 0, penalty: Int.max)
        for mask in 0..<8 {
            m.applyMask(mask)
            m.drawFormat(ecc: ecc, mask: mask)
            let p = m.penalty()
            if p < best.penalty { best = (mask, p) }
            m.applyMask(mask)  // XOR again to undo
        }
        m.applyMask(best.mask)
        m.drawFormat(ecc: ecc, mask: best.mask)

        self.version = version
        self.ecc = ecc
        self.mask = best.mask
        self.size = m.size
        self.modules = m.dark
    }
}

/// Working grid; `isFunction` marks modules that data and masks must not touch.
private struct Matrix {
    let version: Int
    let size: Int
    var dark: [Bool]
    var isFunction: [Bool]

    init(version: Int) {
        self.version = version
        size = 17 + 4 * version
        dark = [Bool](repeating: false, count: size * size)
        isFunction = dark
    }

    mutating func setFunction(_ x: Int, _ y: Int, _ value: Bool) {
        dark[y * size + x] = value
        isFunction[y * size + x] = true
    }

    mutating func drawFunctionPatterns(ecc: ECC) {
        for i in 0..<size {
            setFunction(6, i, i % 2 == 0)
            setFunction(i, 6, i % 2 == 0)
        }
        // Each finder plus its one-module light separator, as a 9x9 square.
        for (cx, cy) in [(3, 3), (size - 4, 3), (3, size - 4)] {
            for dy in -4...4 {
                for dx in -4...4 {
                    let x = cx + dx, y = cy + dy
                    guard x >= 0, x < size, y >= 0, y < size else { continue }
                    let d = max(abs(dx), abs(dy))
                    setFunction(x, y, d != 2 && d != 4)
                }
            }
        }
        let centres = alignmentCentres(version)
        for (i, cy) in centres.enumerated() {
            for (j, cx) in centres.enumerated() {
                // The three corners where an alignment pattern would hit a finder.
                if (i == 0 && j == 0) || (i == 0 && j == centres.count - 1) || (i == centres.count - 1 && j == 0) {
                    continue
                }
                for dy in -2...2 {
                    for dx in -2...2 { setFunction(cx + dx, cy + dy, max(abs(dx), abs(dy)) != 1) }
                }
            }
        }
        drawFormat(ecc: ecc, mask: 0)  // reserve the area; redrawn per mask
        drawVersion()
    }

    private func alignmentCentres(_ version: Int) -> [Int] {
        let table: [[Int]] = [
            [], [6, 18], [6, 22], [6, 26], [6, 30], [6, 34], [6, 22, 38], [6, 24, 42], [6, 26, 46], [6, 28, 50],
        ]
        return table[version - 1]
    }

    /// BCH(15,5) format word, XORed with 0x5412 so it is never all zero.
    mutating func drawFormat(ecc: ECC, mask: Int) {
        let data = ecc.formatBits << 3 | mask
        var rem = data
        for _ in 0..<10 { rem = (rem << 1) ^ ((rem >> 9) * 0x537) }
        let bits = (data << 10 | rem) ^ 0x5412
        func bit(_ i: Int) -> Bool { (bits >> i) & 1 == 1 }

        for i in 0...5 { setFunction(8, i, bit(i)) }
        setFunction(8, 7, bit(6))
        setFunction(8, 8, bit(7))
        setFunction(7, 8, bit(8))
        for i in 9..<15 { setFunction(14 - i, 8, bit(i)) }

        for i in 0..<8 { setFunction(size - 1 - i, 8, bit(i)) }
        for i in 8..<15 { setFunction(8, size - 15 + i, bit(i)) }
        setFunction(8, size - 8, true)  // the always-dark module
    }

    /// BCH(18,6) version word, only present from version 7.
    mutating func drawVersion() {
        guard version >= 7 else { return }
        var rem = version
        for _ in 0..<12 { rem = (rem << 1) ^ ((rem >> 11) * 0x1F25) }
        let bits = version << 12 | rem
        for i in 0..<18 {
            let b = (bits >> i) & 1 == 1
            let a = size - 11 + i % 3
            let c = i / 3
            setFunction(a, c, b)
            setFunction(c, a, b)
        }
    }

    /// Zigzag up and down two-column strips from the bottom right, skipping the timing column.
    mutating func placeCodewords(_ data: [UInt8]) {
        var i = 0
        var right = size - 1
        while right >= 1 {
            if right == 6 { right = 5 }
            for vert in 0..<size {
                for j in 0..<2 {
                    let x = right - j
                    let upward = (right + 1) & 2 == 0
                    let y = upward ? size - 1 - vert : vert
                    if !isFunction[y * size + x], i < data.count * 8 {
                        dark[y * size + x] = (data[i >> 3] >> (7 - UInt8(i & 7))) & 1 == 1
                        i += 1
                    }
                }
            }
            right -= 2
        }
    }

    mutating func applyMask(_ mask: Int) {
        for y in 0..<size {
            for x in 0..<size where !isFunction[y * size + x] {
                let flip: Bool
                switch mask {
                case 0: flip = (x + y) % 2 == 0
                case 1: flip = y % 2 == 0
                case 2: flip = x % 3 == 0
                case 3: flip = (x + y) % 3 == 0
                case 4: flip = (x / 3 + y / 2) % 2 == 0
                case 5: flip = x * y % 2 + x * y % 3 == 0
                case 6: flip = (x * y % 2 + x * y % 3) % 2 == 0
                default: flip = ((x + y) % 2 + x * y % 3) % 2 == 0
                }
                if flip { dark[y * size + x].toggle() }
            }
        }
    }

    /// The four standard penalty rules; the lowest total picks the mask.
    func penalty() -> Int {
        var score = 0
        let finderLike: [[Bool]] = [
            [true, false, true, true, true, false, true, false, false, false, false],
            [false, false, false, false, true, false, true, true, true, false, true],
        ]
        for transpose in [false, true] {
            for a in 0..<size {
                let line = (0..<size).map { b in transpose ? dark[b * size + a] : dark[a * size + b] }
                // Rule 1: runs of five or more same-coloured modules.
                var run = 1
                for i in 1...size {
                    if i < size, line[i] == line[i - 1] {
                        run += 1
                    } else {
                        if run >= 5 { score += run - 2 }
                        run = 1
                    }
                }
                // Rule 3: patterns that look like a finder.
                if size >= 11 {
                    for i in 0...(size - 11) where finderLike.contains(where: { Array(line[i..<i + 11]) == $0 }) {
                        score += 40
                    }
                }
            }
        }
        // Rule 2: 2x2 blocks of one colour.
        for y in 0..<(size - 1) {
            for x in 0..<(size - 1) {
                let c = dark[y * size + x]
                if c == dark[y * size + x + 1], c == dark[(y + 1) * size + x], c == dark[(y + 1) * size + x + 1] {
                    score += 3
                }
            }
        }
        // Rule 4: balance of dark and light.
        let total = size * size
        let darkCount = dark.filter { $0 }.count
        let k = (abs(darkCount * 20 - total * 10) + total - 1) / total - 1
        return score + k * 10
    }
}

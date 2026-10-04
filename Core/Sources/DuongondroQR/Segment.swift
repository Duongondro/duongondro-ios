import Foundation

/// Error correction level. Higher levels survive more damage but hold less data.
public enum ECC: Int, CaseIterable, Sendable {
    case low, medium, quality, high

    /// The two format-information bits (not in rank order, per ISO/IEC 18004).
    var formatBits: Int { [1, 0, 3, 2][rawValue] }
}

public enum QRError: Error, Equatable {
    case invalidCharacters
    case tooLong
}

/// One run of text in a single encoding mode. A code may mix several segments
/// so that, for example, a URL stays in the dense alphanumeric mode except for
/// the one character that is not in its table.
public struct Segment: Equatable, Sendable {
    public enum Mode: Sendable {
        case numeric, alphanumeric, byte

        var indicator: Int {
            switch self {
            case .numeric: return 0b0001
            case .alphanumeric: return 0b0010
            case .byte: return 0b0100
            }
        }

        /// Width of the character count field; it grows at version 10.
        func countBits(version: Int) -> Int {
            let small: Int
            switch self {
            case .numeric: small = 10
            case .alphanumeric: small = 9
            case .byte: small = 8
            }
            if version <= 9 { return small }
            return small + (self == .byte ? 8 : 2)
        }
    }

    public let mode: Mode
    /// Characters (bytes in byte mode) in the segment.
    public let count: Int
    let bits: [Bool]

    static let alphanumericTable = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:")

    public static func numeric(_ digits: String) throws -> Segment {
        guard digits.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { throw QRError.invalidCharacters }
        var bits: [Bool] = []
        let values = digits.utf8.map { Int($0) - 48 }
        var i = 0
        while i < values.count {
            let n = min(3, values.count - i)
            let group = values[i..<i + n].reduce(0) { $0 * 10 + $1 }
            appendBits(&bits, group, n * 3 + 1)  // 1, 2, 3 digits -> 4, 7, 10 bits
            i += n
        }
        return Segment(mode: .numeric, count: values.count, bits: bits)
    }

    public static func alphanumeric(_ text: String) throws -> Segment {
        let values = try text.map { ch -> Int in
            guard let v = alphanumericTable.firstIndex(of: ch) else { throw QRError.invalidCharacters }
            return v
        }
        var bits: [Bool] = []
        var i = 0
        while i + 1 < values.count {
            appendBits(&bits, values[i] * 45 + values[i + 1], 11)
            i += 2
        }
        if i < values.count { appendBits(&bits, values[i], 6) }
        return Segment(mode: .alphanumeric, count: values.count, bits: bits)
    }

    public static func bytes(_ data: [UInt8]) -> Segment {
        var bits: [Bool] = []
        for b in data { appendBits(&bits, Int(b), 8) }
        return Segment(mode: .byte, count: data.count, bits: bits)
    }

    /// Splits text into segments with the fewest bits, by dynamic programming
    /// over bytes. Switching modes costs a header, so a lone digit inside a
    /// URL stays alphanumeric and a lone '#' becomes a tiny byte segment only
    /// when that is cheaper than widening its neighbours.
    public static func split(_ text: String) -> [Segment] {
        let bytes = Array(text.utf8)
        if bytes.isEmpty { return [] }
        let modes: [Mode] = [.numeric, .alphanumeric, .byte]
        // Costs are scaled by 6 so 10/3 and 11/2 bits per character stay integral.
        let charCost = [20, 33, 48]
        let header = modes.map { 6 * (4 + $0.countBits(version: 1)) }

        func allowed(_ m: Int, _ b: UInt8) -> Bool {
            switch m {
            case 0: return b >= 48 && b <= 57
            case 1: return b < 128 && alphanumericTable.contains(Character(UnicodeScalar(b)))
            default: return true
            }
        }

        let inf = Int.max / 2
        var cost = [[Int]](repeating: [inf, inf, inf], count: bytes.count)
        var from = [[Int]](repeating: [0, 0, 0], count: bytes.count)
        for (i, b) in bytes.enumerated() {
            for m in 0..<3 where allowed(m, b) {
                if i == 0 {
                    cost[0][m] = header[m] + charCost[m]
                    continue
                }
                for p in 0..<3 where cost[i - 1][p] < inf {
                    let c = cost[i - 1][p] + (p == m ? 0 : header[m]) + charCost[m]
                    if c < cost[i][m] { cost[i][m] = c; from[i][m] = p }
                }
            }
        }

        var chosen = [Int](repeating: 2, count: bytes.count)
        var m = (0..<3).min { cost[bytes.count - 1][$0] < cost[bytes.count - 1][$1] }!
        for i in stride(from: bytes.count - 1, through: 0, by: -1) {
            chosen[i] = m
            m = from[i][m]
        }

        var result: [Segment] = []
        var start = 0
        for i in 1...bytes.count where i == bytes.count || chosen[i] != chosen[start] {
            let run = Array(bytes[start..<i])
            let s = String(decoding: run, as: UTF8.self)
            // The run is valid for its mode by construction of `allowed`.
            switch chosen[start] {
            case 0: result.append(try! numeric(s))
            case 1: result.append(try! alphanumeric(s))
            default: result.append(Segment.bytes(run))
            }
            start = i
        }
        return result
    }

    static func appendBits(_ bits: inout [Bool], _ value: Int, _ length: Int) {
        for i in stride(from: length - 1, through: 0, by: -1) { bits.append((value >> i) & 1 == 1) }
    }
}

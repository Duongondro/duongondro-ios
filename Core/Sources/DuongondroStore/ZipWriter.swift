import Foundation

/// A minimal ZIP writer: stored entries (no compression), enough for an export
/// of a few JSON files and photos. No dependency, so the format stays checkable.
public struct ZipWriter {
    private var data = Data()
    private var central = Data()
    private var count: UInt16 = 0

    public init() {}

    public mutating func add(_ name: String, _ contents: Data, modified: Date = Date()) {
        let nameBytes = Data(name.utf8)
        let crc = CRC32.checksum(contents)
        let (time, date) = Self.dosTimestamp(modified)
        let offset = UInt32(data.count)

        var local = Data()
        local.append(le32: 0x0403_4B50)
        local.append(le16: 20)          // version needed
        local.append(le16: 0x0800)      // UTF-8 names
        local.append(le16: 0)           // stored
        local.append(le16: time)
        local.append(le16: date)
        local.append(le32: crc)
        local.append(le32: UInt32(contents.count))
        local.append(le32: UInt32(contents.count))
        local.append(le16: UInt16(nameBytes.count))
        local.append(le16: 0)
        data.append(local)
        data.append(nameBytes)
        data.append(contents)

        var entry = Data()
        entry.append(le32: 0x0201_4B50)
        entry.append(le16: 20)          // version made by
        entry.append(le16: 20)
        entry.append(le16: 0x0800)
        entry.append(le16: 0)
        entry.append(le16: time)
        entry.append(le16: date)
        entry.append(le32: crc)
        entry.append(le32: UInt32(contents.count))
        entry.append(le32: UInt32(contents.count))
        entry.append(le16: UInt16(nameBytes.count))
        entry.append(le16: 0)           // extra
        entry.append(le16: 0)           // comment
        entry.append(le16: 0)           // disk
        entry.append(le16: 0)           // internal attributes
        entry.append(le32: 0)           // external attributes
        entry.append(le32: offset)
        central.append(entry)
        central.append(nameBytes)
        count += 1
    }

    public func finish() -> Data {
        var out = data
        let centralOffset = UInt32(out.count)
        out.append(central)
        out.append(le32: 0x0605_4B50)
        out.append(le16: 0)
        out.append(le16: 0)
        out.append(le16: count)
        out.append(le16: count)
        out.append(le32: UInt32(central.count))
        out.append(le32: centralOffset)
        out.append(le16: 0)
        return out
    }

    static func dosTimestamp(_ date: Date) -> (time: UInt16, date: UInt16) {
        let c = Calendar.gregorian(in: .current).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let hour: Int = c.hour ?? 0, minute: Int = c.minute ?? 0, second: Int = c.second ?? 0
        let year: Int = max(0, (c.year ?? 1980) - 1980), month: Int = c.month ?? 1, day: Int = c.day ?? 1
        let time = UInt16(truncatingIfNeeded: (hour << 11) | (minute << 5) | (second / 2))
        let dosDate = UInt16(truncatingIfNeeded: (year << 9) | (month << 5) | day)
        return (time, dosDate)
    }
}

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func append(le16 v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func append(le32 v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
}

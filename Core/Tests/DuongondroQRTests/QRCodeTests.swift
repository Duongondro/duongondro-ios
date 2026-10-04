import CoreGraphics
import CoreImage
import XCTest
@testable import DuongondroQR

final class QRCodeTests: XCTestCase {
    static let invite = "HTTPS://DUONGONDRO.APP/I/7K2MQ9XA#H4N8R2CJ6TPW3ZQF"
    static let friend = "HTTPS://DUONGONDRO.APP/F/7K2MQ9XA#H4N8R2CJ6TPW3ZQF"

    func testInviteLinksFitVersion3AtM() throws {
        for url in [Self.invite, Self.friend] {
            let qr = try QRCode.encode(url, ecc: .medium)
            XCTAssertEqual(qr.version, 3, url)
            XCTAssertEqual(qr.size, 29, url)
        }
    }

    func testSplitKeepsHashAsOneByteSegment() {
        let modes = Segment.split(Self.invite).map(\.mode)
        XCTAssertEqual(modes, [.alphanumeric, .byte, .alphanumeric])
    }

    func testSplitMergesTinySegments() {
        // A lone digit between letters is cheaper inside the alphanumeric run.
        XCTAssertEqual(Segment.split("AB1CD").map(\.mode), [.alphanumeric])
        XCTAssertEqual(Segment.split("1234567890").map(\.mode), [.numeric])
    }

    func testFinderModules() throws {
        let qr = try QRCode.encode("HELLO")
        XCTAssertTrue(qr.isFinderModule(x: 0, y: 0))
        XCTAssertTrue(qr.isFinderModule(x: qr.size - 1, y: 6))
        XCTAssertTrue(qr.isFinderModule(x: 6, y: qr.size - 1))
        XCTAssertFalse(qr.isFinderModule(x: 7, y: 7))
        XCTAssertFalse(qr.isFinderModule(x: qr.size - 1, y: qr.size - 1))
    }

    func testTooLongThrows() {
        XCTAssertThrowsError(try QRCode.encode(String(repeating: "a", count: 400)))
    }

    func testMinimumVersion() throws {
        XCTAssertEqual(try QRCode.encode("HELLO", minVersion: 5).version, 5)
    }

    func testSpecExampleCodewords() throws {
        // ISO/IEC 18004 Annex I: "01234567" at 1-M is version 1, 16 data + 10 ECC codewords.
        let qr = try QRCode.encode("01234567", ecc: .medium)
        XCTAssertEqual(qr.version, 1)
        let data = QRCode.testPadded(try [Segment.numeric("01234567")], version: 1, ecc: .medium)
        XCTAssertEqual(data, [0x10, 0x20, 0x0C, 0x56, 0x61, 0x80, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11])
        XCTAssertEqual(QRCode.testInterleaved(data, version: 1, ecc: .medium).suffix(10),
                       [0xA5, 0x24, 0xD4, 0xC1, 0xED, 0x36, 0xC7, 0x87, 0x2C, 0x55])
    }

    // MARK: Round trips through CoreImage's detector

    func testRoundTrips() throws {
        var rng = SeededGenerator(seed: 42)
        let alnum = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:")
        var inputs = [
            Self.invite,
            Self.friend,
            "hello, world",
            "Duongöndro: 你好",
            "0123456789012345678901234567890123456789",
            String((0..<60).map { _ in alnum.randomElement(using: &rng)! }),
            String((0..<20).map { _ in alnum.randomElement(using: &rng)! }),
            String((0..<100).map { _ in "abcdefghij klmnop".randomElement(using: &rng)! }),  // version 7+
        ]
        inputs.append(String(repeating: "Practice makes the mind calm. ", count: 3))
        for text in inputs {
            for ecc in ECC.allCases {
                let qr = try QRCode.encode(text, ecc: ecc)
                XCTAssertEqual(try decode(qr), text, "v\(qr.version) \(ecc) mask \(qr.mask): \(text)")
            }
        }
        XCTAssertGreaterThanOrEqual(try QRCode.encode(inputs[7], ecc: .quality).version, 7)
    }

    func testEveryVersionDecodes() throws {
        for version in 1...QRCode.maxVersion {
            let qr = try QRCode.encode("HTTPS://DUONGONDRO.APP", ecc: .low, minVersion: version)
            XCTAssertEqual(qr.version, version)
            XCTAssertEqual(try decode(qr), "HTTPS://DUONGONDRO.APP", "version \(version)")
        }
    }

    private func decode(_ qr: QRCode) throws -> String? {
        let scale = 8, quiet = 4
        let side = (qr.size + 2 * quiet) * scale
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.setFillColor(gray: 0, alpha: 1)
        for y in 0..<qr.size {
            for x in 0..<qr.size where qr[x, y] {
                // CGContext's origin is bottom-left; flip rows so the image is upright.
                ctx.fill(CGRect(x: (x + quiet) * scale, y: (qr.size - 1 - y + quiet) * scale, width: scale, height: scale))
            }
        }
        let image = try XCTUnwrap(ctx.makeImage())
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let features = detector.features(in: CIImage(cgImage: image))
        return (features.first as? CIQRCodeFeature)?.messageString
    }
}

/// Deterministic so a failing input can be reproduced.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

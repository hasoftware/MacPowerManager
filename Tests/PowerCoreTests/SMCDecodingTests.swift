import XCTest
@testable import PowerCore

final class SMCDecodingTests: XCTestCase {
    private func decode(_ type: String, _ bytes: [UInt8], le: Bool) -> Double? {
        SMCReading.decode(type: type, bytes: bytes, littleEndian: le)
    }

    func testLittleEndianIntegersOnAppleSilicon() {
        XCTAssertEqual(decode("ui32", [0x01, 0x00, 0x00, 0x00], le: true), 1, "CHTE = 01000000 nghĩa là 1")
        XCTAssertEqual(decode("ui16", [0x50, 0x00], le: true), 80, "BRSC")
        XCTAssertEqual(decode("ui16", [0xf6, 0x21], le: true), 8694, "B0DC")
        XCTAssertEqual(decode("si16", [0x38, 0xff], le: true), -200, "B0AC khi xả")
    }

    func testBigEndianKeys() {
        XCTAssertEqual(decode("ui16", [0x15, 0xfd], le: false), 5629, "B0RM là big-endian")
        XCTAssertEqual(decode("ui32", [0x00, 0x00, 0x08, 0xc7], le: false), 2247, "#KEY")
        XCTAssertEqual(decode("sp78", [0x1e, 0x4c], le: false)!, 30.3, accuracy: 0.01, "TB0T trên Intel")
    }

    func testFloatAndSmallTypes() {
        XCTAssertEqual(decode("flt ", [0x98, 0x99, 0x07, 0x42], le: true)!, 33.9, accuracy: 0.01)
        XCTAssertEqual(decode("ui8 ", [0x51], le: true), 81)
        XCTAssertEqual(decode("si8 ", [0xff], le: true), -1)
        XCTAssertNil(decode("hex_", [0x00], le: true))
        XCTAssertNil(decode("ui16", [0x00], le: true), "Sai kích thước thì không giải mã")
    }

    func testIntelFloatIsLittleEndian() {
        // Trên Intel `flt ` lưu little-endian dù các số nguyên là big-endian.
        let fan = SMCReading(key: "F0Ac", type: "flt ", attributes: 0x80, bytes: [0x00, 0xe8, 0x9a, 0x45])
        if !Platform.isAppleSilicon {
            XCTAssertEqual(fan.doubleValue!, 4957, accuracy: 0.5)
        }
        XCTAssertEqual(decode("flt ", [0x00, 0xe8, 0x9a, 0x45], le: true)!, 4957, accuracy: 0.5)
    }
}

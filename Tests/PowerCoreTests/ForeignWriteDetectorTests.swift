import XCTest
@testable import PowerCore

final class ForeignWriteDetectorTests: XCTestCase {
    private let inhibit: [UInt8] = [0x01, 0x00, 0x00, 0x00]
    private let allow: [UInt8] = [0x00, 0x00, 0x00, 0x00]

    func testNoMismatch() {
        let written = ["CHTE": inhibit, "CHIE": [0x00]]
        XCTAssertEqual(ForeignWriteDetector.detect(lastWritten: written, current: written, now: testEpoch), [])
    }

    func testReportsMismatchAsLowercaseHex() {
        let result = ForeignWriteDetector.detect(lastWritten: ["CHTE": allow], current: ["CHTE": inhibit], now: testEpoch)
        XCTAssertEqual(result, [ForeignWrite(key: "CHTE", expected: "00000000", found: "01000000", at: testEpoch)])
    }

    func testHexUsesLowercase() {
        XCTAssertEqual(ForeignWriteDetector.hex([0xAB, 0x0C, 0xFF]), "ab0cff")
        XCTAssertEqual(ForeignWriteDetector.hex([]), "")
    }

    func testMissingCurrentValueIsSkipped() {
        XCTAssertEqual(ForeignWriteDetector.detect(lastWritten: ["CHTE": inhibit], current: [:], now: testEpoch), [],
                       "Không đọc được key thì không kết luận")
    }

    func testKeysWeNeverWroteAreIgnored() {
        XCTAssertEqual(ForeignWriteDetector.detect(lastWritten: [:], current: ["CHIE": [0x08]], now: testEpoch), [])
    }

    func testMultipleMismatchesSortedByKey() {
        let written: [String: [UInt8]] = ["CHTE": allow, "CHIE": [0x00], "CH0J": [0x00], "ACLC": [0x00]]
        let current: [String: [UInt8]] = ["CHTE": inhibit, "CHIE": [0x08], "CH0J": [0x00], "ACLC": [0x04]]
        let result = ForeignWriteDetector.detect(lastWritten: written, current: current, now: testEpoch)
        XCTAssertEqual(result.map(\.key), ["ACLC", "CHIE", "CHTE"])
        XCTAssertEqual(result.map(\.found), ["04", "08", "01000000"])
        XCTAssertTrue(result.allSatisfy { $0.at == testEpoch })
    }

    func testLengthMismatchIsReported() {
        let result = ForeignWriteDetector.detect(lastWritten: ["CHTE": inhibit], current: ["CHTE": [0x01]], now: testEpoch)
        XCTAssertEqual(result.first?.found, "01")
        XCTAssertEqual(result.first?.expected, "01000000")
    }
}

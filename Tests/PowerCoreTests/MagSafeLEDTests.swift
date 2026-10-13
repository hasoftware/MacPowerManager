import XCTest
@testable import PowerCore

final class MagSafeLEDTests: XCTestCase {
    func testStatusColors() {
        func color(_ ac: Bool, adapter: Bool? = true, charging: Bool) -> MagSafeLEDColor? {
            MagSafeLED.desiredColor(mode: .status, acPresent: ac, adapterEnabled: adapter, charging: charging)
        }
        XCTAssertEqual(color(true, charging: true), .amber, "Đang sạc")
        XCTAssertEqual(color(true, charging: false), .green, "Giữ ở giới hạn hoặc đã đầy: không còn cam mãi")
        XCTAssertEqual(color(true, adapter: false, charging: false), .off, "Đang xả bằng cách ngắt bộ sạc")
        XCTAssertNil(color(false, charging: false), "Rút sạc: đèn không sáng, không ghi")
    }

    func testOtherModes() {
        XCTAssertNil(MagSafeLED.desiredColor(mode: .system, acPresent: true, adapterEnabled: true, charging: true))
        XCTAssertEqual(MagSafeLED.desiredColor(mode: .off, acPresent: true, adapterEnabled: true, charging: true), .off)
        XCTAssertNil(MagSafeLED.desiredColor(mode: .off, acPresent: false, adapterEnabled: true, charging: false))
    }

    func testNextWriteOnlyWhenNeededAndReleasesOnce() {
        XCTAssertEqual(MagSafeLED.nextWrite(desired: .green, owned: false, current: 4), .green)
        XCTAssertNil(MagSafeLED.nextWrite(desired: .green, owned: true, current: 3), "Đã đúng màu")
        XCTAssertEqual(MagSafeLED.nextWrite(desired: nil, owned: true, current: 3), .system, "Trả quyền cho hệ thống")
        XCTAssertNil(MagSafeLED.nextWrite(desired: nil, owned: false, current: 4), "Chưa từng đặt màu thì không đụng tới")
    }

    func testConfigDefaultsToSystemAndDecodes() throws {
        XCTAssertEqual(PowerConfig().magSafeLED, .system)
        let old = try JSONDecoder().decode(PowerConfig.self, from: Data(#"{"chargeLimit":80}"#.utf8))
        XCTAssertEqual(old.magSafeLED, .system)
        let bad = try JSONDecoder().decode(PowerConfig.self, from: Data(#"{"magSafeLED":"rainbow"}"#.utf8))
        XCTAssertEqual(bad.magSafeLED, .system)
        var c = PowerConfig()
        c.magSafeLED = .status
        XCTAssertEqual(try JSONDecoder().decode(PowerConfig.self, from: JSONEncoder().encode(c)).magSafeLED, .status)
        let command = try JSONDecoder().decode(HelperCommand.self, from: JSONEncoder().encode(HelperCommand.testMagSafeLED(.green)))
        XCTAssertEqual(command, .testMagSafeLED(.green))
    }
}

import XCTest
@testable import PowerCore

final class PowerConfigTests: XCTestCase {
    func testMissingFieldsKeepOtherValues() throws {
        // Cấu hình từ bản cũ, thiếu nhiều trường.
        let json = #"{"chargeLimit": 70, "chargeLimitEnabled": true}"#
        let config = try JSONDecoder().decode(PowerConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.chargeLimit, 70, "Giữ giá trị người dùng đã chọn")
        XCTAssertEqual(config.thermalPauseAbove, PowerConfig().thermalPauseAbove)
        XCTAssertEqual(config.sailingGap, PowerConfig().sailingGap)
    }

    func testWrongTypeFallsBackToDefault() throws {
        let json = #"{"chargeLimit": "tám mươi", "sailingGap": 3}"#
        let config = try JSONDecoder().decode(PowerConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.chargeLimit, PowerConfig().chargeLimit)
        XCTAssertEqual(config.sailingGap, 3)
    }

    func testRoundTrip() throws {
        var config = PowerConfig()
        config.chargeLimit = 65
        config.pauseCharging = true
        let decoded = try JSONDecoder().decode(PowerConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded, config)
    }

    func testHoldsLevel() {
        var config = PowerConfig()
        config.chargeLimit = 100
        XCTAssertFalse(config.holdsLevel, "Giới hạn 100% không cần giữ mức khi ngủ")
        config.chargeLimit = 80
        XCTAssertTrue(config.holdsLevel)
        config.chargeLimitEnabled = false
        XCTAssertFalse(config.holdsLevel)
        config.pauseCharging = true
        XCTAssertTrue(config.holdsLevel)
    }
}

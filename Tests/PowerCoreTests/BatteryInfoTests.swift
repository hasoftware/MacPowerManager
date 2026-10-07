import XCTest
@testable import PowerCore

final class BatteryInfoTests: XCTestCase {
    func testAppleSiliconValues() {
        let info = BatteryReader.parse([
            "CurrentCapacity": 81, "MaxCapacity": 100,
            "AppleRawCurrentCapacity": 6300, "AppleRawMaxCapacity": 7812, "DesignCapacity": 8694,
            "Temperature": 3071, "Voltage": 12400, "InstantAmperage": 5000,
            "PowerTelemetryData": ["SystemPowerIn": 110_700, "SystemLoad": 81_554],
        ])
        XCTAssertEqual(info.percent, 81)
        XCTAssertEqual(info.maxCapacity, 7812)
        XCTAssertEqual(info.temperature!, 33.95, accuracy: 0.01, "Temperature tính bằng 0,1 K")
        XCTAssertEqual(info.batteryPower, 62, accuracy: 0.01)
        XCTAssertEqual(info.systemLoad!, 81.554 - 62, accuracy: 0.01, "SystemLoad không tính phần sạc vào pin")
        XCTAssertEqual(info.health, 7812.0 / 8694 * 100, accuracy: 0.01)
    }

    func testIntelCapacityInMAh() {
        let info = BatteryReader.parse([
            "CurrentCapacity": 2129, "MaxCapacity": 3896, "DesignCapacity": 4400, "Temperature": 3043,
        ])
        XCTAssertEqual(info.percent, 55)
        XCTAssertEqual(info.maxCapacity, 3896)
        XCTAssertEqual(info.currentCapacity, 2129)
        XCTAssertNil(info.systemLoad, "Intel không có PowerTelemetryData")
    }

    func testImplausibleTemperatureIsDropped() {
        XCTAssertNil(BatteryReader.parse(["Temperature": 0]).temperature)
    }

    func testMinutesToChargeToLimit() {
        var info = BatteryInfo()
        info.percent = 60
        info.maxCapacity = 8000
        info.amperage = 4000
        XCTAssertEqual(info.minutesToCharge(to: 80), 24, "20% của 8000 mAh ở 4000 mA = 24 phút")
        info.amperage = -500
        XCTAssertNil(info.minutesToCharge(to: 80), "Đang xả thì không ước tính")
        info.amperage = 4000
        XCTAssertNil(info.minutesToCharge(to: 50), "Đã vượt giới hạn")
    }
}

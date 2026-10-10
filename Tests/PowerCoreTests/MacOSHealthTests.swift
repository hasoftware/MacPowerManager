import XCTest
@testable import PowerCore

final class MacOSHealthTests: XCTestCase {
    func testParsesSystemProfilerJSON() throws {
        // Rút gọn từ `system_profiler SPPowerDataType -json` trên MacBook Pro M2 Pro (macOS 15.5).
        let json = """
        {"SPPowerDataType":[{"_name":"spbattery_information",
          "sppower_battery_health_info":{"sppower_battery_cycle_count":92,"sppower_battery_health":"Good",
                                         "sppower_battery_health_maximum_capacity":"92%"}},
          {"_name":"sppower_information"}]}
        """
        let health = try XCTUnwrap(MacOSBatteryHealth.parse(Data(json.utf8)))
        XCTAssertEqual(health.maximumCapacityPercent, 92)
        XCTAssertEqual(health.cycleCount, 92)
        XCTAssertEqual(health.condition, "Good")
    }

    func testMissingOrInvalidData() {
        XCTAssertNil(MacOSBatteryHealth.parse(Data("not json".utf8)))
        XCTAssertNil(MacOSBatteryHealth.parse(Data(#"{"SPPowerDataType":[]}"#.utf8)), "Máy để bàn không có pin")
        let weird = #"{"SPPowerDataType":[{"sppower_battery_health_info":{"sppower_battery_health_maximum_capacity":"0%"}}]}"#
        XCTAssertNil(MacOSBatteryHealth.parse(Data(weird.utf8))?.maximumCapacityPercent)
    }

    func testNominalHealth() {
        var b = BatteryInfo()
        b.designCapacity = 8694
        b.nominalCapacity = 7923
        b.maxCapacity = 7679
        XCTAssertEqual(b.nominalHealth!, 91.13, accuracy: 0.01)
        XCTAssertEqual(b.health, 88.33, accuracy: 0.01, "Số đo tức thời")
        b.nominalCapacity = 0
        XCTAssertNil(b.nominalHealth)
    }

    func testLiveTelemetryFixesLaggingChargingState() {
        var b = BatteryInfo()
        b.externalConnected = true
        b.isCharging = false          // IOKit chưa kịp cập nhật
        b.amperage = 0
        let live = b.applyingLiveTelemetry(currentmA: 8452, voltagemV: 12300)
        XCTAssertTrue(live.isCharging)
        XCTAssertEqual(live.amperage, 8452)
        XCTAssertEqual(live.voltage, 12300)

        b.isCharging = true           // IOKit còn báo đang sạc dù helper đã chặn
        XCTAssertFalse(b.applyingLiveTelemetry(currentmA: 0, voltagemV: nil).isCharging)

        b.externalConnected = false
        XCTAssertFalse(b.applyingLiveTelemetry(currentmA: -900, voltagemV: nil).isCharging)
        XCTAssertEqual(b.applyingLiveTelemetry(currentmA: nil, voltagemV: 99).voltage, b.voltage, "Giá trị lạ bị bỏ qua")
    }
}

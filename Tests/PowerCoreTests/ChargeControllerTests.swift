import XCTest
@testable import PowerCore

final class ChargeControllerTests: XCTestCase {
    private func decide(_ percent: Int, temp: Double? = 30, _ config: PowerConfig,
                        _ state: inout ControllerState) -> ControlDecision {
        ChargeController.decide(percent: percent, temperature: temp, config: config, state: &state)
    }

    func testChargesNormallyBelowLimit() {
        var state = ControllerState()
        let d = decide(50, PowerConfig(), &state)
        XCTAssertTrue(d.chargingEnabled)
        XCTAssertTrue(d.adapterEnabled)
        XCTAssertEqual(d.reason, .normal)
    }

    func testStopsAtLimitAndSailsUntilGap() {
        var config = PowerConfig()
        config.chargeLimit = 80
        config.sailingGap = 5
        var state = ControllerState()

        XCTAssertFalse(decide(80, config, &state).chargingEnabled)
        XCTAssertFalse(decide(77, config, &state).chargingEnabled, "Vẫn giữ trong khoảng sailing")
        XCTAssertFalse(decide(75, config, &state).chargingEnabled)
        XCTAssertTrue(decide(74, config, &state).chargingEnabled, "Dưới limit - gap thì sạc lại")
        XCTAssertTrue(decide(78, config, &state).chargingEnabled, "Đang sạc lên thì tiếp tục tới limit")
        XCTAssertFalse(decide(80, config, &state).chargingEnabled)
    }

    func testLimit100MeansNoLimit() {
        var config = PowerConfig()
        config.chargeLimit = 100
        var state = ControllerState()
        XCTAssertTrue(decide(99, config, &state).chargingEnabled)
    }

    func testThermalHysteresis() {
        var config = PowerConfig()
        config.chargeLimitEnabled = false
        config.thermalPauseAbove = 40
        config.thermalResumeBelow = 35
        var state = ControllerState()

        XCTAssertTrue(decide(50, temp: 39, config, &state).chargingEnabled)
        XCTAssertEqual(decide(50, temp: 40, config, &state).reason, .thermal)
        XCTAssertEqual(decide(50, temp: 37, config, &state).reason, .thermal, "Chưa nguội đủ")
        XCTAssertTrue(decide(50, temp: 35, config, &state).chargingEnabled)
    }

    func testThermalDisabledIgnoresTemperature() {
        var config = PowerConfig()
        config.chargeLimitEnabled = false
        config.thermalProtectionEnabled = false
        var state = ControllerState()
        XCTAssertTrue(decide(50, temp: 50, config, &state).chargingEnabled)
    }

    func testManualPause() {
        var config = PowerConfig()
        config.pauseCharging = true
        var state = ControllerState()
        let d = decide(40, config, &state)
        XCTAssertFalse(d.chargingEnabled)
        XCTAssertTrue(d.adapterEnabled)
        XCTAssertEqual(d.reason, .manualPause)
    }

    func testDischargeDisablesAdapterUntilTarget() {
        var config = PowerConfig()
        config.dischargeEnabled = true
        config.dischargeTarget = 60
        var state = ControllerState()

        let d1 = decide(90, config, &state)
        XCTAssertFalse(d1.adapterEnabled)
        XCTAssertFalse(d1.chargingEnabled)
        XCTAssertFalse(d1.dischargeFinished)

        let d2 = decide(60, config, &state)
        XCTAssertTrue(d2.adapterEnabled)
        XCTAssertTrue(d2.dischargeFinished)
        XCTAssertTrue(d2.chargingEnabled, "Xả xong dưới giới hạn thì quay về quy tắc giới hạn bình thường")

        // Xả về đúng mốc giới hạn thì giữ nguyên, không sạc lại.
        config.dischargeTarget = 80
        state = ControllerState()
        XCTAssertFalse(decide(95, config, &state).adapterEnabled)
        let d3 = decide(80, config, &state)
        XCTAssertTrue(d3.adapterEnabled)
        XCTAssertFalse(d3.chargingEnabled)
    }

    func testCriticalBatteryAlwaysCharges() {
        var config = PowerConfig()
        config.pauseCharging = true
        config.dischargeEnabled = true
        config.dischargeTarget = 5
        var state = ControllerState()
        let d = decide(PowerConstants.criticalPercent, temp: 50, config, &state)
        XCTAssertTrue(d.chargingEnabled)
        XCTAssertTrue(d.adapterEnabled)
        XCTAssertEqual(d.reason, .critical)
    }

    func testSanitizeClampsValues() {
        var config = PowerConfig()
        config.chargeLimit = 5
        config.dischargeTarget = 1
        config.thermalPauseAbove = 38
        config.thermalResumeBelow = 45
        let s = config.sanitized()
        XCTAssertEqual(s.chargeLimit, 20)
        XCTAssertGreaterThan(s.dischargeTarget, PowerConstants.criticalPercent)
        XCTAssertLessThan(s.thermalResumeBelow, s.thermalPauseAbove)
    }
}

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
        XCTAssertEqual(d.effectiveLimit, 80)
        XCTAssertEqual(d.effects, [])
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

    func testHoldingVsSailingReasons() {
        var h = ControllerHarness { $0.chargeLimit = 80; $0.sailingGap = 5 }
        XCTAssertEqual(h.step(79).reason, .normal)
        XCTAssertEqual(h.step(80).reason, .limitReached)
        XCTAssertEqual(h.step(83).reason, .limitReached, "Trên giới hạn vẫn là giữ mức")
        XCTAssertEqual(h.step(79).reason, .sailing, "Dưới giới hạn, trong khoảng sailing")
        XCTAssertEqual(h.step(75).reason, .sailing, "Đúng mốc limit - gap vẫn chờ")
        XCTAssertTrue(h.state.holdingAtLimit)
        let resumed = h.step(74)
        XCTAssertEqual(resumed.reason, .normal)
        XCTAssertTrue(resumed.chargingEnabled)
        XCTAssertFalse(h.state.holdingAtLimit)
        XCTAssertEqual(h.step(79).reason, .normal, "Đang sạc lên không bị coi là sailing")
    }

    func testHoldingStatePersistsAcrossTicks() {
        var h = ControllerHarness { $0.chargeLimit = 60; $0.sailingGap = 10 }
        h.step(60)
        for p in stride(from: 60, through: 50, by: -1) {
            XCTAssertFalse(h.step(p).chargingEnabled, "\(p)% vẫn trong khoảng sailing")
        }
        XCTAssertTrue(h.step(49).chargingEnabled)
    }

    func testLimit100MeansNoLimit() {
        var config = PowerConfig()
        config.chargeLimit = 100
        var state = ControllerState()
        let d = decide(99, config, &state)
        XCTAssertTrue(d.chargingEnabled)
        XCTAssertEqual(d.effectiveLimit, 100)
        XCTAssertEqual(decide(100, config, &state).reason, .normal, "Giới hạn 100% không bao giờ giữ mức")
        XCTAssertFalse(state.holdingAtLimit)
    }

    func testLimitDisabledNeverHolds() {
        var config = PowerConfig()
        config.chargeLimitEnabled = false
        var state = ControllerState()
        state.holdingAtLimit = true
        state.chargeToLimitOnce = true
        let d = decide(90, config, &state)
        XCTAssertEqual(d.reason, .normal)
        XCTAssertEqual(d.effectiveLimit, 100)
        XCTAssertFalse(state.holdingAtLimit)
        XCTAssertFalse(state.chargeToLimitOnce, "Tắt giới hạn thì bỏ lệnh sạc tới giới hạn")
    }

    func testUnsanitizedLimitIsClamped() {
        var config = PowerConfig()
        config.chargeLimit = 5
        var state = ControllerState()
        let d = decide(30, config, &state)
        XCTAssertEqual(d.effectiveLimit, 20, "Giới hạn luôn được kẹp về 20...100")
        XCTAssertEqual(d.reason, .limitReached)

        config.chargeLimit = 250
        state = ControllerState()
        let high = decide(99, config, &state)
        XCTAssertEqual(high.effectiveLimit, 100)
        XCTAssertTrue(high.chargingEnabled)
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

    func testMissingOrInvalidTemperatureNeverPauses() {
        var config = PowerConfig()
        config.chargeLimitEnabled = false
        var state = ControllerState()
        XCTAssertEqual(decide(50, temp: 45, config, &state).reason, .thermal)
        XCTAssertEqual(decide(50, temp: nil, config, &state).reason, .normal, "Mất cảm biến thì không chặn sạc")
        XCTAssertFalse(state.thermalPaused)
        XCTAssertEqual(decide(50, temp: .nan, config, &state).reason, .normal)
        XCTAssertEqual(decide(50, temp: .infinity, config, &state).reason, .normal)
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

    func testThermalReasonTakesPriorityOverPause() {
        var config = PowerConfig()
        config.pauseCharging = true
        var state = ControllerState()
        let d = decide(50, temp: 45, config, &state)
        XCTAssertEqual(d.reason, .thermal)
        XCTAssertFalse(d.chargingEnabled)
        XCTAssertTrue(d.adapterEnabled)
    }

    func testPauseBeatsLimitHoldingReason() {
        var config = PowerConfig()
        config.pauseCharging = true
        var state = ControllerState()
        XCTAssertEqual(decide(85, config, &state).reason, .manualPause)
        XCTAssertTrue(state.holdingAtLimit, "Vẫn ghi nhận giữ mức để khi bỏ tạm dừng không sạc vượt")
        config.pauseCharging = false
        XCTAssertEqual(decide(85, config, &state).reason, .limitReached)
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
        XCTAssertEqual(d3.reason, .limitReached)
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
        XCTAssertTrue(d.dischargeFinished, "Đang xả thì kết thúc xả")
    }

    func testCompatibilityWrapperMatchesInputAPI() {
        var config = PowerConfig()
        config.chargeLimit = 70
        var a = ControllerState(), b = ControllerState()
        for p in [50, 70, 68, 64, 66, 70, 15, 9] {
            let viaWrapper = decide(p, config, &a)
            let viaInput = ChargeController.decide(input: ControllerInput(now: testEpoch, percent: p, temperature: 30),
                                                   config: config, state: &b)
            XCTAssertEqual(viaWrapper, viaInput, "\(p)%")
            XCTAssertEqual(a, b)
        }
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

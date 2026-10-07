import XCTest
@testable import PowerCore

/// "Sạc tới giới hạn ngay" và các thay đổi trạng thái khi đổi cấu hình.
final class ControllerCommandsTests: XCTestCase {
    // MARK: chargeToLimitNow

    func testChargeToLimitNowLifecycle() {
        var h = ControllerHarness { $0.chargeLimit = 80; $0.sailingGap = 5 }
        XCTAssertEqual(h.step(80).reason, .limitReached)
        XCTAssertEqual(h.step(77).reason, .sailing)

        XCTAssertTrue(ControllerCommands.chargeToLimitNow(state: &h.state, config: h.config))
        XCTAssertTrue(h.state.chargeToLimitOnce)
        XCTAssertFalse(h.state.holdingAtLimit)

        let charging = h.step(77)
        XCTAssertEqual(charging.reason, .normal, "Bỏ qua khoảng sailing")
        XCTAssertTrue(charging.chargingEnabled)
        XCTAssertEqual(charging.effects, [])
        XCTAssertEqual(h.step(79).reason, .normal)

        let done = h.step(80)
        XCTAssertEqual(done.reason, .limitReached)
        XCTAssertEqual(done.effects, [.chargeToLimitDone])
        XCTAssertFalse(h.state.chargeToLimitOnce, "Tự tắt khi đạt giới hạn")

        XCTAssertEqual(h.step(80).effects, [], "Chỉ báo xong một lần")
        XCTAssertEqual(h.step(78).reason, .sailing, "Sau đó khoảng sailing hoạt động lại bình thường")
    }

    func testChargeToLimitNowAboveLimitCompletesImmediately() {
        var h = ControllerHarness { $0.chargeLimit = 80 }
        h.step(85)
        ControllerCommands.chargeToLimitNow(state: &h.state, config: h.config)
        let d = h.step(85)
        XCTAssertEqual(d.reason, .limitReached)
        XCTAssertEqual(d.effects, [.chargeToLimitDone])
        XCTAssertTrue(h.state.holdingAtLimit)
    }

    func testChargeToLimitNowSurvivesPauseAndHeat() {
        var h = ControllerHarness { $0.chargeLimit = 80 }
        h.step(80)
        h.step(77)
        ControllerCommands.chargeToLimitNow(state: &h.state, config: h.config)
        h.config.pauseCharging = true
        XCTAssertEqual(h.step(77).reason, .manualPause)
        h.config.pauseCharging = false
        h.temperature = 45
        XCTAssertEqual(h.step(77).reason, .thermal)
        XCTAssertTrue(h.state.chargeToLimitOnce, "Lệnh vẫn chờ cho tới khi đạt giới hạn")
        h.temperature = 30
        XCTAssertEqual(h.step(77).reason, .normal)
    }

    func testChargeToLimitNowNoOpWhenLimitDisabledOr100() {
        var state = ControllerState()
        state.holdingAtLimit = true
        var config = PowerConfig()
        config.chargeLimitEnabled = false
        XCTAssertFalse(ControllerCommands.chargeToLimitNow(state: &state, config: config))
        config.chargeLimitEnabled = true
        config.chargeLimit = 100
        XCTAssertFalse(ControllerCommands.chargeToLimitNow(state: &state, config: config))
        XCTAssertFalse(state.chargeToLimitOnce)
        XCTAssertTrue(state.holdingAtLimit, "Không làm gì")
    }

    func testChargeToLimitNowNoOpDuringTopUp() {
        var h = ControllerHarness()
        h.startTopUp()
        XCTAssertFalse(ControllerCommands.chargeToLimitNow(state: &h.state, config: h.config))
        ControllerCommands.chargeToLimitNow(state: &h.state)
        XCTAssertFalse(h.state.chargeToLimitOnce)
        XCTAssertEqual(h.step(85).effects, [], "Không báo xong giả khi Top Up vượt giới hạn")
    }

    func testLegacyChargeToLimitFlagDroppedWhenLimitDisabled() {
        var h = ControllerHarness { $0.chargeLimitEnabled = false }
        ControllerCommands.chargeToLimitNow(state: &h.state)
        XCTAssertTrue(h.state.chargeToLimitOnce)
        let d = h.step(60)
        XCTAssertFalse(h.state.chargeToLimitOnce, "decide tự bỏ cờ khi không có giới hạn")
        XCTAssertEqual(d.effects, [])
    }

    func testChargeToLimitFlagIgnoredByTopUpInDecide() {
        var h = ControllerHarness()
        h.startTopUp()
        h.state.chargeToLimitOnce = true // ví dụ trạng thái cũ từ state.json
        XCTAssertEqual(h.step(85).effects, [])
        XCTAssertFalse(h.state.chargeToLimitOnce)
    }

    // MARK: configDidChange

    func testPauseCancelsTopUp() {
        var h = ControllerHarness()
        h.startTopUp()
        var new = h.config
        new.pauseCharging = true
        XCTAssertEqual(ControllerCommands.configDidChange(from: h.config, to: new, state: &h.state),
                       [.topUpEnded(.cancelled)])
        XCTAssertNil(h.state.topUp)
    }

    func testDischargeCancelsTopUpViaConfig() {
        var h = ControllerHarness()
        h.startTopUp()
        var new = h.config
        new.dischargeEnabled = true
        XCTAssertEqual(ControllerCommands.configDidChange(from: h.config, to: new, state: &h.state),
                       [.topUpEnded(.cancelled)])
    }

    func testUnrelatedChangeKeepsTopUp() {
        var h = ControllerHarness()
        h.startTopUp()
        var new = h.config
        new.chargeLimit = 70
        new.thermalPauseAbove = 45
        XCTAssertEqual(ControllerCommands.configDidChange(from: h.config, to: new, state: &h.state), [])
        XCTAssertNotNil(h.state.topUp)

        // Đã tạm dừng từ trước thì không coi là "vừa bật tạm dừng".
        h.config.pauseCharging = true
        new.pauseCharging = true
        XCTAssertEqual(ControllerCommands.configDidChange(from: h.config, to: new, state: &h.state), [])
        XCTAssertNotNil(h.state.topUp)
    }

    func testRaisingLimitChargesToNewLimit() {
        var h = ControllerHarness { $0.chargeLimit = 80 }
        h.step(80)
        var new = h.config
        new.chargeLimit = 82
        _ = ControllerCommands.configDidChange(from: h.config, to: new, state: &h.state)
        h.config = new
        XCTAssertFalse(h.state.holdingAtLimit)
        XCTAssertEqual(h.step(80).reason, .normal, "Nâng giới hạn thì sạc tiếp tới mức mới")
        XCTAssertEqual(h.step(82).reason, .limitReached)
    }

    func testLoweringLimitKeepsHolding() {
        var h = ControllerHarness { $0.chargeLimit = 80 }
        h.step(80)
        var new = h.config
        new.chargeLimit = 70
        _ = ControllerCommands.configDidChange(from: h.config, to: new, state: &h.state)
        h.config = new
        XCTAssertTrue(h.state.holdingAtLimit)
        XCTAssertEqual(h.step(80).reason, .limitReached)
    }

    func testDisablingLimitClearsChargeToLimit() {
        var state = ControllerState()
        state.chargeToLimitOnce = true
        var off = PowerConfig()
        off.chargeLimitEnabled = false
        _ = ControllerCommands.configDidChange(from: PowerConfig(), to: off, state: &state)
        XCTAssertFalse(state.chargeToLimitOnce)
    }

    func testReenablingLimitAppliesFromCurrentLevel() {
        // Bật lại giới hạn giống hạ giới hạn từ 100%: trên mốc thì giữ, dưới mốc thì sạc tới mốc.
        var h = ControllerHarness { $0.chargeLimitEnabled = false }
        XCTAssertEqual(h.step(90).reason, .normal)
        var on = h.config
        on.chargeLimitEnabled = true
        XCTAssertEqual(ControllerCommands.configDidChange(from: h.config, to: on, state: &h.state), [])
        h.config = on
        XCTAssertEqual(h.step(90).reason, .limitReached)

        var low = ControllerHarness { $0.chargeLimitEnabled = false }
        low.step(77)
        _ = ControllerCommands.configDidChange(from: low.config, to: on, state: &low.state)
        low.config = on
        XCTAssertEqual(low.step(77).reason, .normal)
    }
}

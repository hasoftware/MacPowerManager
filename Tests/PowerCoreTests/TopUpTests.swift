import XCTest
@testable import PowerCore

/// I5: sạc đầy một lần (Top Up).
final class TopUpTests: XCTestCase {
    // MARK: Lệnh bắt đầu / hủy

    func testRefusedWhenUnplugged() {
        var h = ControllerHarness()
        h.acPresent = false
        XCTAssertEqual(h.startTopUp(), .notPluggedIn)
        XCTAssertNil(h.state.topUp)
    }

    func testStartRecordsBootAndDefaultExpiry() throws {
        var h = ControllerHarness()
        XCTAssertNil(h.startTopUp())
        let topUp = try XCTUnwrap(h.state.topUp)
        XCTAssertEqual(topUp.startedAt, h.now)
        XCTAssertEqual(topUp.bootSessionUUID, "BOOT-A")
        XCTAssertEqual(topUp.expiresAt.timeIntervalSince(topUp.startedAt),
                       TimeInterval(PowerConstants.topUpDefaultHours * 3600))
    }

    func testStartClampsHours() throws {
        let cases: [(Int?, Int)] = [(nil, 24), (0, 1), (-5, 1), (1, 1), (12, 12), (72, 72), (100, 72),
                                    (Int.max, 72), (Int.min, 1)]
        for (hours, expected) in cases {
            var state = ControllerState()
            XCTAssertNil(ControllerCommands.startTopUp(state: &state, now: testEpoch, hours: hours,
                                                       acPresent: true, bootSessionUUID: "B"))
            let topUp = try XCTUnwrap(state.topUp)
            XCTAssertEqual(topUp.expiresAt.timeIntervalSince(testEpoch), TimeInterval(expected * 3600),
                           "hours = \(String(describing: hours))")
        }
    }

    func testStartClearsChargeToLimitAndHolding() {
        var h = ControllerHarness()
        h.state.holdingAtLimit = true
        h.state.chargeToLimitOnce = true
        h.startTopUp()
        XCTAssertFalse(h.state.holdingAtLimit)
        XCTAssertFalse(h.state.chargeToLimitOnce)
    }

    func testCancel() {
        var h = ControllerHarness()
        XCTAssertFalse(ControllerCommands.cancelTopUp(state: &h.state), "Không có gì để hủy")
        h.startTopUp()
        XCTAssertTrue(ControllerCommands.cancelTopUp(state: &h.state))
        XCTAssertNil(h.state.topUp)
        let d = h.step(85)
        XCTAssertEqual(d.reason, .limitReached, "Hủy xong thì giới hạn quay lại")
        XCTAssertEqual(d.effectiveLimit, 80)
    }

    func testConfigForTopUpCancelsPauseAndDischarge() {
        var config = PowerConfig()
        config.pauseCharging = true
        config.dischargeEnabled = true
        let c = ControllerCommands.configForTopUp(config)
        XCTAssertFalse(c.pauseCharging)
        XCTAssertFalse(c.dischargeEnabled)
        XCTAssertEqual(c.chargeLimit, config.chargeLimit)
    }

    // MARK: Khi đang sạc đầy

    func testChargesPastLimitIgnoringSailing() {
        var h = ControllerHarness { $0.chargeLimit = 80 }
        XCTAssertEqual(h.step(80).reason, .limitReached)
        XCTAssertEqual(h.step(78).reason, .sailing)
        h.startTopUp()
        for p in [78, 80, 85, 99] {
            let d = h.step(p)
            XCTAssertEqual(d.reason, .topUp, "\(p)%")
            XCTAssertTrue(d.chargingEnabled)
            XCTAssertTrue(d.adapterEnabled)
            XCTAssertEqual(d.effectiveLimit, 100)
            XCTAssertEqual(d.effects, [])
        }
    }

    func testStaysTopUpAt100() {
        var h = ControllerHarness()
        h.startTopUp()
        for _ in 0..<5 {
            let d = h.step(100)
            XCTAssertEqual(d.reason, .topUp, "Đầy rồi vẫn giữ sạc bật, không kết thúc")
            XCTAssertTrue(d.chargingEnabled)
            XCTAssertEqual(d.effects, [])
        }
        XCTAssertNotNil(h.state.topUp)
    }

    func testHeatPausesTopUp() {
        var h = ControllerHarness()
        h.startTopUp()
        h.temperature = 42
        let hot = h.step(85)
        XCTAssertEqual(hot.reason, .thermal)
        XCTAssertFalse(hot.chargingEnabled)
        XCTAssertEqual(hot.effectiveLimit, 100)
        XCTAssertNotNil(h.state.topUp, "Nóng chỉ tạm dừng, không hủy sạc đầy")
        h.temperature = 37
        XCTAssertEqual(h.step(85).reason, .thermal, "Chưa nguội đủ")
        h.temperature = 34
        XCTAssertEqual(h.step(85).reason, .topUp)
    }

    func testManualPauseDuringTopUp() {
        var h = ControllerHarness()
        h.startTopUp()
        h.config.pauseCharging = true
        let d = h.step(85)
        XCTAssertEqual(d.reason, .manualPause)
        XCTAssertFalse(d.chargingEnabled)
        XCTAssertEqual(d.effectiveLimit, 100)
    }

    func testLidClosedDoesNotEndTopUp() {
        var h = ControllerHarness()
        h.startTopUp()
        h.lidClosed = true
        XCTAssertEqual(h.step(85).reason, .topUp)
    }

    // MARK: Kết thúc

    func testUnplugEndsTopUpAndLimitReturns() {
        var h = ControllerHarness()
        h.startTopUp()
        XCTAssertEqual(h.step(90).reason, .topUp)
        h.acPresent = false
        let d = h.step(90)
        XCTAssertEqual(d.effects, [.topUpEnded(.unplugged)])
        XCTAssertNil(h.state.topUp)
        XCTAssertEqual(d.effectiveLimit, 80)
        XCTAssertEqual(d.reason, .limitReached)
        XCTAssertEqual(h.step(90).effects, [], "Chỉ báo kết thúc một lần")
        h.acPresent = true
        XCTAssertEqual(h.step(90).reason, .limitReached, "Cắm lại không tự bật lại sạc đầy")
    }

    func testNewBootEndsTopUp() {
        var h = ControllerHarness()
        h.startTopUp()
        h.bootSessionUUID = "BOOT-B"
        let d = h.step(60)
        XCTAssertEqual(d.effects, [.topUpEnded(.newBoot)])
        XCTAssertNil(h.state.topUp)
        XCTAssertEqual(d.reason, .normal)
    }

    func testEmptyBootUUIDNeverEndsTopUp() {
        var h = ControllerHarness()
        h.startTopUp()
        h.bootSessionUUID = ""
        XCTAssertEqual(h.step(60).reason, .topUp, "Không đọc được boot UUID hiện tại")

        var h2 = ControllerHarness()
        h2.bootSessionUUID = ""
        h2.startTopUp()
        h2.bootSessionUUID = "BOOT-B"
        XCTAssertEqual(h2.step(60).reason, .topUp, "Không biết boot UUID lúc bắt đầu")
    }

    func testExpiryEndsTopUp() throws {
        var h = ControllerHarness()
        h.startTopUp(hours: 1)
        let expiresAt = try XCTUnwrap(h.state.topUp?.expiresAt)
        let before = h.step(90, after: 3599)
        XCTAssertEqual(before.reason, .topUp, "Còn 1 giây")
        XCTAssertLessThan(h.now, expiresAt)
        let at = h.step(90, after: 1)
        XCTAssertEqual(h.now, expiresAt)
        XCTAssertEqual(at.effects, [.topUpEnded(.expired)], "Đúng thời điểm hết hạn thì kết thúc")
        XCTAssertEqual(at.reason, .limitReached)
    }

    func testDischargeCancelsTopUp() {
        var h = ControllerHarness()
        h.startTopUp()
        h.config.dischargeEnabled = true
        h.config.dischargeTarget = 60
        let d = h.step(90)
        XCTAssertEqual(d.effects, [.topUpEnded(.cancelled)])
        XCTAssertEqual(d.reason, .discharging)
        XCTAssertFalse(d.adapterEnabled)
        XCTAssertEqual(d.effectiveLimit, 80)
    }

    func testEndReasonPriority() {
        // Nhiều lý do cùng lúc: khởi động lại > hết hạn > rút sạc > hủy.
        var h = ControllerHarness()
        h.startTopUp(hours: 1)
        h.bootSessionUUID = "BOOT-B"
        h.acPresent = false
        XCTAssertEqual(h.step(50, after: 7200).effects, [.topUpEnded(.newBoot)])

        var h2 = ControllerHarness()
        h2.startTopUp(hours: 1)
        h2.acPresent = false
        h2.config.dischargeEnabled = true
        XCTAssertEqual(h2.step(50, after: 7200).effects.first, .topUpEnded(.expired))

        var h3 = ControllerHarness()
        h3.startTopUp()
        h3.acPresent = false
        h3.config.dischargeEnabled = true
        XCTAssertEqual(h3.step(90).effects, [.topUpEnded(.unplugged)])
    }

    func testUnplugAtCriticalEndsTopUp() {
        var h = ControllerHarness()
        h.startTopUp()
        h.acPresent = false
        let d = h.step(5)
        XCTAssertEqual(d.reason, .critical)
        XCTAssertEqual(d.effects, [.topUpEnded(.unplugged)], "Top Up không tồn tại khi rút sạc, kể cả lúc pin yếu")
        XCTAssertNil(h.state.topUp)
    }

    func testTopUpBelowLimitAfterEndChargesToLimit() {
        var h = ControllerHarness { $0.chargeLimit = 80; $0.sailingGap = 5 }
        h.startTopUp(hours: 1)
        XCTAssertEqual(h.step(77).reason, .topUp)
        let d = h.step(78, after: 3600)
        XCTAssertEqual(d.effects, [.topUpEnded(.expired)])
        XCTAssertEqual(d.reason, .normal, "Bắt đầu Top Up đã bỏ giữ mức, nên sạc tiếp tới giới hạn")
    }

    func testStatePersistsThroughCodable() throws {
        var h = ControllerHarness()
        h.startTopUp()
        h.step(90)
        let data = try JSONEncoder().encode(h.state)
        let restored = try JSONDecoder().decode(ControllerState.self, from: data)
        XCTAssertEqual(restored, h.state)
        var h2 = h
        h2.state = restored
        XCTAssertEqual(h2.step(95).reason, .topUp, "Helper khởi động lại cùng phiên boot vẫn tiếp tục")
    }
}

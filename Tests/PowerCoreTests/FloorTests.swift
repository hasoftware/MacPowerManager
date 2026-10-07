import XCTest
@testable import PowerCore

/// I1 (mức nguy hiểm) và I3 (mức sàn 20%).
final class FloorTests: XCTestCase {
    // MARK: I1: pin ≤ 10% luôn sạc và bật adapter

    func testCriticalBeatsEverything() {
        var h = ControllerHarness {
            $0.pauseCharging = true
            $0.dischargeEnabled = true
            $0.dischargeTarget = 15
            $0.chargeLimit = 20
        }
        h.temperature = 60
        h.lidClosed = true
        h.state.holdingAtLimit = true
        h.state.thermalPaused = true
        for p in [-5, 0, 1, 5, PowerConstants.criticalPercent] {
            let d = h.step(p)
            XCTAssertEqual(d.reason, .critical, "\(p)%")
            XCTAssertTrue(d.chargingEnabled, "\(p)%")
            XCTAssertTrue(d.adapterEnabled, "\(p)%")
        }
    }

    func testCriticalBeatsTopUpAndKeepsIt() {
        var h = ControllerHarness()
        h.temperature = 50
        XCTAssertNil(h.startTopUp())
        let topUp = h.state.topUp
        let d = h.step(8)
        XCTAssertEqual(d.reason, .critical)
        XCTAssertTrue(d.chargingEnabled && d.adapterEnabled)
        XCTAssertEqual(d.effectiveLimit, 100, "Đang sạc đầy một lần thì giới hạn hiệu lực là 100")
        XCTAssertEqual(h.state.topUp, topUp, "Pin nguy hiểm không hủy sạc đầy một lần")
        XCTAssertEqual(h.step(30).reason, .thermal, "Qua mức nguy hiểm, chống nóng vẫn áp dụng cho Top Up")
    }

    func testCriticalEndsDischargeInSameTick() {
        // Mục tiêu chưa sanitize: helper luôn sanitize, nhưng decide cũng phải an toàn.
        var h = ControllerHarness { $0.dischargeEnabled = true; $0.dischargeTarget = 5 }
        let d = h.step(10)
        XCTAssertEqual(d.reason, .critical)
        XCTAssertEqual(d.effects, [.dischargeFinished])
        XCTAssertTrue(d.adapterEnabled)
    }

    func testJustAboveCriticalFollowsNormalRules() {
        var h = ControllerHarness { $0.pauseCharging = true }
        XCTAssertEqual(h.step(PowerConstants.criticalPercent + 1).reason, .manualPause)
    }

    // MARK: I3: dưới 20%, sailing và chống nóng không chặn sạc

    func testSailingNeverBlocksBelowFloor() {
        // limit 25, gap 10: không có mức sàn thì 15...24% vẫn là sailing.
        var h = ControllerHarness { $0.chargeLimit = 25; $0.sailingGap = 10 }
        XCTAssertEqual(h.step(25).reason, .limitReached)
        XCTAssertEqual(h.step(20).reason, .sailing, "20% chưa dưới mức sàn")
        let d = h.step(19)
        XCTAssertEqual(d.reason, .normal, "19% đang giữ mức thì vẫn sạc")
        XCTAssertTrue(d.chargingEnabled)
        XCTAssertFalse(h.state.holdingAtLimit)
        XCTAssertEqual(h.step(21).reason, .normal, "Sau khi sạc lại thì tiếp tục tới giới hạn")
    }

    func testHoldingAt19PercentCharges() {
        var h = ControllerHarness { $0.chargeLimit = 20; $0.sailingGap = 1 }
        h.state.holdingAtLimit = true
        XCTAssertTrue(h.step(19).chargingEnabled)
        XCTAssertEqual(h.step(20).reason, .limitReached)
    }

    func testThermalNeverBlocksBelowFloor() {
        var h = ControllerHarness { $0.chargeLimitEnabled = false }
        h.temperature = 50
        XCTAssertEqual(h.step(19).reason, .normal)
        XCTAssertTrue(h.step(19).chargingEnabled)
        XCTAssertEqual(h.step(PowerConstants.thermalFloorPercent).reason, .thermal)
        XCTAssertEqual(h.step(19).reason, .normal, "Xuống dưới 20% lại được sạc dù vẫn nóng")
    }

    func testThermalHysteresisSurvivesBelowFloor() {
        var h = ControllerHarness { $0.chargeLimitEnabled = false }
        h.temperature = 45
        XCTAssertEqual(h.step(25).reason, .thermal)
        h.temperature = 38
        XCTAssertEqual(h.step(18).reason, .normal)
        XCTAssertTrue(h.state.thermalPaused, "Trạng thái trễ nhiệt vẫn được giữ, chỉ không áp dụng")
        XCTAssertEqual(h.step(21).reason, .thermal, "Chưa nguội tới mức sạc lại")
        h.temperature = 35
        XCTAssertEqual(h.step(21).reason, .normal)
    }

    func testFloorAppliesDuringTopUp() {
        var h = ControllerHarness()
        h.temperature = 50
        h.startTopUp()
        let d = h.step(15)
        XCTAssertEqual(d.reason, .topUp)
        XCTAssertTrue(d.chargingEnabled)
        XCTAssertEqual(h.step(20).reason, .thermal)
    }

    func testDischargeStillStopsAtTargetBelowFloor() {
        // Mục tiêu xả tối thiểu là 15% (sau sanitize): xả tiếp được dưới 20% nhưng dừng đúng mốc.
        var h = ControllerHarness { $0.dischargeEnabled = true; $0.dischargeTarget = 15 }
        XCTAssertEqual(h.step(18).reason, .discharging)
        let d = h.step(15)
        XCTAssertEqual(d.reason, .normal)
        XCTAssertTrue(d.adapterEnabled)
        XCTAssertEqual(d.effects, [.dischargeFinished])
    }
}

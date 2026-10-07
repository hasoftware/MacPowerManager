import XCTest
@testable import PowerCore

final class DischargeTests: XCTestCase {
    private func harness(target: Int, limit: Int = 80) -> ControllerHarness {
        ControllerHarness {
            $0.dischargeEnabled = true
            $0.dischargeTarget = target
            $0.chargeLimit = limit
        }
    }

    func testCutsAdapterAboveTarget() {
        var h = harness(target: 50)
        let d = h.step(70)
        XCTAssertEqual(d.reason, .discharging)
        XCTAssertFalse(d.adapterEnabled)
        XCTAssertFalse(d.chargingEnabled)
        XCTAssertEqual(d.effects, [])
        XCTAssertEqual(d.effectiveLimit, 80, "Giới hạn hiệu lực vẫn là giới hạn sạc, không phải mục tiêu xả")
    }

    func testFinishesAtTargetWithAdapterBackOnSameTick() {
        var h = harness(target: 50)
        for p in stride(from: 70, through: 51, by: -1) {
            XCTAssertFalse(h.step(p).adapterEnabled, "\(p)%")
        }
        let d = h.step(50)
        XCTAssertTrue(d.adapterEnabled, "Bật lại adapter ngay trong lần đánh giá xả xong")
        XCTAssertEqual(d.effects, [.dischargeFinished])
        XCTAssertEqual(d.reason, .normal)
        XCTAssertTrue(d.chargingEnabled)
    }

    func testFinishAtLimitHolds() {
        var h = harness(target: 80, limit: 80)
        h.step(95)
        let d = h.step(80)
        XCTAssertEqual(d.reason, .limitReached)
        XCTAssertFalse(d.chargingEnabled)
        XCTAssertTrue(d.adapterEnabled)
        XCTAssertTrue(d.dischargeFinished)
    }

    func testFinishInsideSailingBandWaits() {
        var h = harness(target: 77, limit: 80)
        h.step(90)
        let d = h.step(77)
        XCTAssertEqual(d.reason, .sailing, "Đã vượt giới hạn trước khi xả nên vẫn chờ trong khoảng sailing")
        XCTAssertFalse(d.chargingEnabled)
    }

    func testOvershootBelowTargetStillFinishes() {
        var h = harness(target: 60)
        XCTAssertEqual(h.step(55).effects, [.dischargeFinished], "Đã dưới mục tiêu ngay từ đầu")
    }

    func testLidClosedSuspendsDischarge() {
        var h = harness(target: 50)
        XCTAssertEqual(h.step(70).reason, .discharging)
        h.lidClosed = true
        let d = h.step(70)
        XCTAssertEqual(d.reason, .clamshellSuspended)
        XCTAssertTrue(d.adapterEnabled, "Nắp đóng thì không ngắt adapter")
        XCTAssertFalse(d.chargingEnabled)
        XCTAssertEqual(d.effects, [], "Chỉ tạm ngừng, không kết thúc xả")
        h.lidClosed = false
        XCTAssertEqual(h.step(70).reason, .discharging, "Mở nắp thì xả tiếp")
    }

    func testLidClosedAtTargetFinishes() {
        var h = harness(target: 50)
        h.lidClosed = true
        let d = h.step(50)
        XCTAssertEqual(d.effects, [.dischargeFinished])
        XCTAssertTrue(d.adapterEnabled)
    }

    func testDischargeBeatsHeatPauseAndLimit() {
        var h = harness(target: 50)
        h.config.pauseCharging = true
        h.temperature = 50
        let d = h.step(90)
        XCTAssertEqual(d.reason, .discharging)
        XCTAssertFalse(d.adapterEnabled)
        XCTAssertTrue(h.state.thermalPaused, "Trạng thái nhiệt vẫn được theo dõi khi xả")
        let done = h.step(50)
        XCTAssertEqual(done.reason, .thermal, "Xả xong thì các quy tắc khác áp dụng lại")
        XCTAssertTrue(done.adapterEnabled)
    }

    func testCriticalEndsDischarge() {
        var h = harness(target: 50)
        let d = h.step(10)
        XCTAssertEqual(d.reason, .critical)
        XCTAssertTrue(d.adapterEnabled && d.chargingEnabled)
        XCTAssertEqual(d.effects, [.dischargeFinished])
    }

    func testAdapterNeverCutWhenDischargeDisabled() {
        var h = ControllerHarness()
        for p in 0...100 {
            XCTAssertTrue(h.step(p).adapterEnabled, "\(p)%")
        }
    }
}

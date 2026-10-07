import XCTest
@testable import PowerCore

final class SleepGateTests: XCTestCase {
    private func gate(charging: Bool, adapter: Bool = true, currentCharging: Bool?, currentAdapter: Bool? = true,
                      phase: WakePhase, reason: ChargeReason = .normal, holds: Bool = true) -> (charging: Bool, adapter: Bool) {
        SleepGate.constrain(charging: charging, adapter: adapter, currentCharging: currentCharging,
                            currentAdapter: currentAdapter, phase: phase, reason: reason, holdsLevelDuringSleep: holds)
    }

    func testAwakePassesThrough() {
        let r = gate(charging: true, adapter: false, currentCharging: false, phase: .awake)
        XCTAssertTrue(r.charging)
        XCTAssertFalse(r.adapter)
    }

    func testNeverEnablesChargingWhileHoldingLevel() {
        for phase in [WakePhase.sleepPending, .darkWake] {
            XCTAssertFalse(gate(charging: true, currentCharging: false, phase: phase).charging, "\(phase): không được bật lại sạc")
        }
    }

    func testMayStillDisableCharging() {
        XCTAssertFalse(gate(charging: false, currentCharging: true, phase: .darkWake).charging,
                       "Đạt giới hạn trong dark wake thì vẫn được tắt sạc")
    }

    func testNeverCutsAdapterWhileSleeping() {
        XCTAssertTrue(gate(charging: false, adapter: false, currentCharging: false, phase: .sleepPending, reason: .discharging).adapter)
        XCTAssertTrue(gate(charging: false, adapter: true, currentCharging: false, currentAdapter: false, phase: .darkWake).adapter,
                      "Được phép bật lại adapter")
    }

    func testCriticalBatteryAlwaysCharges() {
        let r = gate(charging: true, currentCharging: false, phase: .darkWake, reason: .critical)
        XCTAssertTrue(r.charging, "Pin ≤ 10% luôn được sạc, kể cả khi ngủ")
        XCTAssertTrue(r.adapter)
    }

    func testChargingResumesAfterCoolingWhenNotHoldingLevel() {
        // Đang tạm dừng vì nóng lúc đi ngủ, không có giới hạn: khi nguội trong dark wake phải sạc lại được.
        XCTAssertTrue(gate(charging: true, currentCharging: false, phase: .darkWake, holds: false).charging)
    }

    func testSleepState() {
        var config = PowerConfig()
        config.chargeLimit = 80
        XCTAssertFalse(SleepGate.sleepState(config: config, currentCharging: true, percent: 60).charging, "Giữ mức pin khi ngủ")
        XCTAssertTrue(SleepGate.sleepState(config: config, currentCharging: true, percent: 60).adapter)
        XCTAssertTrue(SleepGate.sleepState(config: config, currentCharging: false, percent: 8).charging, "Pin nguy hiểm luôn sạc")

        config.chargeLimit = 100
        XCTAssertTrue(SleepGate.sleepState(config: config, currentCharging: true, percent: 60).charging, "Không giới hạn thì sạc bình thường")

        config.chargeLimit = 80
        config.disableChargingBeforeSleep = false
        XCTAssertTrue(SleepGate.sleepState(config: config, currentCharging: true, percent: 60).charging)
        XCTAssertFalse(SleepGate.sleepState(config: config, currentCharging: false, percent: 60).charging,
                       "Không bật sạc lúc sắp ngủ nếu đang tắt (ví dụ đang nóng)")
    }

    func testHoldsLevelDuringSleep() {
        var config = PowerConfig()
        XCTAssertTrue(SleepGate.holdsLevelDuringSleep(config))
        config.disableChargingBeforeSleep = false
        XCTAssertFalse(SleepGate.holdsLevelDuringSleep(config))
    }
}

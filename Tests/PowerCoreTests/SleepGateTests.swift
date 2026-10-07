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

    func testCutAdapterIsReenabledWhileAsleep() {
        // Adapter vẫn đang bị ngắt (ví dụ lệnh bật lại lúc WillSleep thất bại): phải bật lại, không giữ ngắt.
        for phase in [WakePhase.sleepPending, .darkWake] {
            XCTAssertTrue(gate(charging: false, adapter: false, currentCharging: false, currentAdapter: false,
                               phase: phase, reason: .discharging).adapter, "\(phase)")
        }
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

    // MARK: Sạc đầy một lần (giới hạn hiệu lực 100%)

    func testTopUpDoesNotHoldLevel() {
        let config = PowerConfig()
        XCTAssertFalse(SleepGate.holdsLevelDuringSleep(config, topUpActive: true))
        var state = ControllerState()
        XCTAssertTrue(SleepGate.holdsLevelDuringSleep(config, state: state))
        XCTAssertNil(ControllerCommands.startTopUp(state: &state, now: testEpoch, hours: nil, acPresent: true,
                                                   bootSessionUUID: "B"))
        XCTAssertFalse(SleepGate.holdsLevelDuringSleep(config, state: state))
    }

    func testSleepStateAllowsChargingDuringTopUp() {
        let config = PowerConfig()
        let r = SleepGate.sleepState(config: config, currentCharging: true, percent: 85, topUpActive: true)
        XCTAssertTrue(r.charging, "Đang sạc đầy một lần thì vẫn sạc khi ngủ")
        XCTAssertTrue(r.adapter)
        XCTAssertFalse(SleepGate.sleepState(config: config, currentCharging: false, percent: 85, topUpActive: true).charging,
                       "Đang tạm dừng vì nóng lúc đi ngủ thì không bật sạc")
        XCTAssertFalse(SleepGate.sleepState(config: config, currentCharging: true, percent: 85, topUpActive: false).charging)
    }

    func testSleepStateStateOverloadMatches() {
        var state = ControllerState()
        state.topUp = TopUpState(startedAt: testEpoch, expiresAt: testEpoch.addingTimeInterval(3600), bootSessionUUID: "B")
        let config = PowerConfig()
        let viaState = SleepGate.sleepState(config: config, currentCharging: true, percent: 70, state: state)
        let viaFlag = SleepGate.sleepState(config: config, currentCharging: true, percent: 70, topUpActive: true)
        XCTAssertEqual(viaState.charging, viaFlag.charging)
        XCTAssertEqual(viaState.adapter, viaFlag.adapter)
    }

    func testDarkWakeMayEnableChargingDuringTopUp() {
        let config = PowerConfig()
        let holds = SleepGate.holdsLevelDuringSleep(config, topUpActive: true)
        let r = gate(charging: true, currentCharging: false, phase: .darkWake, reason: .topUp, holds: holds)
        XCTAssertTrue(r.charging, "Top Up hết nóng trong dark wake thì sạc tiếp")
        XCTAssertTrue(r.adapter)
    }

    func testDecisionThroughGateDuringTopUpBeforeSleep() {
        var h = ControllerHarness()
        h.startTopUp()
        let d = h.step(85)
        let holds = SleepGate.holdsLevelDuringSleep(h.config, state: h.state)
        let r = SleepGate.constrain(charging: d.chargingEnabled, adapter: d.adapterEnabled, currentCharging: true,
                                    currentAdapter: true, phase: .sleepPending, reason: d.reason,
                                    holdsLevelDuringSleep: holds)
        XCTAssertTrue(r.charging)
        XCTAssertTrue(r.adapter)
    }

    func testSleepStateCriticalAlwaysCharges() {
        var config = PowerConfig()
        config.pauseCharging = true
        for topUp in [false, true] {
            let r = SleepGate.sleepState(config: config, currentCharging: false, percent: 10, topUpActive: topUp)
            XCTAssertTrue(r.charging)
            XCTAssertTrue(r.adapter)
        }
    }

    /// I4: trước khi ngủ adapter luôn bật; khi ngủ/thức ngầm không bao giờ ngắt adapter.
    func testAdapterAlwaysOnBeforeSleepSweep() {
        for limitEnabled in [false, true] {
            for limit in [20, 80, 100] {
                for pause in [false, true] {
                    for discharge in [false, true] {
                        for before in [false, true] {
                            var config = PowerConfig()
                            config.chargeLimitEnabled = limitEnabled
                            config.chargeLimit = limit
                            config.pauseCharging = pause
                            config.dischargeEnabled = discharge
                            config.disableChargingBeforeSleep = before
                            for current in [nil, false, true] as [Bool?] {
                                for percent in [nil, 5, 50, 95] as [Int?] {
                                    for topUp in [false, true] {
                                        let r = SleepGate.sleepState(config: config, currentCharging: current,
                                                                     percent: percent, topUpActive: topUp)
                                        XCTAssertTrue(r.adapter)
                                        if current == false, (percent ?? 100) > PowerConstants.criticalPercent {
                                            XCTAssertFalse(r.charging, "Không bật sạc lúc sắp ngủ")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func testGateNeverCutsAdapterOrReenablesChargingWhileAsleep() {
        let reasons: [ChargeReason] = [.normal, .limitReached, .sailing, .manualPause, .thermal, .discharging,
                                       .topUp, .clamshellSuspended]
        for phase in [WakePhase.sleepPending, .darkWake] {
            for reason in reasons {
                for wantCharging in [false, true] {
                    for wantAdapter in [false, true] {
                        for current in [nil, false, true] as [Bool?] {
                            for currentAdapter in [nil, false, true] as [Bool?] {
                                let r = gate(charging: wantCharging, adapter: wantAdapter, currentCharging: current,
                                             currentAdapter: currentAdapter, phase: phase, reason: reason, holds: true)
                                XCTAssertTrue(r.adapter, "\(phase) \(reason)")
                                if current != true { XCTAssertFalse(r.charging, "\(phase) \(reason)") }
                            }
                        }
                    }
                }
            }
        }
    }
}

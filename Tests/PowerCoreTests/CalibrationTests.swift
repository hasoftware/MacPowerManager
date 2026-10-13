import XCTest
@testable import PowerCore

final class CalibrationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var config: PowerConfig {
        var c = PowerConfig()
        c.chargeLimit = 80
        return c
    }

    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    private func run(_ state: inout ControllerState, minutes: Double, percent: Int, ac: Bool = true, lid: Bool = false,
                     temperature: Double = 30, config: PowerConfig? = nil) -> ControlDecision {
        ChargeController.decide(input: ControllerInput(now: at(minutes), percent: percent, temperature: temperature,
                                                       acPresent: ac, lidClosed: lid, bootSessionUUID: "boot"),
                                config: config ?? self.config, state: &state)
    }

    private func started(adapterSupported: Bool = true) -> ControllerState {
        var state = ControllerState()
        state.holdingAtLimit = true
        XCTAssertNil(ControllerCommands.startCalibration(state: &state, now: t0, acPresent: true, adapterSupported: adapterSupported))
        return state
    }

    func testFullCycle() {
        var state = started()
        // Bước 1: sạc tới 100% dù giới hạn 80%.
        var d = run(&state, minutes: 1, percent: 80)
        XCTAssertTrue(d.chargingEnabled)
        XCTAssertEqual(d.reason, .calibrating)
        XCTAssertEqual(d.effectiveLimit, 100)
        d = run(&state, minutes: 60, percent: 100)
        XCTAssertEqual(state.calibration?.phase, .holdFull)
        XCTAssertTrue(d.effects.contains(.calibrationPhase(.holdFull)))
        XCTAssertTrue(d.chargingEnabled, "Giữ 100% với sạc bật")

        // Giữ 1 giờ rồi sang bước xả: ngắt adapter.
        d = run(&state, minutes: 119, percent: 100)
        XCTAssertEqual(state.calibration?.phase, .holdFull)
        d = run(&state, minutes: 120, percent: 100)
        XCTAssertEqual(state.calibration?.phase, .discharge)
        XCTAssertFalse(d.chargingEnabled)
        XCTAssertFalse(d.adapterEnabled)
        XCTAssertEqual(state.dischargeStartedAt, at(120))

        // Xả tới 15% thì sạc lại.
        d = run(&state, minutes: 300, percent: 15)
        XCTAssertEqual(state.calibration?.phase, .recharge)
        XCTAssertTrue(d.chargingEnabled)
        XCTAssertTrue(d.adapterEnabled)
        XCTAssertNil(state.dischargeStartedAt)

        d = run(&state, minutes: 420, percent: 100)
        XCTAssertEqual(state.calibration?.phase, .holdFinal)
        d = run(&state, minutes: 480, percent: 100)
        XCTAssertNil(state.calibration)
        XCTAssertEqual(state.lastCalibrationAt, at(480))
        XCTAssertTrue(d.effects.contains(.calibrationEnded(.finished)))
        // Trở về giới hạn 80%: pin đang 100% nên giữ mức, không sạc.
        XCTAssertFalse(d.chargingEnabled)
        XCTAssertEqual(d.effectiveLimit, 80)
    }

    func testHoldTimerOnlyCountsWhilePluggedAndRefillsWhenDropped() {
        var state = started()
        _ = run(&state, minutes: 0, percent: 100)
        XCTAssertEqual(state.calibration?.phase, .holdFull)
        _ = run(&state, minutes: 50, percent: 99, ac: false)
        _ = run(&state, minutes: 70, percent: 99)
        XCTAssertEqual(state.calibration?.phase, .holdFull, "Rút sạc thì đếm lại thời gian giữ")
        _ = run(&state, minutes: 80, percent: 93, ac: false)
        XCTAssertEqual(state.calibration?.phase, .chargeToFull, "Tụt dưới 95% thì sạc đầy lại")
    }

    func testDischargeLeaseRestsAdapterThenResumes() {
        var state = started()
        state.calibration?.phase = .discharge
        var d = run(&state, minutes: 0, percent: 90)
        XCTAssertFalse(d.adapterEnabled)
        // Hết hạn thuê 6 giờ: bật lại adapter 2 phút để đọc lại trạng thái cắm sạc.
        d = run(&state, minutes: 360, percent: 40)
        XCTAssertTrue(d.adapterEnabled)
        XCTAssertFalse(d.chargingEnabled)
        XCTAssertEqual(state.calibration?.phase, .discharge, "Không hủy hiệu chuẩn")
        d = run(&state, minutes: 361, percent: 40)
        XCTAssertTrue(d.adapterEnabled)
        d = run(&state, minutes: 362.5, percent: 40)
        XCTAssertFalse(d.adapterEnabled, "Thuê lại sau khi nghỉ")
        XCTAssertEqual(state.dischargeStartedAt, at(362.5))
    }

    func testDischargeWithoutAdapterCutWaitsForUnplug() {
        var state = started(adapterSupported: false)
        state.calibration?.phase = .discharge
        var d = run(&state, minutes: 0, percent: 90)
        XCTAssertTrue(d.adapterEnabled, "Không ngắt được adapter")
        XCTAssertFalse(d.chargingEnabled, "Nhưng không sạc thêm")
        d = run(&state, minutes: 10, percent: 89, ac: false)
        XCTAssertFalse(d.chargingEnabled)
        XCTAssertEqual(state.calibration?.phase, .discharge)
    }

    func testLidClosedSuspendsDischarge() {
        var state = started()
        state.calibration?.phase = .discharge
        let d = run(&state, minutes: 0, percent: 70, lid: true)
        XCTAssertTrue(d.adapterEnabled)
        XCTAssertEqual(d.reason, .clamshellSuspended)
    }

    func testCriticalAndThermalStillWin() {
        var state = started()
        state.calibration?.phase = .discharge
        XCTAssertEqual(run(&state, minutes: 0, percent: 9).reason, .critical)

        var heated = started()
        let d = run(&heated, minutes: 0, percent: 60, temperature: 45)
        XCTAssertEqual(d.reason, .thermal)
        XCTAssertFalse(d.chargingEnabled)
    }

    func testCancelAndExpire() {
        var state = started()
        var pause = config
        pause.pauseCharging = true
        let effects = ControllerCommands.configDidChange(from: config, to: pause, state: &state)
        XCTAssertEqual(effects, [.calibrationEnded(.cancelled)])
        XCTAssertNil(state.calibration)

        state = started()
        let d = run(&state, minutes: 48 * 60 + 1, percent: 70)
        XCTAssertNil(state.calibration)
        XCTAssertTrue(d.effects.contains(.calibrationEnded(.expired)))
        XCTAssertNil(state.lastCalibrationAt)
    }

    func testStartRequiresACAndBlocksTopUpAndSchedule() {
        var state = ControllerState()
        XCTAssertEqual(ControllerCommands.startCalibration(state: &state, now: t0, acPresent: false, adapterSupported: true),
                       .notPluggedIn)
        state = started()
        XCTAssertEqual(ControllerCommands.startTopUp(state: &state, now: t0, hours: 4, acPresent: true, bootSessionUUID: "boot"),
                       .invalidArgument)
        var scheduled = config
        scheduled.fullChargeSchedule = ChargeSchedule(enabled: true, weekdays: Set(1...7), hour: 0, minute: 0)
        let input = ControllerInput(now: Calendar.current.startOfDay(for: t0).addingTimeInterval(86_400 - 600), percent: 80,
                                    temperature: 30, bootSessionUUID: "boot")
        XCTAssertNil(ScheduledCharge.startIfDue(state: &state, config: scheduled, input: input))
        XCTAssertTrue(ControllerCommands.cancelCalibration(state: &state))
        XCTAssertFalse(ControllerCommands.cancelCalibration(state: &state))
    }

    func testSleepGateAllowsChargingOnlyInChargingPhases() {
        var c = config
        c.disableChargingBeforeSleep = true
        var state = started()
        XCTAssertFalse(SleepGate.holdsLevelDuringSleep(c, state: state))
        state.calibration?.phase = .discharge
        XCTAssertTrue(SleepGate.holdsLevelDuringSleep(c, state: state))
    }

    func testStateRoundTripAndOldStateDecodes() throws {
        var state = started()
        state.lastCalibrationAt = t0
        let decoded = try JSONDecoder().decode(ControllerState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)
        let old = try JSONDecoder().decode(ControllerState.self, from: Data(#"{"holdingAtLimit":true}"#.utf8))
        XCTAssertNil(old.calibration)
        XCTAssertTrue(old.holdingAtLimit)
    }
}

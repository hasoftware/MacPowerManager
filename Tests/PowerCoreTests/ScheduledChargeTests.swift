import XCTest
@testable import PowerCore

final class ScheduledChargeTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return c
    }()

    /// 2026-10-12 là thứ Hai.
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private var weekdayConfig: PowerConfig {
        var c = PowerConfig()
        c.chargeLimit = 80
        c.fullChargeSchedule = ChargeSchedule(enabled: true, weekdays: [2, 3, 4, 5, 6], hour: 8, minute: 0)
        return c
    }

    private func input(_ now: Date, percent: Int = 80, ac: Bool = true) -> ControllerInput {
        ControllerInput(now: now, percent: percent, temperature: 30, acPresent: ac, bootSessionUUID: "boot")
    }

    func testLeadTimeScalesWithPercent() {
        XCTAssertEqual(ScheduledCharge.leadTime(percent: 80), 60 * 60)
        XCTAssertEqual(ScheduledCharge.leadTime(percent: 50), 105 * 60)
        XCTAssertEqual(ScheduledCharge.leadTime(percent: 99), 45 * 60, "Tối thiểu 45 phút")
        XCTAssertEqual(ScheduledCharge.leadTime(percent: 0), 180 * 60, "Tối đa 3 giờ")
    }

    func testNextReadyTimeSkipsWeekendAndPassedTime() {
        let schedule = weekdayConfig.fullChargeSchedule
        // Thứ Hai 7:00 → 8:00 cùng ngày.
        XCTAssertEqual(ScheduledCharge.nextReadyTime(after: date(12, 7), schedule: schedule, calendar: calendar), date(12, 8))
        // Đúng 8:00 thì đã qua: thứ Ba.
        XCTAssertEqual(ScheduledCharge.nextReadyTime(after: date(12, 8), schedule: schedule, calendar: calendar), date(13, 8))
        // Thứ Sáu 9:00 → thứ Hai tuần sau.
        XCTAssertEqual(ScheduledCharge.nextReadyTime(after: date(16, 9), schedule: schedule, calendar: calendar), date(19, 8))
        XCTAssertNil(ScheduledCharge.nextReadyTime(after: date(12, 7), schedule: ChargeSchedule(enabled: true, weekdays: []),
                                                   calendar: calendar))
    }

    func testStartsOnlyInsideWindowAndOncePerReadyTime() throws {
        var state = ControllerState()
        // 80% cần 1 giờ: 6:59 chưa bắt đầu.
        XCTAssertNil(ScheduledCharge.startIfDue(state: &state, config: weekdayConfig, input: input(date(12, 6, 59)), calendar: calendar))
        XCTAssertNil(state.topUp)
        XCTAssertEqual(ScheduledCharge.startIfDue(state: &state, config: weekdayConfig, input: input(date(12, 7, 0)), calendar: calendar),
                       date(12, 8))
        let topUp = try XCTUnwrap(state.topUp)
        XCTAssertEqual(topUp.scheduledFor, date(12, 8))
        XCTAssertEqual(topUp.expiresAt, date(12, 10), "Giữ đầy thêm 2 giờ")

        // Người dùng hủy: không tự bắt đầu lại trong cùng giờ hẹn.
        ControllerCommands.cancelTopUp(state: &state)
        XCTAssertNil(ScheduledCharge.startIfDue(state: &state, config: weekdayConfig, input: input(date(12, 7, 30)), calendar: calendar))
        XCTAssertNil(state.topUp)
    }

    func testRespectsConditions() {
        let at = date(12, 7, 30)
        func starts(_ change: (inout PowerConfig) -> Void, ac: Bool = true, percent: Int = 80) -> Bool {
            var config = weekdayConfig
            change(&config)
            var state = ControllerState()
            return ScheduledCharge.startIfDue(state: &state, config: config, input: input(at, percent: percent, ac: ac),
                                              calendar: calendar) != nil
        }
        XCTAssertTrue(starts { _ in })
        XCTAssertFalse(starts({ _ in }, ac: false), "Cần cắm sạc")
        XCTAssertFalse(starts { $0.fullChargeSchedule.enabled = false })
        XCTAssertFalse(starts { $0.chargeLimitEnabled = false }, "Không giới hạn thì đã sạc đầy sẵn")
        XCTAssertFalse(starts { $0.chargeLimit = 100 })
        XCTAssertFalse(starts { $0.pauseCharging = true })
        XCTAssertFalse(starts { $0.dischargeEnabled = true })
        XCTAssertFalse(starts { $0.fullChargeSchedule.weekdays = [1, 7] }, "Thứ Hai không có trong lịch")
    }

    func testExtendsManualTopUp() throws {
        var state = ControllerState()
        state.topUp = TopUpState(startedAt: date(12, 6), expiresAt: date(12, 9), bootSessionUUID: "boot")
        XCTAssertNotNil(ScheduledCharge.startIfDue(state: &state, config: weekdayConfig, input: input(date(12, 7, 30)), calendar: calendar))
        XCTAssertEqual(state.topUp?.startedAt, date(12, 6))
        XCTAssertEqual(state.topUp?.expiresAt, date(12, 10))
    }

    func testUnplugBeforeReadyTimeKeepsScheduledTopUp() throws {
        var state = ControllerState()
        let config = weekdayConfig
        ScheduledCharge.startIfDue(state: &state, config: config, input: input(date(12, 7)), calendar: calendar)

        // Rút sạc lúc 7:30: vẫn giữ phiên sạc đầy, cắm lại thì sạc tiếp tới 100%.
        _ = ChargeController.decide(input: input(date(12, 7, 30), percent: 90, ac: false), config: config, state: &state)
        XCTAssertNotNil(state.topUp)
        let resumed = ChargeController.decide(input: input(date(12, 7, 35), percent: 90), config: config, state: &state)
        XCTAssertEqual(resumed.reason, .topUp)
        XCTAssertTrue(resumed.chargingEnabled)
        XCTAssertEqual(resumed.effectiveLimit, 100)

        // Rút sạc sau giờ hẹn: kết thúc, giới hạn trở lại.
        let left = ChargeController.decide(input: input(date(12, 8, 10), percent: 100, ac: false), config: config, state: &state)
        XCTAssertNil(state.topUp)
        XCTAssertTrue(left.effects.contains(.topUpEnded(.unplugged)))
    }

    func testManualTopUpStillEndsOnUnplug() {
        var state = ControllerState()
        state.topUp = TopUpState(startedAt: date(12, 6), expiresAt: date(12, 20), bootSessionUUID: "boot")
        _ = ChargeController.decide(input: input(date(12, 7), ac: false), config: PowerConfig(), state: &state)
        XCTAssertNil(state.topUp)
    }

    func testExpiresAfterHoldWindow() {
        var state = ControllerState()
        ScheduledCharge.startIfDue(state: &state, config: weekdayConfig, input: input(date(12, 7)), calendar: calendar)
        let decision = ChargeController.decide(input: input(date(12, 10, 1), percent: 100), config: weekdayConfig, state: &state)
        XCTAssertNil(state.topUp)
        XCTAssertTrue(decision.effects.contains(.topUpEnded(.expired)))
        XCTAssertFalse(decision.chargingEnabled, "Về lại giới hạn 80%")
    }

    func testNextStartForWakeScheduling() throws {
        let next = try XCTUnwrap(ScheduledCharge.nextStart(now: date(11, 23), percent: 50, schedule: weekdayConfig.fullChargeSchedule,
                                                           calendar: calendar))
        XCTAssertEqual(next.readyBy, date(12, 8))
        XCTAssertEqual(next.start, date(12, 6, 15))
        XCTAssertNil(ScheduledCharge.nextStart(now: date(11, 23), percent: 50, schedule: ChargeSchedule(), calendar: calendar))
    }

    func testDecodingAndSanitizing() throws {
        // Cấu hình từ bản cũ (không có lịch): lịch tắt.
        let old = try JSONDecoder().decode(PowerConfig.self, from: Data(#"{"chargeLimit":70}"#.utf8))
        XCTAssertEqual(old.chargeLimit, 70)
        XCTAssertFalse(old.fullChargeSchedule.enabled)
        let bad = try JSONDecoder().decode(PowerConfig.self, from: Data(
            #"{"fullChargeSchedule":{"enabled":true,"weekdays":[0,2,9],"hour":30,"minute":-5}}"#.utf8)).sanitized()
        XCTAssertEqual(bad.fullChargeSchedule, ChargeSchedule(enabled: true, weekdays: [2], hour: 23, minute: 0))
        let roundTrip = try JSONDecoder().decode(PowerConfig.self, from: JSONEncoder().encode(weekdayConfig))
        XCTAssertEqual(roundTrip, weekdayConfig)
    }

    func testNewBootAllowsScheduleAgain() {
        var runtime = RuntimeState()
        runtime.bootSessionUUID = "old"
        runtime.controller.scheduledChargeHandled = date(12, 8)
        XCTAssertNil(BootSession.reconcile(runtime, currentUUID: "new").state.controller.scheduledChargeHandled)
    }
}

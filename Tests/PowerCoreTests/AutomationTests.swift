import XCTest
@testable import PowerCore

final class AutomationTests: XCTestCase {
    private func parse(_ line: String) -> AutomationAction? {
        try? Automation.parse(line.split(separator: " ").map(String.init)).get()
    }

    func testCommandLineGrammar() {
        XCTAssertEqual(parse("status"), .status(json: false))
        XCTAssertEqual(parse("status --json"), .status(json: true))
        XCTAssertEqual(parse("limit 80"), .setLimit(80))
        XCTAssertEqual(parse("limit 75%"), .setLimit(75))
        XCTAssertEqual(parse("LIMIT OFF"), .limitEnabled(false))
        XCTAssertEqual(parse("pause"), .pause(true))
        XCTAssertEqual(parse("pause off"), .pause(false))
        XCTAssertEqual(parse("resume"), .pause(false))
        XCTAssertEqual(parse("discharge 50"), .discharge(50))
        XCTAssertEqual(parse("discharge stop"), .discharge(nil))
        XCTAssertEqual(parse("topup"), .topUp(hours: nil))
        XCTAssertEqual(parse("topup 4"), .topUp(hours: 4))
        XCTAssertEqual(parse("topup cancel"), .cancelTopUp)
        XCTAssertEqual(parse("charge-to-limit"), .chargeToLimitNow)
        XCTAssertEqual(parse("calibrate"), .calibration(start: true))
        XCTAssertEqual(parse("calibrate cancel"), .calibration(start: false))
        XCTAssertEqual(parse("magsafe status"), .magSafe(.status))
        XCTAssertEqual(try? Automation.parse([]).get(), .help)
    }

    func testRejectsBadValues() {
        for line in ["limit 10", "limit 101", "limit abc", "discharge 5", "discharge 99", "topup 0", "topup 100",
                     "magsafe rainbow", "calibrate now", "explode"] {
            XCTAssertNil(parse(line), line)
        }
    }

    func testAppliesToConfigWithoutTouchingOtherFields() throws {
        var config = PowerConfig()
        config.chargeLimitEnabled = false
        config.thermalPauseAbove = 42
        let limited = try XCTUnwrap(AutomationAction.setLimit(70).applied(to: config))
        XCTAssertTrue(limited.chargeLimitEnabled)
        XCTAssertEqual(limited.chargeLimit, 70)
        XCTAssertEqual(limited.thermalPauseAbove, 42)
        XCTAssertEqual(AutomationAction.discharge(60).applied(to: config)?.dischargeTarget, 60)
        XCTAssertEqual(AutomationAction.discharge(60).applied(to: config)?.dischargeEnabled, true)
        XCTAssertEqual(AutomationAction.magSafe(.off).applied(to: config)?.magSafeLED, .off)
        XCTAssertNil(AutomationAction.topUp(hours: 2).applied(to: config))
        XCTAssertEqual(AutomationAction.topUp(hours: 2).helperCommand, .startTopUp(hours: 2))
        XCTAssertEqual(AutomationAction.calibration(start: false).helperCommand, .cancelCalibration)
        XCTAssertNil(AutomationAction.pause(true).helperCommand)
    }

    func testURLs() {
        func url(_ s: String) -> AutomationAction? { try? Automation.parse(url: URL(string: s)!).get() }
        XCTAssertEqual(url("macpowermanager://limit/80"), .setLimit(80))
        XCTAssertEqual(url("MacPowerManager://pause/on"), .pause(true))
        XCTAssertEqual(url("macpowermanager://topup/4"), .topUp(hours: 4))
        XCTAssertEqual(url("macpowermanager://discharge/stop"), .discharge(nil), "Dừng xả thì được")
        XCTAssertEqual(url("macpowermanager://calibrate/cancel"), .calibration(start: false))
        XCTAssertEqual(url("macpowermanager://"), .open)
        XCTAssertNil(url("macpowermanager://discharge/50"), "Không cho trang web ngắt bộ sạc")
        XCTAssertNil(url("macpowermanager://calibrate/start"))
        XCTAssertNil(url("https://limit/80"))
    }
}

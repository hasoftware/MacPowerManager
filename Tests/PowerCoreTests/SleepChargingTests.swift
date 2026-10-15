import XCTest
@testable import PowerCore

/// Sạc khi gập máy: vẫn sạc khi còn xa giới hạn, nhưng chỉ khi hẹn được lần thức dậy trước lúc pin có thể chạm giới hạn.
final class SleepChargingTests: XCTestCase {
    private func plan(allowed: Bool = true, reason: ChargeReason = .normal, percent: Int? = 30, limit: Int = 90,
                      holds: Bool = true, ac: Bool = true, lid: Bool = true) -> SleepCharging.Plan {
        SleepCharging.plan(chargingAllowed: allowed, reason: reason, percent: percent, limit: limit,
                           holdsLevel: holds, acPresent: ac, lidClosed: lid)
    }

    func testWindowNeverReachesLimitAtMaxRate() {
        for limit in [50, 80, 90, 95] {
            for percent in 0...limit {
                guard let window = SleepCharging.window(percent: percent, limit: limit) else {
                    XCTAssertLessThan(limit - percent, SleepCharging.minimumHeadroom)
                    continue
                }
                let gained = window / 60 * SleepCharging.maxPercentPerMinute
                XCTAssertLessThanOrEqual(Double(percent) + gained, Double(limit), "\(percent)% -> \(limit)%")
            }
        }
    }

    func testWindowFor30To90() {
        // 59% ở 3%/phút: thức dậy sau khoảng 19,7 phút.
        XCTAssertEqual(SleepCharging.window(percent: 30, limit: 90)!, 59.0 / 3 * 60, accuracy: 0.01)
        XCTAssertEqual(SleepCharging.window(percent: 87, limit: 90), SleepCharging.minimumWindow)
        XCTAssertNil(SleepCharging.window(percent: 88, limit: 90))
        XCTAssertNil(SleepCharging.window(percent: 95, limit: 90))
    }

    func testChargesWithLidClosedOnlyWhenWakeArmed() {
        let p = plan()
        XCTAssertTrue(p.charging)
        XCTAssertTrue(p.requiresWake)
        XCTAssertNotNil(p.checkAfter)
        XCTAssertTrue(p.charging(wakeArmed: true))
        XCTAssertFalse(p.charging(wakeArmed: false), "Không hẹn được giờ thức dậy thì giữ mức pin như cũ")
    }

    func testHoldsLevelWhenNearLimitUnpluggedOrLidOpen() {
        XCTAssertEqual(plan(percent: 89), .init(charging: false))
        XCTAssertEqual(plan(ac: false), .init(charging: false), "Không đánh thức máy đang nằm trong balo")
        XCTAssertEqual(plan(lid: false), .init(charging: false), "Nắp mở: không làm sáng màn hình lúc ngủ")
        XCTAssertEqual(plan(percent: nil), .init(charging: false))
    }

    func testRespectsControllerDecision() {
        XCTAssertEqual(plan(allowed: false, reason: .sailing), .init(charging: false))
        XCTAssertEqual(plan(allowed: false, reason: .manualPause), .init(charging: false))
        // Đang nóng: không sạc, nhưng thức dậy kiểm tra lại để sạc tiếp khi pin đã nguội.
        XCTAssertEqual(plan(allowed: false, reason: .thermal), .init(charging: false, checkAfter: SleepCharging.thermalRecheck))
    }

    func testCriticalAndNoLimit() {
        XCTAssertEqual(plan(allowed: false, percent: 5, lid: false), .init(charging: true))
        XCTAssertEqual(plan(holds: false), .init(charging: true))
        XCTAssertEqual(plan(allowed: false, holds: false), .init(charging: false))
    }

    func testConstrainLoosensOnlyWhenArmed() {
        func gate(armed: Bool) -> Bool {
            SleepGate.constrain(charging: true, adapter: true, currentCharging: false, currentAdapter: true,
                                phase: .darkWake, reason: .normal, holdsLevelDuringSleep: true,
                                sleepChargingArmed: armed).charging
        }
        XCTAssertFalse(gate(armed: false))
        XCTAssertTrue(gate(armed: true))
        // Bộ điều khiển muốn tắt sạc thì luôn tắt, dù đã hẹn giờ.
        XCTAssertFalse(SleepGate.constrain(charging: false, adapter: true, currentCharging: true, currentAdapter: true,
                                           phase: .darkWake, reason: .limitReached, holdsLevelDuringSleep: true,
                                           sleepChargingArmed: true).charging)
    }
}

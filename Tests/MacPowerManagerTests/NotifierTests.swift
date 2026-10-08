import Foundation
import PowerCore
import XCTest
@testable import MacPowerManager

@MainActor
final class NotifierTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var posted: [String] = []

    override func setUp() {
        suite = "NotifierTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        posted = []
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeNotifier() -> Notifier {
        Notifier(defaults: defaults) { [unowned self] id, _, _ in self.posted.append(id) }
    }

    private func battery(_ percent: Int, plugged: Bool = true) -> BatteryInfo {
        var b = BatteryInfo()
        b.percent = percent
        b.externalConnected = plugged
        return b
    }

    private func status(discharging: Bool, target: Int = 50, writes: [ForeignWrite]? = nil) -> HelperStatus {
        var config = PowerConfig()
        config.dischargeEnabled = discharging
        config.dischargeTarget = target
        var s = HelperStatus(version: "0.3.0", config: config, chargingKeys: "CHTE", adapterKeys: "CHIE",
                             chargingEnabled: false, adapterEnabled: !discharging, reason: .limitReached,
                             temperature: nil, lastError: nil)
        s.foreignWrites = writes
        return s
    }

    private func evaluate(_ n: Notifier, _ percent: Int, _ s: HelperStatus?, now: Date = Date()) {
        n.evaluate(battery: battery(percent), temperature: nil, helper: s, prefs: Preferences(), now: now)
    }

    // MARK: Xả xong

    func testDischargeDoneWhenTargetReached() {
        let n = makeNotifier()
        evaluate(n, 60, status(discharging: true))
        evaluate(n, 50, status(discharging: false))
        XCTAssertEqual(posted.filter { $0 == "discharge-done" }.count, 1)
    }

    func testCancelledDischargeDoesNotNotify() {
        let n = makeNotifier()
        evaluate(n, 70, status(discharging: true))
        evaluate(n, 68, status(discharging: false))   // người dùng dừng / sạc đầy một lần / đổi cấu hình
        XCTAssertFalse(posted.contains("discharge-done"))
    }

    func testHelperOutageDoesNotNotify() {
        let n = makeNotifier()
        evaluate(n, 60, status(discharging: true))
        evaluate(n, 59, nil)                           // mất kết nối helper
        XCTAssertFalse(posted.contains("discharge-done"))
        evaluate(n, 58, status(discharging: true))     // kết nối lại, vẫn đang xả
        XCTAssertFalse(posted.contains("discharge-done"))
        evaluate(n, 50, status(discharging: false))
        XCTAssertEqual(posted.filter { $0 == "discharge-done" }.count, 1)
    }

    func testDischargeEndingDuringOutageStillNotifiesOnReconnect() {
        let n = makeNotifier()
        evaluate(n, 55, status(discharging: true))
        evaluate(n, 52, nil)
        evaluate(n, 50, status(discharging: false))
        XCTAssertEqual(posted.filter { $0 == "discharge-done" }.count, 1)
    }

    // MARK: Ghi từ bên ngoài

    func testForeignWriteNotifiedOncePerIncident() {
        let now = Date()
        let write = ForeignWrite(key: "CHTE", expected: "01000000", found: "00000000", at: now.addingTimeInterval(-60))
        let n = makeNotifier()
        evaluate(n, 80, status(discharging: false, writes: [write]), now: now)
        evaluate(n, 80, nil, now: now)                 // helper gián đoạn không xóa trạng thái
        evaluate(n, 80, status(discharging: false, writes: [write]), now: now)
        XCTAssertEqual(posted.filter { $0 == "foreign-controller" }.count, 1)

        // Mở lại app: trạng thái đã lưu trong UserDefaults.
        let relaunched = makeNotifier()
        evaluate(relaunched, 80, status(discharging: false, writes: [write]), now: now)
        XCTAssertEqual(posted.filter { $0 == "foreign-controller" }.count, 1)

        // Tool khác ghi lại mỗi phút: vẫn chỉ một thông báo trong cửa sổ 30 phút.
        for minute in 1...20 {
            let t = now.addingTimeInterval(Double(minute) * 60)
            let w = ForeignWrite(key: "CHTE", expected: "01000000", found: "00000000", at: t)
            evaluate(relaunched, 80, status(discharging: false, writes: [w]), now: t)
        }
        XCTAssertEqual(posted.filter { $0 == "foreign-controller" }.count, 1)

        // Sau cửa sổ, một sự việc mới thì báo tiếp.
        let later = now.addingTimeInterval(AppModel.foreignWriteWindow + 120)
        let newer = ForeignWrite(key: "CHTE", expected: "01000000", found: "00000000", at: later)
        evaluate(relaunched, 80, status(discharging: false, writes: [newer]), now: later)
        XCTAssertEqual(posted.filter { $0 == "foreign-controller" }.count, 2)
    }

    func testStaleForeignWriteNotNotified() {
        let now = Date()
        let old = ForeignWrite(key: "CHTE", expected: "01", found: "00", at: now.addingTimeInterval(-2 * 3600))
        let n = makeNotifier()
        evaluate(n, 80, status(discharging: false, writes: [old]), now: now)
        XCTAssertFalse(posted.contains("foreign-controller"))
    }
}

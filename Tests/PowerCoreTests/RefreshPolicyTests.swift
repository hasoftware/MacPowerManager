import XCTest
@testable import PowerCore

final class RefreshPolicyTests: XCTestCase {
    private func ctx(_ visible: Bool, battery: Bool = false, lpm: Bool = false) -> RefreshPolicy.Context {
        .init(uiVisible: visible, onBattery: battery, lowPowerMode: lpm)
    }

    func testNothingVisiblePausesMonitors() {
        XCTAssertNil(RefreshPolicy.systemInterval(ctx(false)))
        XCTAssertNil(RefreshPolicy.processInterval(ctx(false), chosen: 2))
        XCTAssertEqual(RefreshPolicy.batteryInterval(ctx(false)), 60)
    }

    func testVisibleOnAC() {
        XCTAssertEqual(RefreshPolicy.systemInterval(ctx(true)), 1)
        XCTAssertEqual(RefreshPolicy.processInterval(ctx(true), chosen: 2), 2)
        XCTAssertEqual(RefreshPolicy.processInterval(ctx(true), chosen: 10), 10)
        XCTAssertEqual(RefreshPolicy.batteryInterval(ctx(true)), 5)
    }

    func testSidebarOnlyPagesSampleSlowly() {
        XCTAssertEqual(RefreshPolicy.systemInterval(ctx(true), detailed: false), 5)
        XCTAssertNil(RefreshPolicy.systemInterval(ctx(false), detailed: false))
    }

    func testBatteryAndLowPowerSlowDown() {
        XCTAssertEqual(RefreshPolicy.systemInterval(ctx(true, battery: true)), 2)
        XCTAssertEqual(RefreshPolicy.processInterval(ctx(true, battery: true), chosen: 2), 5)
        XCTAssertEqual(RefreshPolicy.systemInterval(ctx(true, battery: true, lpm: true)), 3)
        XCTAssertEqual(RefreshPolicy.processInterval(ctx(true, lpm: true), chosen: 5), 10)
    }

    func testTolerance() {
        XCTAssertEqual(RefreshPolicy.tolerance(for: 30), 6)
        XCTAssertEqual(RefreshPolicy.tolerance(for: 0.2), 0.1)
    }
}

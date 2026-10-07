import XCTest
@testable import PowerCore

final class EffectVerifierTests: XCTestCase {
    private let since = testEpoch

    private func evaluate(after seconds: TimeInterval, current: Int?, inhibited: Bool = true,
                          ac: Bool = true, percent: Int = 80) -> EffectState {
        EffectVerifier.evaluate(inhibitedSince: inhibited ? since : nil, now: since.addingTimeInterval(seconds),
                                batteryCurrentmA: current, acPresent: ac, percent: percent)
    }

    func testNotApplicableWhenNotInhibited() {
        XCTAssertEqual(evaluate(after: 200, current: 2000, inhibited: false), .notApplicable)
    }

    func testNotApplicableWhenUnplugged() {
        XCTAssertEqual(evaluate(after: 200, current: 2000, ac: false), .notApplicable)
    }

    func testNotApplicableWhenNearlyFull() {
        XCTAssertEqual(evaluate(after: 200, current: 2000, percent: 99), .notApplicable)
        XCTAssertEqual(evaluate(after: 200, current: 2000, percent: 100), .notApplicable)
        XCTAssertNotEqual(evaluate(after: 200, current: 2000, percent: 98), .notApplicable)
    }

    func testUnknownCurrentIsNotApplicable() {
        XCTAssertEqual(evaluate(after: 0, current: nil), .notApplicable, "Trước hạn")
        XCTAssertEqual(evaluate(after: 500, current: nil), .notApplicable, "Sau hạn")
    }

    func testVerifiedAtOrBelowThreshold() {
        let threshold = PowerConstants.effectCurrentThresholdmA
        XCTAssertEqual(evaluate(after: 0, current: threshold), .verified)
        XCTAssertEqual(evaluate(after: 5, current: 0), .verified)
        XCTAssertEqual(evaluate(after: 5, current: -1500), .verified, "Pin đang xả")
        XCTAssertEqual(evaluate(after: 500, current: 10), .verified)
        XCTAssertEqual(evaluate(after: 0, current: threshold + 1), .pending(since: since))
    }

    func testPendingBeforeDeadline() {
        XCTAssertEqual(evaluate(after: 0, current: 1200), .pending(since: since))
        XCTAssertEqual(evaluate(after: PowerConstants.effectVerifySeconds - 0.5, current: 1200), .pending(since: since))
        XCTAssertEqual(evaluate(after: -30, current: 1200), .pending(since: since), "Đồng hồ lùi")
    }

    func testIneffectiveAfterDeadline() {
        let state = evaluate(after: PowerConstants.effectVerifySeconds, current: 1200)
        guard case .ineffective(let detail) = state else { return XCTFail("\(state)") }
        XCTAssertTrue(detail.contains("1200 mA"), detail)
        XCTAssertTrue(detail.contains("90 giây"), detail)
        XCTAssertTrue(detail.contains("chặn sạc"), "Thông báo tiếng Việt: \(detail)")
    }

    func testTimelineVerifiedAfterRampDown() {
        let samples: [(TimeInterval, Int?, EffectState)] = [
            (0, 2500, .pending(since: since)),
            (10, nil, .notApplicable),
            (30, 900, .pending(since: since)),
            (60, 120, .pending(since: since)),
            (70, 30, .verified),
            (200, 0, .verified),
        ]
        for (t, current, expected) in samples {
            XCTAssertEqual(evaluate(after: t, current: current), expected, "t = \(t)")
        }
    }

    func testTimelineIneffectiveThenRecovers() {
        XCTAssertEqual(evaluate(after: 60, current: 1500), .pending(since: since))
        if case .ineffective = evaluate(after: 95, current: 1400) {} else { XCTFail("Phải không hiệu lực sau 90 giây") }
        if case .ineffective = evaluate(after: 300, current: 51) {} else { XCTFail("51 mA vẫn vượt ngưỡng") }
        XCTAssertEqual(evaluate(after: 310, current: 20), .verified, "Dòng về 0 thì xác nhận lại hiệu lực")
    }

    func testExtremeDatesDoNotTrap() {
        let state = EffectVerifier.evaluate(inhibitedSince: .distantPast, now: .distantFuture, batteryCurrentmA: 900,
                                            acPresent: true, percent: 50)
        if case .ineffective = state {} else { XCTFail("\(state)") }
        let infinite = EffectVerifier.evaluate(inhibitedSince: Date(timeIntervalSinceReferenceDate: -.infinity),
                                               now: testEpoch, batteryCurrentmA: 900, acPresent: true, percent: 50)
        if case .ineffective = infinite {} else { XCTFail("\(infinite)") }
    }
}

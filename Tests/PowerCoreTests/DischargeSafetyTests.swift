import XCTest
@testable import PowerCore

/// Hạn thuê xả (I2), điều kiện cắm sạc khi ngắt adapter, xác minh việc ngắt và từ chối xả khi không hỗ trợ.
final class DischargeSafetyTests: XCTestCase {
    private func harness(target: Int = 50) -> ControllerHarness {
        ControllerHarness {
            $0.dischargeEnabled = true
            $0.dischargeTarget = target
        }
    }

    private let leaseSeconds = PowerConstants.dischargeMaxMinutes * 60

    // MARK: Hạn thuê

    func testLeaseConstant() {
        XCTAssertEqual(PowerConstants.dischargeMaxMinutes, 360)
    }

    func testLeaseRecordedOnFirstCutAndKept() {
        var h = harness()
        XCTAssertNil(h.state.dischargeStartedAt)
        XCTAssertFalse(h.step(90).adapterEnabled)
        let started = h.now
        XCTAssertEqual(h.state.dischargeStartedAt, started)
        h.step(89, after: 600)
        XCTAssertEqual(h.state.dischargeStartedAt, started, "Không bắt đầu lại hạn thuê ở mỗi vòng")
    }

    func testLeaseExpiryTurnsAdapterOnWithEffect() {
        var h = harness()
        h.step(90)
        let justBefore = h.step(85, after: leaseSeconds - 1)
        XCTAssertFalse(justBefore.adapterEnabled, "Còn hạn thì vẫn xả")
        XCTAssertEqual(justBefore.reason, .discharging)

        let expired = h.step(85, after: 1)
        XCTAssertTrue(expired.adapterEnabled, "Hết hạn thì bật lại adapter ngay")
        XCTAssertNotEqual(expired.reason, .discharging)
        XCTAssertEqual(expired.effects, [.dischargeAborted(.leaseExpired)])
        XCTAssertFalse(expired.dischargeFinished)

        // Helper chưa kịp tắt xả: vẫn không ngắt lại adapter.
        XCTAssertTrue(h.step(85).adapterEnabled)
        // Helper tắt xả: bỏ hạn thuê.
        h.config.dischargeEnabled = false
        XCTAssertEqual(h.step(85).effects, [])
        XCTAssertNil(h.state.dischargeStartedAt)
    }

    func testExpiredLeaseFallsBackToNormalRules() {
        var h = harness()
        h.config.chargeLimit = 80
        h.step(90)
        let d = h.step(90, after: leaseSeconds)
        XCTAssertEqual(d.reason, .limitReached, "Trên giới hạn thì vẫn giữ mức sau khi hủy xả")
        XCTAssertFalse(d.chargingEnabled)
        XCTAssertTrue(d.adapterEnabled)
    }

    func testLeaseKeepsCountingWhileLidClosed() {
        var h = harness()
        h.step(90)
        h.lidClosed = true
        XCTAssertEqual(h.step(90, after: leaseSeconds / 2).reason, .clamshellSuspended)
        h.lidClosed = false
        let d = h.step(90, after: leaseSeconds / 2)
        XCTAssertTrue(d.adapterEnabled)
        XCTAssertEqual(d.effects, [.dischargeAborted(.leaseExpired)])
    }

    func testLeaseNotStartedWhileSuspendedOrUnplugged() {
        var h = harness()
        h.lidClosed = true
        h.step(90)
        XCTAssertNil(h.state.dischargeStartedAt, "Nắp đóng: chưa ngắt adapter nên chưa tính hạn thuê")
        h.lidClosed = false
        h.acPresent = false
        h.step(90)
        XCTAssertNil(h.state.dischargeStartedAt, "Rút sạc: không ngắt adapter")
    }

    func testClockGoingBackwardsExpiresLease() {
        var h = harness()
        h.step(90)
        let d = h.step(90, after: -(PowerConstants.clockSkewToleranceSeconds + 1))
        XCTAssertTrue(d.adapterEnabled)
        XCTAssertEqual(d.effects, [.dischargeAborted(.leaseExpired)])
        XCTAssertFalse(ChargeController.dischargeLeaseExpired(testEpoch, now: testEpoch.addingTimeInterval(-30)),
                       "Lệch nhỏ (NTP) không làm hết hạn")
    }

    func testCriticalBeatsLease() {
        var h = harness(target: 15)
        h.step(90)
        let d = h.step(10, after: leaseSeconds)
        XCTAssertEqual(d.reason, .critical)
        XCTAssertEqual(d.effects, [.dischargeFinished])
    }

    func testReachingTargetFinishesEvenAfterLease() {
        var h = harness()
        h.step(90)
        XCTAssertEqual(h.step(50, after: leaseSeconds).effects, [.dischargeFinished])
    }

    func testConfigChangeRestartsLease() {
        var state = ControllerState()
        state.dischargeStartedAt = testEpoch
        var off = PowerConfig()
        off.dischargeEnabled = false
        var on = off
        on.dischargeEnabled = true

        var s1 = state
        _ = ControllerCommands.configDidChange(from: off, to: on, state: &s1)
        XCTAssertNil(s1.dischargeStartedAt, "Bật xả là một hạn thuê mới")

        var s2 = state
        _ = ControllerCommands.configDidChange(from: on, to: off, state: &s2)
        XCTAssertNil(s2.dischargeStartedAt)

        var s3 = state
        var target = on
        target.dischargeTarget = 40
        _ = ControllerCommands.configDidChange(from: on, to: target, state: &s3)
        XCTAssertEqual(s3.dischargeStartedAt, testEpoch, "Đổi mục tiêu không kéo dài hạn thuê")
    }

    func testStateDecodingWithLease() throws {
        var state = ControllerState()
        state.dischargeStartedAt = testEpoch
        let decoded = try JSONDecoder().decode(ControllerState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)

        let old = try JSONDecoder().decode(ControllerState.self, from: Data("{\"holdingAtLimit\":true}".utf8))
        XCTAssertNil(old.dischargeStartedAt, "state.json của bản cũ")
        XCTAssertTrue(old.holdingAtLimit)
        let bad = try JSONDecoder().decode(ControllerState.self, from: Data("{\"dischargeStartedAt\":\"x\"}".utf8))
        XCTAssertNil(bad.dischargeStartedAt)
    }

    func testEffectRoundTrip() throws {
        let effects: [ControllerEffect] = [.dischargeAborted(.leaseExpired), .dischargeAborted(.adapterCutIneffective)]
        XCTAssertEqual(try JSONDecoder().decode([ControllerEffect].self, from: JSONEncoder().encode(effects)), effects)
    }

    // MARK: Chỉ ngắt adapter khi đang cắm sạc

    func testUnpluggedAboveTargetKeepsAdapterOn() {
        var h = harness()
        h.acPresent = false
        let d = h.step(70)
        XCTAssertTrue(d.adapterEnabled, "Rút sạc thì không có gì để ngắt")
        XCTAssertNotEqual(d.reason, .discharging)
        XCTAssertEqual(d.effects, [], "Không kết thúc xả: cắm lại thì xả tiếp")

        h.acPresent = true
        let again = h.step(70)
        XCTAssertEqual(again.reason, .discharging)
        XCTAssertFalse(again.adapterEnabled)
    }

    func testUnpluggedAboveLimitHolds() {
        var h = harness()
        h.config.chargeLimit = 60
        h.acPresent = false
        let d = h.step(70)
        XCTAssertEqual(d.reason, .limitReached)
        XCTAssertFalse(d.chargingEnabled, "Cắm lại trước vòng kế tiếp cũng không sạc vượt giới hạn")
        XCTAssertTrue(d.adapterEnabled)
    }

    func testUnpluggedAtTargetStillFinishes() {
        var h = harness()
        h.acPresent = false
        XCTAssertEqual(h.step(50).effects, [.dischargeFinished])
    }

    func testNeverCutsWhileUnplugged() {
        for target in [15, 50, 95] {
            var h = harness(target: target)
            h.acPresent = false
            for p in 0...100 {
                XCTAssertTrue(h.step(p).adapterEnabled, "\(p)% target \(target)")
            }
        }
    }

    // MARK: Cắm sạc vật lý

    func testACPresenceFollowsIOKitWhileAdapterEnabled() {
        XCTAssertEqual(ACPresence.resolve(externalConnected: true, adapterEnabled: true, lastKnown: nil).acPresent, true)
        let unplugged = ACPresence.resolve(externalConnected: false, adapterEnabled: true, lastKnown: true)
        XCTAssertFalse(unplugged.acPresent)
        XCTAssertEqual(unplugged.lastKnown, false)
        let noKeys = ACPresence.resolve(externalConnected: false, adapterEnabled: nil, lastKnown: true)
        XCTAssertFalse(noKeys.acPresent, "Không có key adapter: luôn theo IOKit")
    }

    func testACPresenceKeepsLastKnownWhileCut() {
        let cut = ACPresence.resolve(externalConnected: false, adapterEnabled: false, lastKnown: true)
        XCTAssertTrue(cut.acPresent, "IOKit báo không cắm vì chính helper ngắt adapter")
        XCTAssertEqual(cut.lastKnown, true)
        XCTAssertFalse(ACPresence.resolve(externalConnected: false, adapterEnabled: false, lastKnown: false).acPresent,
                       "Đã rút trước khi ngắt thì vẫn coi là rút")
        XCTAssertFalse(ACPresence.resolve(externalConnected: true, adapterEnabled: false, lastKnown: nil).acPresent,
                       "Chưa biết gì thì coi như rút để bật lại adapter")
    }

    /// Vòng lặp helper mô phỏng: cắm → ngắt adapter (IOKit báo rút) → vẫn xả, không bật/ngắt liên tục.
    func testSimulatedLoopDoesNotOscillate() {
        var h = harness()
        var lastKnown: Bool?
        var adapterEnabled = true
        for i in 0..<30 {
            let resolved = ACPresence.resolve(externalConnected: adapterEnabled, adapterEnabled: adapterEnabled,
                                              lastKnown: lastKnown)
            lastKnown = resolved.lastKnown
            h.acPresent = resolved.acPresent
            let d = h.step(90)
            XCTAssertFalse(d.adapterEnabled, "vòng \(i)")
            adapterEnabled = d.adapterEnabled
        }
    }

    // MARK: Xác minh ngắt adapter

    func testAdapterCutVerification() {
        let t0 = testEpoch
        XCTAssertEqual(AdapterCutVerifier.evaluate(cutSince: nil, now: t0, batteryCurrentmA: 500, previous: .verified),
                       .notApplicable)
        XCTAssertEqual(AdapterCutVerifier.evaluate(cutSince: t0, now: t0.addingTimeInterval(5), batteryCurrentmA: 300,
                                                   previous: .notApplicable), .pending(since: t0))
        XCTAssertEqual(AdapterCutVerifier.evaluate(cutSince: t0, now: t0.addingTimeInterval(5), batteryCurrentmA: -1200,
                                                   previous: .pending(since: t0)), .verified)
        XCTAssertEqual(AdapterCutVerifier.evaluate(cutSince: t0, now: t0.addingTimeInterval(59), batteryCurrentmA: 0,
                                                   previous: .pending(since: t0)), .pending(since: t0))
        guard case .ineffective = AdapterCutVerifier.evaluate(cutSince: t0, now: t0.addingTimeInterval(60),
                                                             batteryCurrentmA: 0, previous: .pending(since: t0)) else {
            return XCTFail("Dòng 0 mA sau 60 giây: adapter chưa bị ngắt")
        }
        guard case .ineffective = AdapterCutVerifier.evaluate(cutSince: t0, now: t0.addingTimeInterval(120),
                                                             batteryCurrentmA: nil, previous: .pending(since: t0)) else {
            return XCTFail("Không đọc được dòng: không xác minh được nên hủy")
        }
        guard case .ineffective = AdapterCutVerifier.evaluate(cutSince: t0, now: t0.addingTimeInterval(-600),
                                                             batteryCurrentmA: 100, previous: .notApplicable) else {
            return XCTFail("Đồng hồ lùi: không chờ mãi")
        }
        XCTAssertEqual(AdapterCutVerifier.evaluate(cutSince: t0, now: t0.addingTimeInterval(600), batteryCurrentmA: 100,
                                                   previous: .verified), .verified, "Đã xác minh thì giữ tới khi bật lại adapter")
    }

    func testSleepAssertionOnlyWhileCutInEffect() {
        let t0 = testEpoch
        XCTAssertTrue(AdapterCutVerifier.holdsSleepAssertion(adapterEnabled: false, check: .verified))
        XCTAssertTrue(AdapterCutVerifier.holdsSleepAssertion(adapterEnabled: false, check: .pending(since: t0)))
        XCTAssertFalse(AdapterCutVerifier.holdsSleepAssertion(adapterEnabled: true, check: .verified),
                       "Đọc lại thấy adapter bật")
        XCTAssertFalse(AdapterCutVerifier.holdsSleepAssertion(adapterEnabled: nil, check: .verified))
        XCTAssertFalse(AdapterCutVerifier.holdsSleepAssertion(adapterEnabled: false, check: .notApplicable),
                       "Adapter bị tiến trình khác ngắt, không phải helper")
        XCTAssertFalse(AdapterCutVerifier.holdsSleepAssertion(adapterEnabled: false, check: .ineffective(detail: "")))
    }

    // MARK: Từ chối xả

    func testDischargeRefusedWithoutAdapterKeys() {
        var config = PowerConfig()
        config.dischargeEnabled = true
        config.chargeLimit = 70
        let refused = ControllerCommands.validate(config, adapterSupported: false)
        XCTAssertEqual(refused.error, .unsupported)
        XCTAssertFalse(refused.config.dischargeEnabled)
        XCTAssertEqual(refused.config.chargeLimit, 70, "Phần còn lại của cấu hình vẫn áp dụng")

        let ok = ControllerCommands.validate(config, adapterSupported: true)
        XCTAssertNil(ok.error)
        XCTAssertEqual(ok.config, config)

        config.dischargeEnabled = false
        XCTAssertNil(ControllerCommands.validate(config, adapterSupported: false).error)
    }
}

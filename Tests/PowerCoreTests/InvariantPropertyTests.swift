import XCTest
@testable import PowerCore

/// Kiểm tra các bất biến an toàn (I1, I3, I5, I13 và quy tắc ngắt adapter) trên toàn bộ không gian đầu vào.
final class InvariantPropertyTests: XCTestCase {
    private struct Violations {
        var count = 0
        var samples: [String] = []

        mutating func check(_ ok: Bool, _ message: @autoclosure () -> String) {
            guard !ok else { return }
            count += 1
            if samples.count < 10 { samples.append(message()) }
        }

        func report(file: StaticString = #filePath, line: UInt = #line) {
            if count > 0 {
                XCTFail("\(count) vi phạm, ví dụ:\n" + samples.joined(separator: "\n"), file: file, line: line)
            }
        }
    }

    /// Các bất biến phải đúng cho mọi lần quyết định.
    private func verify(_ d: ControlDecision, input: ControllerInput, config: PowerConfig,
                        before: ControllerState, after: ControllerState, into v: inout Violations) {
        // Chỉ dựng chuỗi mô tả khi có vi phạm (test quét hàng trăm nghìn trường hợp).
        func ctx() -> String {
            "\(input.percent)% t=\(input.temperature.map { "\($0)" } ?? "nil") ac=\(input.acPresent) "
                + "lid=\(input.lidClosed) cfg=\(config) state=\(before) -> \(d)"
        }
        // I13
        v.check(ChargeController.limitRange.contains(d.effectiveLimit), "effectiveLimit: \(ctx())")
        // Ngắt adapter chỉ khi đang xả.
        v.check(d.adapterEnabled || d.reason == .discharging, "adapter cut: \(ctx())")
        v.check(d.reason != .discharging || (!d.adapterEnabled && !d.chargingEnabled), "discharging: \(ctx())")
        // I1
        if input.percent <= PowerConstants.criticalPercent {
            v.check(d.chargingEnabled && d.adapterEnabled && d.reason == .critical, "critical: \(ctx())")
        }
        // I3
        if input.percent < PowerConstants.sailingFloorPercent {
            v.check(![.sailing, .limitReached, .thermal].contains(d.reason), "floor: \(ctx())")
        }
        // Sạc bật đúng khi lý do cho phép sạc.
        v.check(d.chargingEnabled == [.normal, .topUp, .critical].contains(d.reason), "charging/reason: \(ctx())")
        // I5: không tồn tại Top Up khi rút sạc; Top Up luôn là giới hạn 100.
        if !input.acPresent { v.check(after.topUp == nil, "topUp unplugged: \(ctx())") }
        if after.topUp != nil { v.check(d.effectiveLimit == 100, "topUp limit: \(ctx())") }
        if d.reason == .topUp { v.check(after.topUp != nil, "topUp reason: \(ctx())") }
        if before.topUp != nil && after.topUp == nil {
            v.check(d.effects.contains { if case .topUpEnded = $0 { return true } else { return false } },
                    "topUp ended silently: \(ctx())")
        }
        // Không giữ mức khi không có giới hạn.
        let sane = config.sanitized()
        if !sane.chargeLimitEnabled || sane.chargeLimit >= 100 {
            v.check(!after.holdingAtLimit && !after.chargeToLimitOnce, "holding without limit: \(ctx())")
            v.check(![.sailing, .limitReached].contains(d.reason), "sailing without limit: \(ctx())")
        }
        if d.reason == .sailing { v.check(input.percent < d.effectiveLimit, "sailing at limit: \(ctx())") }
        if d.reason == .limitReached { v.check(input.percent >= d.effectiveLimit, "limitReached below: \(ctx())") }
        // Mỗi hiệu ứng xuất hiện tối đa một lần.
        v.check(Set(d.effects.map { "\($0)" }).count == d.effects.count, "duplicate effects: \(ctx())")
        if d.dischargeFinished { v.check(config.dischargeEnabled, "dischargeFinished w/o discharge: \(ctx())") }
    }

    private func configs() -> [PowerConfig] {
        var result: [PowerConfig] = []
        // nil = tắt giới hạn.
        for limit in [nil, 20, 50, 80, 99, 100] as [Int?] {
            for gap in [1, 10] {
                for mode in 0..<4 {
                    for thermal in [true, false] {
                        var c = PowerConfig()
                        c.chargeLimitEnabled = limit != nil
                        c.chargeLimit = limit ?? 80
                        c.sailingGap = gap
                        c.thermalProtectionEnabled = thermal
                        switch mode {
                        case 1: c.pauseCharging = true
                        case 2: c.dischargeEnabled = true; c.dischargeTarget = 15
                        case 3: c.dischargeEnabled = true; c.dischargeTarget = 60
                        default: break
                        }
                        result.append(c)
                    }
                }
            }
        }
        return result
    }

    private func states() -> [ControllerState] {
        var holding = ControllerState()
        holding.holdingAtLimit = true
        var hot = ControllerState()
        hot.thermalPaused = true
        var once = ControllerState()
        once.chargeToLimitOnce = true
        var topUp = ControllerState()
        topUp.topUp = TopUpState(startedAt: testEpoch, expiresAt: testEpoch.addingTimeInterval(3600),
                                 bootSessionUUID: "BOOT-A")
        var all = topUp
        all.holdingAtLimit = true
        all.thermalPaused = true
        all.chargeToLimitOnce = true
        return [ControllerState(), holding, hot, once, topUp, all]
    }

    /// Quét percent 0...100 × nhiệt độ × cấu hình × trạng thái × (cắm sạc, nắp).
    func testExhaustiveSweep() {
        var v = Violations()
        let temps: [Double?] = [nil, 25, 36, 40, .nan]
        let environments: [(ac: Bool, lid: Bool)] = [(true, false), (true, true), (false, false)]
        let configs = configs(), states = states()
        var evaluated = 0
        for config in configs {
            for start in states {
                for env in environments {
                    for temp in temps {
                        for percent in 0...100 {
                            var state = start
                            let input = ControllerInput(now: testEpoch.addingTimeInterval(60), percent: percent,
                                                        temperature: temp, acPresent: env.ac, lidClosed: env.lid,
                                                        bootSessionUUID: "BOOT-A")
                            let d = ChargeController.decide(input: input, config: config, state: &state)
                            verify(d, input: input, config: config, before: start, after: state, into: &v)
                            evaluated += 1
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(evaluated, 100_000)
        v.report()
    }

    /// Chuỗi trạng thái nối tiếp: pin lên xuống ngẫu nhiên, cấu hình và môi trường đổi giữa chừng.
    func testRandomWalkKeepsInvariants() {
        var rng = SeededGenerator(seed: 0x4D50_4D30_332E_30)
        var v = Violations()
        let configs = configs()
        for _ in 0..<200 {
            var config = configs.randomElement(using: &rng)!
            var state = ControllerState()
            var now = testEpoch
            var percent = Int.random(in: 0...100, using: &rng)
            var temp: Double = .random(in: 25...45, using: &rng)
            var ac = true, lid = false
            var boot = "BOOT-A"
            for _ in 0..<300 {
                now = now.addingTimeInterval(.random(in: 5...600, using: &rng))
                percent = min(max(percent + Int.random(in: -2...2, using: &rng), 0), 100)
                temp = min(max(temp + .random(in: -1.5...1.5, using: &rng), 20), 60)
                switch Int.random(in: 0..<100, using: &rng) {
                case 0: ac.toggle()
                case 1: lid.toggle()
                case 2: config = configs.randomElement(using: &rng)!
                case 3: _ = ControllerCommands.startTopUp(state: &state, now: now, hours: Int.random(in: -1...80, using: &rng),
                                                          acPresent: ac, bootSessionUUID: boot)
                case 4: ControllerCommands.cancelTopUp(state: &state)
                case 5: ControllerCommands.chargeToLimitNow(state: &state, config: config)
                case 6: boot = boot == "BOOT-A" ? "BOOT-B" : "BOOT-A"
                default: break
                }
                let before = state
                let input = ControllerInput(now: now, percent: percent, temperature: temp, acPresent: ac,
                                            lidClosed: lid, bootSessionUUID: boot)
                let d = ChargeController.decide(input: input, config: config, state: &state)
                verify(d, input: input, config: config, before: before, after: state, into: &v)
                // Quyết định ổn định: chạy lại với cùng đầu vào cho cùng kết quả (không hiệu ứng lặp lại).
                var again = state
                let d2 = ChargeController.decide(input: input, config: config, state: &again)
                v.check(again == state, "not idempotent state: \(input) \(config)")
                v.check(d2.chargingEnabled == d.chargingEnabled && d2.adapterEnabled == d.adapterEnabled
                        && d2.reason == d.reason, "not idempotent decision: \(input) \(config)")
                let oneShot = d2.effects.contains { effect in
                    if case .topUpEnded = effect { return true }
                    return effect == .chargeToLimitDone
                }
                v.check(!oneShot, "repeated one-shot effect: \(input)")
            }
        }
        v.report()
    }

    /// I13: giá trị cực đoan (cấu hình chưa sanitize, % âm/vượt, nhiệt độ NaN/vô cực, ngày lạ) không làm trap.
    func testTotalityWithWildInputs() {
        var rng = SeededGenerator(seed: 13)
        var v = Violations()
        let ints = [Int.min, -1000, -1, 0, 1, 10, 11, 19, 20, 21, 50, 99, 100, 101, 1000, Int.max]
        let doubles: [Double] = [-.infinity, -40, 0, 34.9, 35, 40, 54.9, 1e300, .infinity, .nan]
        let dates: [Date] = [.distantPast, testEpoch, .distantFuture]
        for _ in 0..<20_000 {
            var config = PowerConfig()
            config.chargeLimitEnabled = .random(using: &rng)
            config.chargeLimit = ints.randomElement(using: &rng)!
            config.sailingGap = ints.randomElement(using: &rng)!
            config.pauseCharging = .random(using: &rng)
            config.dischargeEnabled = .random(using: &rng)
            config.dischargeTarget = ints.randomElement(using: &rng)!
            config.thermalProtectionEnabled = .random(using: &rng)
            config.thermalPauseAbove = doubles.randomElement(using: &rng)!
            config.thermalResumeBelow = doubles.randomElement(using: &rng)!
            var state = ControllerState()
            state.holdingAtLimit = .random(using: &rng)
            state.thermalPaused = .random(using: &rng)
            state.chargeToLimitOnce = .random(using: &rng)
            if Bool.random(using: &rng) {
                state.topUp = TopUpState(startedAt: dates.randomElement(using: &rng)!,
                                         expiresAt: dates.randomElement(using: &rng)!,
                                         bootSessionUUID: ["", "BOOT-A", "BOOT-B"].randomElement(using: &rng)!)
            }
            let before = state
            let input = ControllerInput(now: dates.randomElement(using: &rng)!, percent: ints.randomElement(using: &rng)!,
                                        temperature: Bool.random(using: &rng) ? nil : doubles.randomElement(using: &rng)!,
                                        acPresent: .random(using: &rng), lidClosed: .random(using: &rng),
                                        bootSessionUUID: ["", "BOOT-A", "BOOT-B"].randomElement(using: &rng)!)
            let d = ChargeController.decide(input: input, config: config, state: &state)
            verify(d, input: input, config: config, before: before, after: state, into: &v)
        }
        v.report()
    }

    /// Lệnh và bộ xác minh cũng phải tổng với giá trị cực đoan.
    func testCommandsAndVerifiersAreTotal() {
        for hours in [Int.min, -1, 0, 1, 24, 72, 73, Int.max] as [Int?] + [nil] {
            for date in [Date.distantPast, testEpoch, .distantFuture] {
                var state = ControllerState()
                XCTAssertNil(ControllerCommands.startTopUp(state: &state, now: date, hours: hours, acPresent: true,
                                                           bootSessionUUID: ""))
                XCTAssertNotNil(state.topUp)
            }
        }
        for current in [Int.min, -1, 0, 50, 51, Int.max] {
            for percent in [Int.min, 0, 98, 99, Int.max] {
                for seconds in [-1e12, 0, 89.99, 90, 1e12] {
                    _ = EffectVerifier.evaluate(inhibitedSince: testEpoch, now: testEpoch.addingTimeInterval(seconds),
                                                batteryCurrentmA: current, acPresent: true, percent: percent)
                }
            }
        }
    }
}

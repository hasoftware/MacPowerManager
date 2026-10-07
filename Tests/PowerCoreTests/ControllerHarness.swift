import Foundation
@testable import PowerCore

/// Mốc thời gian cố định cho các test (không phụ thuộc đồng hồ máy).
let testEpoch = Date(timeIntervalSinceReferenceDate: 800_000_000)

/// Mô phỏng vòng lặp của helper: giữ cấu hình, trạng thái và đồng hồ giả giữa các lần `decide`.
struct ControllerHarness {
    var config = PowerConfig()
    var state = ControllerState()
    var now = testEpoch
    var bootSessionUUID = "BOOT-A"
    var acPresent = true
    var lidClosed = false
    var temperature: Double? = 30

    init(_ configure: (inout PowerConfig) -> Void = { _ in }) {
        configure(&config)
    }

    /// Một lần đánh giá, mặc định cách lần trước 10 giây (chu kỳ timer của helper).
    @discardableResult
    mutating func step(_ percent: Int, after seconds: TimeInterval = 10) -> ControlDecision {
        now = now.addingTimeInterval(seconds)
        let input = ControllerInput(now: now, percent: percent, temperature: temperature, acPresent: acPresent,
                                    lidClosed: lidClosed, bootSessionUUID: bootSessionUUID)
        return ChargeController.decide(input: input, config: config, state: &state)
    }

    @discardableResult
    mutating func startTopUp(hours: Int? = nil) -> HelperError? {
        ControllerCommands.startTopUp(state: &state, now: now, hours: hours, acPresent: acPresent,
                                      bootSessionUUID: bootSessionUUID)
    }
}

/// Bộ sinh số ngẫu nhiên có seed (SplitMix64) để test thuộc tính lặp lại được.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

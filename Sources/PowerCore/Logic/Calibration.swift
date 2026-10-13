import Foundation

/// Các bước hiệu chuẩn pin: sạc đầy và giữ 1 giờ, xả xuống thấp, sạc đầy lại và giữ 1 giờ, rồi trở về giới hạn.
/// Giữ pin ở 80% lâu ngày làm bộ đo dung lượng lệch dần; một chu trình đầy–cạn–đầy giúp macOS đo lại cho đúng.
public enum CalibrationPhase: String, Codable, Sendable, CaseIterable {
    case chargeToFull, holdFull, discharge, recharge, holdFinal

    /// Bước hiển thị (1…3): sạc đầy, xả, sạc đầy lại.
    public var step: Int {
        switch self {
        case .chargeToFull, .holdFull: 1
        case .discharge: 2
        case .recharge, .holdFinal: 3
        }
    }

    /// Pha cho phép (và cần) sạc tới 100%.
    public var chargesToFull: Bool { self != .discharge }
}

public enum CalibrationEndReason: String, Codable, Sendable {
    case finished, cancelled, expired
}

public struct CalibrationState: Codable, Equatable, Sendable {
    public var phase: CalibrationPhase
    public var startedAt: Date
    public var phaseStartedAt: Date
    /// Không ngắt được adapter (máy không hỗ trợ, bị khóa hoặc lệnh không có hiệu lực): bước xả cần người dùng rút sạc.
    public var needsUnplug: Bool
    /// Sau mỗi hạn thuê xả, adapter được bật lại tới lúc này để helper đọc lại trạng thái cắm sạc thật rồi mới ngắt tiếp.
    public var adapterRestUntil: Date?

    public init(phase: CalibrationPhase = .chargeToFull, startedAt: Date, phaseStartedAt: Date? = nil,
                needsUnplug: Bool = false, adapterRestUntil: Date? = nil) {
        self.phase = phase
        self.startedAt = startedAt
        self.phaseStartedAt = phaseStartedAt ?? startedAt
        self.needsUnplug = needsUnplug
        self.adapterRestUntil = adapterRestUntil
    }
}

/// Logic hiệu chuẩn (thuần, để kiểm thử). `ChargeController.decide` gọi các hàm này.
public enum Calibration {
    /// Giữ 100% chừng này (khi đang cắm sạc) sau mỗi lần sạc đầy, để bộ đo dung lượng ổn định.
    public static let holdSeconds: TimeInterval = 3600
    /// Xả xuống mức này.
    public static let lowPercent = 15
    /// Đang giữ 100% mà pin tụt dưới mức này (ví dụ rút sạc lâu) thì sạc đầy lại.
    public static let refillBelowPercent = 95
    /// Quá thời gian này thì tự hủy (máy không cắm sạc, pin không lên được 100%…).
    public static let maxSeconds: TimeInterval = 48 * 3600
    /// Thời gian bật lại adapter giữa hai hạn thuê xả.
    public static let adapterRestSeconds: TimeInterval = 120

    static func endReason(_ calibration: CalibrationState, input: ControllerInput, config: PowerConfig) -> CalibrationEndReason? {
        let elapsed = input.now.timeIntervalSince(calibration.startedAt)
        if elapsed > maxSeconds || elapsed < -PowerConstants.clockSkewToleranceSeconds { return .expired }
        if config.pauseCharging || config.dischargeEnabled { return .cancelled }
        return nil
    }

    /// Chuyển bước theo mức pin và thời gian. Hoàn tất thì xóa trạng thái và ghi `lastCalibrationAt`.
    static func advance(state: inout ControllerState, input: ControllerInput, effects: inout [ControllerEffect]) {
        guard var cal = state.calibration else { return }
        let now = input.now
        func move(to phase: CalibrationPhase) {
            cal.phase = phase
            cal.phaseStartedAt = now
            effects.append(.calibrationPhase(phase))
        }
        switch cal.phase {
        case .chargeToFull, .recharge:
            if input.percent >= 100 { move(to: cal.phase == .chargeToFull ? .holdFull : .holdFinal) }
        case .holdFull, .holdFinal:
            if input.percent < refillBelowPercent {
                move(to: cal.phase == .holdFull ? .chargeToFull : .recharge)
            } else if !input.acPresent {
                // Chỉ tính thời gian giữ 100% khi đang cắm sạc.
                cal.phaseStartedAt = now
            } else if now.timeIntervalSince(cal.phaseStartedAt) >= holdSeconds {
                if cal.phase == .holdFull {
                    move(to: .discharge)
                } else {
                    state.calibration = nil
                    state.lastCalibrationAt = now
                    effects.append(.calibrationEnded(.finished))
                    return
                }
            }
        case .discharge:
            if input.percent <= lowPercent {
                cal.adapterRestUntil = nil
                state.dischargeStartedAt = nil
                move(to: .recharge)
            }
        }
        state.calibration = cal
    }

    /// Quyết định ở bước xả: ngắt adapter nếu đang cắm sạc (giới hạn bởi hạn thuê xả và tạm nghỉ giữa các lần thuê),
    /// không thì chờ pin tự xả. Không bao giờ sạc ở bước này.
    static func dischargeDecision(state: inout ControllerState, input: ControllerInput)
        -> (charging: Bool, adapter: Bool, reason: ChargeReason) {
        guard var cal = state.calibration else { return (true, true, .normal) }
        defer { state.calibration = cal }
        if cal.needsUnplug || !input.acPresent {
            state.dischargeStartedAt = nil
            return (false, true, .calibrating)
        }
        if input.lidClosed {
            return (false, true, .clamshellSuspended)
        }
        if let rest = cal.adapterRestUntil {
            if input.now < rest { return (false, true, .calibrating) }
            cal.adapterRestUntil = nil
        }
        if ChargeController.dischargeLeaseExpired(state.dischargeStartedAt, now: input.now) {
            state.dischargeStartedAt = nil
            cal.adapterRestUntil = input.now.addingTimeInterval(adapterRestSeconds)
            return (false, true, .calibrating)
        }
        if state.dischargeStartedAt == nil { state.dischargeStartedAt = input.now }
        return (false, false, .calibrating)
    }
}

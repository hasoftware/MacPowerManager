import Foundation

public enum ChargeReason: String, Codable, Sendable {
    case normal
    case limitReached
    case manualPause
    case thermal
    case discharging
    case critical

    public var label: String {
        switch self {
        case .normal: "Sạc bình thường"
        case .limitReached: "Đã đạt giới hạn sạc"
        case .manualPause: "Tạm dừng sạc (dùng adapter)"
        case .thermal: "Tạm dừng do pin nóng"
        case .discharging: "Đang xả pin"
        case .critical: "Pin yếu, cho phép sạc"
        }
    }
}

/// Trạng thái cần nhớ giữa các lần đánh giá (hysteresis).
public struct ControllerState: Equatable, Sendable {
    public var thermalPaused = false
    public var holdingAtLimit = false
    public init() {}
}

public struct ControlDecision: Equatable, Sendable {
    public var chargingEnabled: Bool
    public var adapterEnabled: Bool
    public var reason: ChargeReason
    /// Đã xả tới mức mục tiêu, helper nên tắt `dischargeEnabled`.
    public var dischargeFinished: Bool
}

/// Logic thuần, không đụng phần cứng, để dễ kiểm thử.
public enum ChargeController {
    public static func decide(percent: Int,
                              temperature: Double?,
                              config: PowerConfig,
                              state: inout ControllerState) -> ControlDecision {
        // An toàn trên hết: pin quá yếu thì luôn cho sạc.
        if percent <= PowerConstants.criticalPercent {
            state = ControllerState()
            return ControlDecision(chargingEnabled: true, adapterEnabled: true, reason: .critical,
                                   dischargeFinished: config.dischargeEnabled)
        }

        if config.thermalProtectionEnabled, let t = temperature {
            if t >= config.thermalPauseAbove {
                state.thermalPaused = true
            } else if t <= config.thermalResumeBelow {
                state.thermalPaused = false
            }
        } else {
            state.thermalPaused = false
        }

        if config.chargeLimitEnabled && config.chargeLimit < 100 {
            if percent >= config.chargeLimit {
                state.holdingAtLimit = true
            } else if percent < config.chargeLimit - config.sailingGap {
                state.holdingAtLimit = false
            }
        } else {
            state.holdingAtLimit = false
        }

        var dischargeFinished = false
        if config.dischargeEnabled {
            if percent > config.dischargeTarget {
                return ControlDecision(chargingEnabled: false, adapterEnabled: false, reason: .discharging,
                                       dischargeFinished: false)
            }
            dischargeFinished = true
        }

        let reason: ChargeReason
        if config.pauseCharging {
            reason = .manualPause
        } else if state.thermalPaused {
            reason = .thermal
        } else if state.holdingAtLimit {
            reason = .limitReached
        } else {
            reason = .normal
        }
        return ControlDecision(chargingEnabled: reason == .normal, adapterEnabled: true, reason: reason,
                               dischargeFinished: dischargeFinished)
    }
}

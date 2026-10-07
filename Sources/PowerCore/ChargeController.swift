import Foundation

/// Logic thuần, không đụng phần cứng, để dễ kiểm thử.
///
/// STUB của giai đoạn 0 (v0.3.0): giữ nguyên hành vi v0.2.0. Gói việc "logic" sẽ viết lại theo
/// ControllerInput/ControlDecision mới (top up, sailing, floors, clamshell, chargeToLimitOnce).
public enum ChargeController {
    public static func decide(input: ControllerInput, config: PowerConfig,
                              state: inout ControllerState) -> ControlDecision {
        let percent = input.percent
        let effectiveLimit = config.chargeLimitEnabled ? config.chargeLimit : 100

        // An toàn trên hết: pin quá yếu thì luôn cho sạc.
        if percent <= PowerConstants.criticalPercent {
            let topUp = state.topUp
            state = ControllerState()
            state.topUp = topUp
            return ControlDecision(chargingEnabled: true, adapterEnabled: true, reason: .critical,
                                   effectiveLimit: effectiveLimit,
                                   effects: config.dischargeEnabled ? [.dischargeFinished] : [])
        }

        if config.thermalProtectionEnabled, let t = input.temperature {
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

        var effects: [ControllerEffect] = []
        if config.dischargeEnabled {
            if percent > config.dischargeTarget {
                return ControlDecision(chargingEnabled: false, adapterEnabled: false, reason: .discharging,
                                       effectiveLimit: effectiveLimit)
            }
            effects.append(.dischargeFinished)
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
                               effectiveLimit: effectiveLimit, effects: effects)
    }

    /// Tương thích với code/test cũ: cắm sạc, mở nắp, thời điểm hiện tại.
    public static func decide(percent: Int, temperature: Double?, config: PowerConfig,
                              state: inout ControllerState) -> ControlDecision {
        decide(input: ControllerInput(now: Date(), percent: percent, temperature: temperature),
               config: config, state: &state)
    }
}

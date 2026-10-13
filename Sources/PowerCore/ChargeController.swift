import Foundation

/// Logic thuần, không đụng phần cứng, để dễ kiểm thử.
///
/// Thứ tự ưu tiên (cao xuống thấp):
/// 1. Pin nguy hiểm (≤ `criticalPercent`): luôn sạc và bật adapter, thắng mọi thứ khác.
/// 2. Xả pin: ngắt adapter tới mục tiêu, chỉ khi đang cắm sạc và trong hạn thuê (`dischargeMaxMinutes`);
///    nắp đóng thì tạm ngừng xả.
/// 3. Pin nóng: không chặn sạc dưới `thermalFloorPercent`; vẫn áp dụng khi đang sạc đầy một lần.
/// 4. Tạm dừng sạc thủ công.
/// 2a. Hiệu chuẩn pin: bước xả ngắt adapter (có hạn thuê) hoặc chờ pin tự xả; các bước sạc như sạc đầy một lần
///     (vẫn tôn trọng pin nóng). Bật tạm dừng hoặc xả thủ công thì hủy hiệu chuẩn.
/// 5. Sạc đầy một lần: giới hạn hiệu lực 100%, bỏ qua khoảng sailing.
/// 6. Giới hạn + khoảng sailing: không chặn sạc dưới `sailingFloorPercent`.
///
/// Vòng đời sạc đầy một lần (máy khởi động lại, hết hạn, rút sạc, bật xả) được xét trước tất cả.
/// Hàm tổng: không throw, không trap với mọi đầu vào; `effectiveLimit` luôn trong `limitRange`.
public enum ChargeController {
    public static let limitRange = 20...100

    public static func decide(input: ControllerInput, config rawConfig: PowerConfig,
                              state: inout ControllerState) -> ControlDecision {
        let config = rawConfig.sanitized()
        let percent = input.percent
        var effects: [ControllerEffect] = []

        if let topUp = state.topUp, let reason = topUpEndReason(topUp, input: input, config: config) {
            state.topUp = nil
            effects.append(.topUpEnded(reason))
        }
        if let calibration = state.calibration, let reason = Calibration.endReason(calibration, input: input, config: config) {
            state.calibration = nil
            state.dischargeStartedAt = nil
            effects.append(.calibrationEnded(reason))
        }
        Calibration.advance(state: &state, input: input, effects: &effects)
        let calibrationPhase = state.calibration?.phase
        // Hiệu chuẩn cũng sạc tới 100% như sạc đầy một lần (không giữ mức, bỏ "sạc tới giới hạn ngay").
        let topUpActive = state.topUp != nil || calibrationPhase != nil
        let limitActive = config.chargeLimitEnabled && config.chargeLimit < 100
        let limit = limitActive ? clampLimit(config.chargeLimit) : 100
        let effectiveLimit = topUpActive ? 100 : limit

        // Luôn cập nhật trạng thái trễ (nhiệt, giữ mức) để lần sau nhất quán, kể cả khi nhánh khác thắng.
        updateThermal(input.temperature, config: config, state: &state)
        updateHolding(percent: percent, limit: limit, limitActive: limitActive, gap: config.sailingGap,
                      topUpActive: topUpActive, state: &state, effects: &effects)

        func decision(charging: Bool, adapter: Bool = true, _ reason: ChargeReason) -> ControlDecision {
            ControlDecision(chargingEnabled: charging, adapterEnabled: adapter, reason: reason,
                            effectiveLimit: effectiveLimit, effects: effects)
        }

        // Thời điểm bắt đầu ngắt adapter chỉ có nghĩa khi đang bật xả.
        if !config.dischargeEnabled && calibrationPhase != .discharge { state.dischargeStartedAt = nil }

        // An toàn trên hết: pin quá yếu thì luôn cho sạc.
        if percent <= PowerConstants.criticalPercent {
            if config.dischargeEnabled { effects.append(.dischargeFinished) }
            return decision(charging: true, .critical)
        }

        if let calibrationPhase {
            if calibrationPhase == .discharge {
                let d = Calibration.dischargeDecision(state: &state, input: input)
                return decision(charging: d.charging, adapter: d.adapter, d.reason)
            }
            if state.thermalPaused && percent >= PowerConstants.thermalFloorPercent {
                return decision(charging: false, .thermal)
            }
            return decision(charging: true, .calibrating)
        }

        if config.dischargeEnabled {
            if percent > config.dischargeTarget {
                if dischargeLeaseExpired(state.dischargeStartedAt, now: input.now) {
                    // I2: hết hạn thuê (lease) thì bật lại adapter; helper tắt `dischargeEnabled`.
                    effects.append(.dischargeAborted(.leaseExpired))
                } else if input.acPresent {
                    // Nắp đóng: không ngắt adapter, tránh vòng lặp ngủ/thức.
                    if input.lidClosed { return decision(charging: false, .clamshellSuspended) }
                    if state.dischargeStartedAt == nil { state.dischargeStartedAt = input.now }
                    return decision(charging: false, adapter: false, .discharging)
                }
                // Không cắm sạc (I2 cần acPresent): không có gì để ngắt, pin tự xả.
                // Adapter giữ bật và các quy tắc thường (giới hạn, nhiệt, tạm dừng) áp dụng như bình thường.
            } else {
                effects.append(.dischargeFinished)
            }
        }

        if state.thermalPaused && percent >= PowerConstants.thermalFloorPercent {
            return decision(charging: false, .thermal)
        }
        if config.pauseCharging { return decision(charging: false, .manualPause) }
        if topUpActive { return decision(charging: true, .topUp) }
        if state.holdingAtLimit {
            return decision(charging: false, percent >= limit ? .limitReached : .sailing)
        }
        return decision(charging: true, .normal)
    }

    /// Tương thích với code/test cũ: cắm sạc, mở nắp, thời điểm hiện tại.
    public static func decide(percent: Int, temperature: Double?, config: PowerConfig,
                              state: inout ControllerState) -> ControlDecision {
        decide(input: ControllerInput(now: Date(), percent: percent, temperature: temperature),
               config: config, state: &state)
    }

    /// Lý do kết thúc sạc đầy một lần, nil nếu vẫn tiếp tục. Không kết thúc khi pin đầy:
    /// giữ sạc bật ở 100% cho tới khi rút sạc, hết hạn hoặc bị hủy.
    static func topUpEndReason(_ topUp: TopUpState, input: ControllerInput,
                               config: PowerConfig) -> TopUpEndReason? {
        if !topUp.bootSessionUUID.isEmpty, !input.bootSessionUUID.isEmpty,
           topUp.bootSessionUUID != input.bootSessionUUID {
            return .newBoot
        }
        if input.now >= topUp.expiresAt { return .expired }
        // Sạc đầy theo lịch: rút sạc trước giờ hẹn (ví dụ chuyển chỗ ngồi) không hủy, cắm lại thì sạc tiếp.
        if !input.acPresent, topUp.scheduledFor.map({ input.now >= $0 }) ?? true { return .unplugged }
        if config.dischargeEnabled { return .cancelled }
        return nil
    }

    /// Hạn thuê xả (I2): adapter không được ngắt quá `dischargeMaxMinutes` kể từ lần ngắt đầu tiên.
    /// Đồng hồ lùi đáng kể (đổi giờ hệ thống) cũng coi là hết hạn để không kéo dài việc ngắt adapter.
    static func dischargeLeaseExpired(_ startedAt: Date?, now: Date) -> Bool {
        guard let startedAt else { return false }
        let elapsed = now.timeIntervalSince(startedAt)
        guard elapsed.isFinite else { return true }
        return elapsed >= PowerConstants.dischargeMaxMinutes * 60 || elapsed < -PowerConstants.clockSkewToleranceSeconds
    }

    static func clampLimit(_ value: Int) -> Int {
        min(max(value, limitRange.lowerBound), limitRange.upperBound)
    }

    /// Trễ nhiệt: dừng khi ≥ `thermalPauseAbove`, sạc lại khi ≤ `thermalResumeBelow`.
    /// Không có cảm biến (hoặc giá trị không hợp lệ) thì không dừng.
    private static func updateThermal(_ temperature: Double?, config: PowerConfig, state: inout ControllerState) {
        guard config.thermalProtectionEnabled, let t = temperature, t.isFinite else {
            state.thermalPaused = false
            return
        }
        if t >= config.thermalPauseAbove {
            state.thermalPaused = true
        } else if t <= config.thermalResumeBelow {
            state.thermalPaused = false
        }
    }

    /// Giữ mức (holding): bật khi đạt giới hạn, tắt khi xuống dưới `limit - gap` hoặc dưới mức sàn.
    /// "Sạc tới giới hạn ngay" buộc tắt giữ mức cho tới khi đạt giới hạn rồi tự tắt.
    private static func updateHolding(percent: Int, limit: Int, limitActive: Bool, gap: Int, topUpActive: Bool,
                                      state: inout ControllerState, effects: inout [ControllerEffect]) {
        guard limitActive else {
            state.holdingAtLimit = false
            state.chargeToLimitOnce = false
            return
        }
        // Đang sạc đầy một lần thì sẽ vượt giới hạn, lệnh "sạc tới giới hạn" không còn ý nghĩa.
        if topUpActive { state.chargeToLimitOnce = false }
        if percent >= limit {
            state.holdingAtLimit = true
            if state.chargeToLimitOnce {
                state.chargeToLimitOnce = false
                effects.append(.chargeToLimitDone)
            }
        } else if state.chargeToLimitOnce || percent < limit - gap
                    || percent < PowerConstants.sailingFloorPercent {
            state.holdingAtLimit = false
        }
    }
}

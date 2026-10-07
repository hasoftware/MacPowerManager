import Foundation

/// Các lệnh làm thay đổi `ControllerState` (thuần, để kiểm thử). Helper gọi các hàm này khi nhận
/// `HelperCommand`, rồi chạy lại `ChargeController.decide` để áp dụng ngay.
public enum ControllerCommands {
    public static let topUpHoursRange = 1...72

    /// Bắt đầu sạc đầy một lần. Trả về lỗi nếu không cắm sạc.
    /// Helper cũng phải tắt tạm dừng và xả trong cấu hình (xem `configForTopUp`), nếu không
    /// `decide` sẽ hủy ngay (xả) hoặc không sạc (tạm dừng).
    public static func startTopUp(state: inout ControllerState, now: Date, hours: Int?,
                                  acPresent: Bool, bootSessionUUID: String) -> HelperError? {
        guard acPresent else { return .notPluggedIn }
        let clamped = min(max(hours ?? PowerConstants.topUpDefaultHours, topUpHoursRange.lowerBound),
                          topUpHoursRange.upperBound)
        state.topUp = TopUpState(startedAt: now, expiresAt: now.addingTimeInterval(TimeInterval(clamped) * 3600),
                                 bootSessionUUID: bootSessionUUID)
        state.chargeToLimitOnce = false
        state.holdingAtLimit = false
        return nil
    }

    /// Hủy sạc đầy một lần. Trả về true nếu đang có phiên để hủy.
    @discardableResult
    public static func cancelTopUp(state: inout ControllerState) -> Bool {
        defer { state.topUp = nil }
        return state.topUp != nil
    }

    /// Bỏ qua khoảng sailing một lần để sạc tới giới hạn. Không làm gì khi tắt giới hạn,
    /// giới hạn 100% hoặc đang sạc đầy một lần. Trả về true nếu lệnh có hiệu lực.
    @discardableResult
    public static func chargeToLimitNow(state: inout ControllerState, config: PowerConfig) -> Bool {
        let config = config.sanitized()
        guard config.chargeLimitEnabled, config.chargeLimit < 100, state.topUp == nil else { return false }
        state.chargeToLimitOnce = true
        state.holdingAtLimit = false
        return true
    }

    /// Bản không có cấu hình (tương thích stub giai đoạn 0). Nếu giới hạn đang tắt,
    /// `ChargeController.decide` sẽ tự bỏ cờ ở lần đánh giá kế tiếp.
    public static func chargeToLimitNow(state: inout ControllerState) {
        guard state.topUp == nil else { return }
        state.chargeToLimitOnce = true
        state.holdingAtLimit = false
    }

    /// Cấu hình sau khi bắt đầu sạc đầy một lần: sạc đầy hủy tạm dừng và xả.
    public static func configForTopUp(_ config: PowerConfig) -> PowerConfig {
        var c = config
        c.pauseCharging = false
        c.dischargeEnabled = false
        return c
    }

    /// Cập nhật trạng thái khi người dùng đổi cấu hình (`HelperCommand.setConfig`).
    /// - Bật tạm dừng hoặc bật xả: hủy sạc đầy một lần.
    /// - Nâng giới hạn: bỏ giữ mức để sạc tới giới hạn mới (bật lại giới hạn coi như hạ từ 100%).
    /// - Tắt giới hạn (hoặc 100%): bỏ lệnh "sạc tới giới hạn ngay".
    public static func configDidChange(from old: PowerConfig, to new: PowerConfig,
                                       state: inout ControllerState) -> [ControllerEffect] {
        let old = old.sanitized(), new = new.sanitized()
        var effects: [ControllerEffect] = []
        let pauseStarted = new.pauseCharging && !old.pauseCharging
        let dischargeStarted = new.dischargeEnabled && !old.dischargeEnabled
        if (pauseStarted || dischargeStarted) && cancelTopUp(state: &state) {
            effects.append(.topUpEnded(.cancelled))
        }
        let oldLimit = old.chargeLimitEnabled ? old.chargeLimit : 100
        let newLimit = new.chargeLimitEnabled ? new.chargeLimit : 100
        if newLimit >= 100 {
            state.chargeToLimitOnce = false
        } else if newLimit > oldLimit {
            state.holdingAtLimit = false
        }
        return effects
    }
}

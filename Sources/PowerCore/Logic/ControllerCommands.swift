import Foundation

/// Các lệnh làm thay đổi `ControllerState` (thuần, để kiểm thử).
/// STUB của giai đoạn 0: gói việc "logic" sẽ hoàn thiện và viết test.
public enum ControllerCommands {
    /// Bắt đầu sạc đầy một lần. Trả về lỗi nếu không cắm sạc.
    public static func startTopUp(state: inout ControllerState, now: Date, hours: Int?,
                                  acPresent: Bool, bootSessionUUID: String) -> HelperError? {
        guard acPresent else { return .notPluggedIn }
        let duration = TimeInterval(max(1, min(hours ?? PowerConstants.topUpDefaultHours, 72)) * 3600)
        state.topUp = TopUpState(startedAt: now, expiresAt: now.addingTimeInterval(duration),
                                 bootSessionUUID: bootSessionUUID)
        return nil
    }

    public static func cancelTopUp(state: inout ControllerState) {
        state.topUp = nil
    }

    /// Bỏ qua khoảng sailing một lần để sạc tới giới hạn.
    public static func chargeToLimitNow(state: inout ControllerState) {
        state.chargeToLimitOnce = true
        state.holdingAtLimit = false
    }
}

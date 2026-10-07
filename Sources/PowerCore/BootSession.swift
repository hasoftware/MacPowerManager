import Foundation

/// SMC được reset khi tắt máy, nên sau khi khởi động lại các giá trị helper đã ghi
/// và các chế độ một lần (sạc đầy, sạc tới giới hạn) không còn ý nghĩa.
public enum BootSession {
    /// Trả về trạng thái đã điều chỉnh theo phiên khởi động hiện tại và cho biết đây có phải phiên mới không.
    /// Phiên mới: bỏ sạc đầy một lần, trạng thái giữ ở giới hạn, "sạc tới giới hạn ngay" và `lastWritten`.
    public static func reconcile(_ state: RuntimeState, currentUUID: String) -> (state: RuntimeState, isNewBoot: Bool) {
        guard state.bootSessionUUID != currentUUID else { return (state, false) }
        var s = state
        s.controller.topUp = nil
        s.controller.holdingAtLimit = false
        s.controller.chargeToLimitOnce = false
        s.lastWritten = [:]
        s.bootSessionUUID = currentUUID
        return (s, true)
    }
}

// MARK: - Client được tin cậy (XPC)

import Foundation

/// Cách điều khiển đèn MagSafe.
public enum MagSafeLEDMode: String, Codable, Sendable, CaseIterable {
    /// macOS tự điều khiển (mặc định). Khi giữ pin ở giới hạn, macOS để đèn cam vì tưởng pin chưa đầy.
    case system
    /// Theo trạng thái của MacPowerManager: cam khi đang sạc, xanh khi giữ ở giới hạn hoặc đã đầy, tắt khi đang xả.
    case status
    /// Luôn tắt đèn (ví dụ để sạc qua đêm trong phòng ngủ).
    case off
}

/// Giá trị của SMC key `ACLC` (đèn trên đầu cắm MagSafe).
public enum MagSafeLEDColor: UInt8, Codable, Sendable, CaseIterable {
    /// Trả quyền điều khiển cho hệ thống.
    case system = 0
    case off = 1
    case green = 3
    case amber = 4
}

/// Chọn màu đèn MagSafe (thuần, để kiểm thử).
public enum MagSafeLED {
    public static let key = "ACLC"

    /// Màu cần đặt, nil nếu không cần ghi gì (chế độ hệ thống, hoặc không cắm sạc: đèn không sáng).
    /// - adapterEnabled: false khi helper đang ngắt bộ sạc để xả pin.
    /// - charging: pin đang thật sự nhận dòng sạc.
    public static func desiredColor(mode: MagSafeLEDMode, acPresent: Bool, adapterEnabled: Bool?,
                                    charging: Bool) -> MagSafeLEDColor? {
        guard acPresent else { return nil }
        switch mode {
        case .system: return nil
        case .off: return .off
        case .status:
            if adapterEnabled == false { return .off }
            return charging ? .amber : .green
        }
    }

    /// Giá trị cần ghi ở vòng này. Không còn màu mong muốn mà helper từng đặt màu thì trả quyền cho hệ thống một lần.
    public static func nextWrite(desired: MagSafeLEDColor?, owned: Bool, current: UInt8?) -> MagSafeLEDColor? {
        guard let desired else { return owned ? .system : nil }
        return current == desired.rawValue ? nil : desired
    }
}

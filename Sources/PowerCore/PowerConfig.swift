import Foundation

/// Cấu hình điều khiển sạc, lưu ở helper (root) để vẫn áp dụng khi app đã thoát.
public struct PowerConfig: Codable, Equatable, Sendable {
    /// Dừng sạc khi đạt `chargeLimit`.
    public var chargeLimitEnabled = true
    public var chargeLimit = 80
    /// Sau khi chạm giới hạn, chỉ sạc lại khi pin giảm xuống dưới `chargeLimit - sailingGap`
    /// để tránh bật/tắt sạc liên tục quanh mốc.
    public var sailingGap = 5

    /// Tạm dừng sạc thủ công: máy chạy bằng adapter, pin giữ nguyên.
    public var pauseCharging = false

    /// Ngắt adapter để xả pin xuống `dischargeTarget`, sau đó tự tắt chế độ này.
    public var dischargeEnabled = false
    public var dischargeTarget = 80

    /// Bảo vệ nhiệt: dừng sạc khi pin nóng hơn `thermalPauseAbove`,
    /// sạc lại khi nguội dưới `thermalResumeBelow`.
    public var thermalProtectionEnabled = true
    public var thermalPauseAbove = 40.0
    public var thermalResumeBelow = 35.0

    /// Tắt sạc trước khi máy ngủ nếu đang bật giới hạn, tránh sạc vượt mức khi ngủ.
    public var disableChargingBeforeSleep = true

    public init() {}

    /// Thiếu trường (cấu hình từ bản cũ) hoặc sai kiểu thì dùng giá trị mặc định cho trường đó,
    /// thay vì làm hỏng toàn bộ cấu hình.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PowerConfig()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        chargeLimitEnabled = value(.chargeLimitEnabled, d.chargeLimitEnabled)
        chargeLimit = value(.chargeLimit, d.chargeLimit)
        sailingGap = value(.sailingGap, d.sailingGap)
        pauseCharging = value(.pauseCharging, d.pauseCharging)
        dischargeEnabled = value(.dischargeEnabled, d.dischargeEnabled)
        dischargeTarget = value(.dischargeTarget, d.dischargeTarget)
        thermalProtectionEnabled = value(.thermalProtectionEnabled, d.thermalProtectionEnabled)
        thermalPauseAbove = value(.thermalPauseAbove, d.thermalPauseAbove)
        thermalResumeBelow = value(.thermalResumeBelow, d.thermalResumeBelow)
        disableChargingBeforeSleep = value(.disableChargingBeforeSleep, d.disableChargingBeforeSleep)
    }

    /// Kẹp các giá trị về khoảng hợp lệ.
    /// Có cần giữ mức pin (không sạc thêm) khi máy ngủ hay không.
    public var holdsLevel: Bool {
        (chargeLimitEnabled && chargeLimit < 100) || pauseCharging || dischargeEnabled
    }

    public func sanitized() -> PowerConfig {
        var c = self
        c.chargeLimit = min(max(c.chargeLimit, 20), 100)
        c.sailingGap = min(max(c.sailingGap, 1), 20)
        c.dischargeTarget = min(max(c.dischargeTarget, PowerConstants.criticalPercent + 5), 95)
        c.thermalPauseAbove = min(max(c.thermalPauseAbove, 30), 55)
        c.thermalResumeBelow = min(max(c.thermalResumeBelow, 25), c.thermalPauseAbove - 1)
        return c
    }
}

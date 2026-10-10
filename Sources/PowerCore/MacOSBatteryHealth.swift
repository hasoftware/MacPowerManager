import Foundation

/// Sức khỏe pin theo cách macOS hiển thị (System Settings → Battery → Battery Health).
///
/// macOS không tính "Maximum Capacity" bằng công thức đơn giản từ IOKit: dịch vụ đánh giá pin của hệ thống
/// cập nhật con số này định kỳ. Cách đọc ổn định là `system_profiler SPPowerDataType -json` (khoảng 50 ms).
public struct MacOSBatteryHealth: Equatable, Sendable {
    /// Ví dụ 92 (%).
    public var maximumCapacityPercent: Int?
    public var cycleCount: Int?
    /// "Good", "Fair", "Service Recommended"…
    public var condition: String?

    public init(maximumCapacityPercent: Int? = nil, cycleCount: Int? = nil, condition: String? = nil) {
        self.maximumCapacityPercent = maximumCapacityPercent
        self.cycleCount = cycleCount
        self.condition = condition
    }

    /// Đọc JSON của `system_profiler SPPowerDataType -json`. Trả về nil nếu không có thông tin pin.
    public static func parse(_ data: Data) -> MacOSBatteryHealth? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["SPPowerDataType"] as? [[String: Any]],
              let info = items.lazy.compactMap({ $0["sppower_battery_health_info"] as? [String: Any] }).first
        else { return nil }
        var health = MacOSBatteryHealth()
        if let text = info["sppower_battery_health_maximum_capacity"] as? String {
            health.maximumCapacityPercent = Int(text.filter(\.isNumber))
        } else if let number = info["sppower_battery_health_maximum_capacity"] as? Int {
            health.maximumCapacityPercent = number
        }
        if let value = health.maximumCapacityPercent, !(1...100).contains(value) {
            health.maximumCapacityPercent = nil
        }
        health.cycleCount = (info["sppower_battery_cycle_count"] as? NSNumber)?.intValue
        health.condition = info["sppower_battery_health"] as? String
        return health
    }
}

import Foundation

/// Tần suất đo của app theo ngữ cảnh. App chăm sóc pin không được tự làm hao pin: không ai xem thì không đo,
/// chạy pin hoặc Low Power Mode thì đo thưa hơn.
public enum RefreshPolicy {
    public struct Context: Equatable, Sendable {
        /// Có cửa sổ bảng điều khiển hoặc popover đang hiển thị (không bị che, không thu nhỏ, màn hình đang bật).
        public var uiVisible: Bool
        public var onBattery: Bool
        public var lowPowerMode: Bool

        public init(uiVisible: Bool, onBattery: Bool, lowPowerMode: Bool) {
            self.uiVisible = uiVisible
            self.onBattery = onBattery
            self.lowPowerMode = lowPowerMode
        }
    }

    /// Khoảng làm mới trang Tiến trình người dùng chọn được.
    public static let processChoices: [TimeInterval] = [2, 5, 10]
    public static let defaultProcessInterval: TimeInterval = 5

    /// Khoảng đo khi chỉ cần các số nhỏ ở thanh bên (trang đang mở không hiện số liệu hệ thống).
    public static let sidebarSystemInterval: TimeInterval = 5

    /// Số liệu hệ thống (CPU, bộ nhớ, ổ đĩa, mạng). nil = tạm dừng. `detailed` = trang đang mở có biểu đồ hoặc số liệu
    /// hệ thống trực tiếp; ngược lại chỉ cập nhật số nhỏ ở thanh bên.
    public static func systemInterval(_ c: Context, detailed: Bool = true) -> TimeInterval? {
        guard c.uiVisible else { return nil }
        guard detailed else { return sidebarSystemInterval }
        if c.lowPowerMode { return 3 }
        return c.onBattery ? 2 : 1
    }

    /// Danh sách tiến trình. nil = tạm dừng. Chạy pin tối thiểu 5 giây, Low Power Mode tối thiểu 10 giây.
    public static func processInterval(_ c: Context, chosen: TimeInterval) -> TimeInterval? {
        guard c.uiVisible else { return nil }
        let floor: TimeInterval = c.lowPowerMode ? 10 : c.onBattery ? 5 : 2
        return max(chosen, floor)
    }

    /// Vòng cập nhật pin và trạng thái helper. Thay đổi % pin và cắm/rút sạc vẫn được cập nhật ngay nhờ thông báo
    /// của macOS, nên khi không ai xem có thể chạy thưa.
    public static func batteryInterval(_ c: Context) -> TimeInterval {
        c.uiVisible ? 5 : 60
    }

    /// Dung sai cho timer: macOS gộp các lần đánh thức CPU gần nhau, đỡ tốn pin.
    public static func tolerance(for interval: TimeInterval) -> TimeInterval {
        max(interval * 0.2, 0.1)
    }
}

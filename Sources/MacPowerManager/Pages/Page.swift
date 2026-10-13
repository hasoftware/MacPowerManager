import PowerCore
import SwiftUI

/// Các trang của bảng điều khiển. Trang đang chọn lưu trong `@AppStorage(Page.storageKey)`.
enum Page: String, CaseIterable, Identifiable {
    // Theo dõi
    case overview, history, health
    // Hệ thống
    case systemOverview, cpu, memory, gpu, disk, network
    // Chăm sóc pin
    case limit, heat, discharge, calibration, sleep
    // Ứng dụng
    case menuBar, notifications, system, about

    static let storageKey = "ui.page"

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .overview: "Tổng quan"
        case .history: "Lịch sử"
        case .health: "Tình trạng pin"
        case .systemOverview: "Tổng quan hệ thống"
        case .cpu: "CPU"
        case .memory: "Bộ nhớ"
        case .gpu: "GPU"
        case .disk: "Ổ đĩa"
        case .network: "Mạng"
        case .limit: "Giới hạn sạc"
        case .heat: "Chống nóng"
        case .discharge: "Xả pin"
        case .calibration: "Hiệu chuẩn"
        case .sleep: "Khi ngủ"
        case .menuBar: "Thanh menu"
        case .notifications: "Thông báo"
        case .system: "Hệ thống & helper"
        case .about: "Giới thiệu"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .history: "chart.xyaxis.line"
        case .health: "heart.text.square"
        case .systemOverview: "gauge.with.dots.needle.50percent"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .gpu: "cube.transparent"
        case .disk: "internaldrive"
        case .network: "network"
        case .limit: "battery.75percent"
        case .heat: "thermometer.medium"
        case .discharge: "arrow.down.to.line"
        case .calibration: "arrow.triangle.2.circlepath.circle"
        case .sleep: "moon.zzz"
        case .menuBar: "menubar.rectangle"
        case .notifications: "bell.badge"
        case .system: "lock.shield"
        case .about: "info.circle"
        }
    }

    static let monitor: [Page] = [.overview, .history, .health]
    static let systemGroup: [Page] = [.systemOverview, .cpu, .memory, .gpu, .disk, .network]
    static let care: [Page] = [.limit, .heat, .discharge, .calibration, .sleep]
    static let app: [Page] = [.menuBar, .notifications, .system, .about]

    /// Trang không áp dụng trên máy Intel (không có xả pin và tùy chọn khi ngủ).
    var appleSiliconOnly: Bool { self == .discharge || self == .calibration || self == .sleep }
}

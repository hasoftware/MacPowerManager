import PowerCore
import SwiftUI

/// Các trang của bảng điều khiển. Trang đang chọn lưu trong `@AppStorage(Page.storageKey)`.
enum Page: String, CaseIterable, Identifiable {
    // Theo dõi
    case overview, history, health
    // Hệ thống
    case processes, cpu, memory, gpu, disk, network, energy, aboutMac
    // Chăm sóc pin
    case limit, heat, discharge, calibration, sleep
    // Dọn dẹp
    case cleanup, cleanupHistory
    // Ứng dụng
    case menuBar, notifications, system, about

    static let storageKey = "ui.page"

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .overview: "Tổng quan"
        case .history: "Lịch sử"
        case .health: "Tình trạng pin"
        case .cpu: "CPU"
        case .memory: "Bộ nhớ"
        case .gpu: "GPU"
        case .processes: "Tiến trình"
        case .energy: "Năng lượng"
        case .aboutMac: "Giới thiệu máy này"
        case .disk: "Ổ đĩa"
        case .network: "Mạng"
        case .limit: "Giới hạn sạc"
        case .heat: "Chống nóng"
        case .discharge: "Xả pin"
        case .calibration: "Hiệu chuẩn"
        case .sleep: "Khi ngủ"
        case .cleanup: "Quét tàn dư"
        case .cleanupHistory: "Lịch sử dọn"
        case .menuBar: "Thanh menu"
        case .notifications: "Thông báo"
        case .system: "Hệ thống & helper"
        case .about: "Giới thiệu"
        }
    }

    /// Trang có biểu đồ hoặc số liệu hệ thống trực tiếp: đo mỗi 1–3 giây. Các trang khác chỉ cần số nhỏ ở thanh bên,
    /// đo mỗi 5 giây (`RefreshPolicy.systemInterval`).
    var showsLiveSystemData: Bool {
        switch self {
        case .overview, .cpu, .memory, .gpu, .disk, .network, .energy: true
        default: false
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .history: "chart.xyaxis.line"
        case .health: "heart.text.square"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .gpu: "cube.transparent"
        case .processes: "list.bullet.rectangle"
        case .energy: "bolt.fill"
        case .aboutMac: "laptopcomputer"
        case .disk: "internaldrive"
        case .network: "network"
        case .limit: "battery.75percent"
        case .heat: "thermometer.medium"
        case .discharge: "arrow.down.to.line"
        case .calibration: "arrow.triangle.2.circlepath.circle"
        case .sleep: "moon.zzz"
        case .cleanup: "sparkle.magnifyingglass"
        case .cleanupHistory: "clock.arrow.circlepath"
        case .menuBar: "menubar.rectangle"
        case .notifications: "bell.badge"
        case .system: "lock.shield"
        case .about: "info.circle"
        }
    }

    static let monitor: [Page] = [.overview, .history, .health]
    static let systemGroup: [Page] = [.processes, .cpu, .memory, .gpu, .disk, .network, .energy, .aboutMac]
    static let care: [Page] = [.limit, .heat, .discharge, .calibration, .sleep]
    static let cleanupGroup: [Page] = [.cleanup, .cleanupHistory]
    static let app: [Page] = [.menuBar, .notifications, .system, .about]

    /// Trang không áp dụng trên máy Intel (không có xả pin và tùy chọn khi ngủ).
    var appleSiliconOnly: Bool { self == .discharge || self == .calibration || self == .sleep }
}

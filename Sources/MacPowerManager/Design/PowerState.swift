import AppKit
import PowerCore
import SwiftUI

/// Một trạng thái duy nhất cho toàn bộ giao diện (biểu tượng thanh menu, chip, vòng pin, ô thao tác).
/// Màu luôn đi kèm biểu tượng và chữ, không dùng màu làm tín hiệu duy nhất.
enum PowerState: String, CaseIterable, Sendable {
    case charging, topUp, full, pluggedIn, holding, sailing, paused
    case discharging, dischargeSuspended, heat, critical, low, onBattery, unknown

    var tint: Color { Color(nsColor: nsTint) }

    var nsTint: NSColor {
        switch self {
        case .charging, .full, .pluggedIn: .systemGreen
        case .topUp: .systemBlue
        case .holding, .sailing: .systemTeal
        case .paused: .systemIndigo
        case .discharging, .dischargeSuspended: .systemPurple
        case .heat: .systemOrange
        case .critical, .low: .systemRed
        case .onBattery, .unknown: .systemGray
        }
    }

    /// Biểu tượng cho chip và ô trạng thái.
    var symbol: String {
        switch self {
        case .charging: "bolt.fill"
        case .topUp: "arrow.up.to.line"
        case .full, .pluggedIn: "powerplug.fill"
        case .holding: "leaf.fill"
        case .sailing: "leaf"
        case .paused: "pause.fill"
        case .discharging: "arrow.down.to.line"
        case .dischargeSuspended: "laptopcomputer"
        case .heat: "flame.fill"
        case .critical: "exclamationmark.triangle.fill"
        case .low: "battery.25percent"
        case .onBattery: "battery.75percent"
        case .unknown: "questionmark"
        }
    }

    /// Huy hiệu nhỏ bên trong biểu tượng pin trên thanh menu.
    var badge: String? {
        switch self {
        case .charging: "bolt.fill"
        case .topUp: "arrow.up"
        case .full, .pluggedIn: "powerplug.fill"
        case .holding, .sailing: "leaf.fill"
        case .paused, .dischargeSuspended: "pause.fill"
        case .discharging: "arrow.down"
        case .heat: "flame.fill"
        case .critical, .low: "exclamationmark"
        case .onBattery, .unknown: nil
        }
    }

    var isCharging: Bool { self == .charging || self == .topUp }

    /// Tên ngắn cho chú giải biểu tượng (trang Thanh menu).
    var legendTitle: LocalizedStringKey {
        switch self {
        case .charging: "Đang sạc"
        case .topUp: "Sạc đầy một lần"
        case .full: "Đã sạc đầy"
        case .pluggedIn: "Cắm sạc, không sạc"
        case .holding: "Đang giữ ở giới hạn"
        case .sailing: "Chờ sạc lại"
        case .paused: "Tạm dừng sạc"
        case .discharging: "Đang xả pin"
        case .dischargeSuspended: "Tạm ngừng xả (gập máy)"
        case .heat: "Tạm dừng do pin nóng"
        case .critical: "Pin yếu, sạc bắt buộc"
        case .low: "Pin yếu"
        case .onBattery: "Đang dùng pin"
        case .unknown: "Không rõ"
        }
    }
}

/// Tóm tắt trạng thái hiện tại để hiển thị: trạng thái, chữ trên chip, dòng thời gian, vạch giới hạn.
struct PowerSummary: Equatable {
    var state: PowerState
    var percent: Int
    /// Vạch giới hạn đang áp dụng; nil khi không giới hạn (100%).
    var limit: Int?
    /// Cận dưới của khoảng giữ pin (sailing); nil nếu không có.
    var sailingFloor: Int?
    var title: String
    var detail: String

    static let empty = PowerSummary(state: .unknown, percent: 0, limit: nil, sailingFloor: nil,
                                    title: String(localized: "Không tìm thấy pin"), detail: "")

    /// - config: cấu hình helper đang thực thi, nil nếu chưa có helper (chỉ theo dõi).
    static func make(battery: BatteryInfo?, status: HelperStatus?, config: PowerConfig?,
                     temperature: Double?, lowThreshold: Int, intel: Bool) -> PowerSummary {
        guard let b = battery else { return .empty }
        let status = config == nil ? nil : status
        let percent = b.percent

        var limit: Int?
        var floor: Int?
        if let config {
            let effective = status?.effectiveLimit ?? (config.chargeLimitEnabled ? config.chargeLimit : 100)
            if effective < 100 {
                limit = effective
                if !intel {
                    floor = max(effective - config.sailingGap, PowerConstants.sailingFloorPercent)
                }
            }
        }

        let state = resolveState(b, status: status, lowThreshold: lowThreshold)
        var summary = PowerSummary(state: state, percent: percent, limit: limit, sailingFloor: floor,
                                   title: "", detail: "")
        let configured = config?.chargeLimit ?? 100
        let remaining = b.timeRemaining.map { Format.duration(minutes: $0) }

        switch state {
        case .charging:
            summary.title = String(localized: "Đang sạc")
            if intel, let firmware = status?.firmwareLimit, firmware < 100 {
                summary.detail = String(localized: "Firmware dừng sạc ở khoảng \(firmware)%")
            } else if let limit, let minutes = b.minutesToCharge(to: limit) {
                summary.detail = String(localized: "Tới \(limit)% sau \(Format.duration(minutes: minutes))")
            } else if let remaining {
                summary.detail = String(localized: "Đầy sau \(remaining)")
            } else {
                summary.detail = String(localized: "Đang ước tính thời gian sạc…")
            }
        case .topUp:
            summary.title = String(localized: "Sạc đầy một lần")
            if let remaining, b.isCharging {
                summary.detail = String(localized: "Đầy sau \(remaining) · giới hạn \(configured)% trở lại khi rút sạc")
            } else {
                summary.detail = String(localized: "Giới hạn \(configured)% trở lại khi rút sạc")
            }
        case .full:
            if status?.topUp != nil {
                summary.title = String(localized: "Đã đầy · giữ 100%")
                summary.detail = String(localized: "Giữ 100% tới khi rút sạc")
            } else {
                summary.title = String(localized: "Đã sạc đầy")
                summary.detail = String(localized: "Máy dùng điện trực tiếp từ bộ sạc")
            }
        case .pluggedIn:
            summary.title = String(localized: "Đang cắm sạc")
            summary.detail = String(localized: "Không sạc, máy dùng điện từ bộ sạc")
        case .holding:
            summary.title = String(localized: "Đang giữ ở \(configured)%")
            summary.detail = String(localized: "Máy dùng điện trực tiếp từ bộ sạc")
        case .sailing:
            summary.title = String(localized: "Chờ sạc lại")
            if let floor {
                summary.detail = String(localized: "Sạc lại khi pin xuống dưới \(floor)%")
            } else {
                summary.detail = String(localized: "Máy dùng điện trực tiếp từ bộ sạc")
            }
        case .paused:
            summary.title = String(localized: "Đã tạm dừng sạc")
            summary.detail = String(localized: "Pin giữ nguyên, máy dùng điện từ bộ sạc")
        case .discharging:
            let target = config?.dischargeTarget ?? 0
            summary.title = String(localized: "Đang xả về \(target)%")
            if let minutes = dischargeMinutes(b, to: target) {
                summary.detail = String(localized: "Còn khoảng \(Format.duration(minutes: minutes))")
            } else {
                summary.detail = String(localized: "Máy chạy bằng pin dù vẫn cắm sạc")
            }
        case .dischargeSuspended:
            summary.title = String(localized: "Tạm ngừng xả")
            summary.detail = String(localized: "Nắp máy đang đóng, sẽ xả tiếp khi mở nắp")
        case .heat:
            summary.title = String(localized: "Tạm dừng do pin nóng")
            let resume = Int(config?.thermalResumeBelow ?? 35)
            summary.detail = String(localized: "Pin \(Format.temperature(temperature)) · sạc lại khi ≤ \(resume)°C")
        case .critical:
            summary.title = String(localized: "Pin yếu · sạc bắt buộc")
            summary.detail = String(localized: "Dưới \(PowerConstants.criticalPercent)% luôn cho phép sạc")
        case .low, .onBattery:
            summary.title = state == .low ? String(localized: "Pin yếu") : String(localized: "Đang dùng pin")
            summary.detail = remaining.map { String(localized: "Còn \($0)") }
                ?? String(localized: "Đang ước tính thời gian còn lại…")
        case .unknown:
            return .empty
        }
        return summary
    }

    private static func resolveState(_ b: BatteryInfo, status: HelperStatus?, lowThreshold: Int) -> PowerState {
        let natural: PowerState = {
            if b.externalConnected {
                if b.isCharging { return .charging }
                return b.fullyCharged || b.percent >= 100 ? .full : .pluggedIn
            }
            return b.percent <= lowThreshold ? .low : .onBattery
        }()
        guard let status else { return natural }
        switch status.reason {
        case .critical: return .critical
        case .discharging: return .discharging
        case .clamshellSuspended: return .dischargeSuspended
        default: break
        }
        // Đã rút sạc thì các lý do "giữ mức" không còn ý nghĩa.
        guard b.externalConnected else { return natural }
        // Intel: firmware vẫn có thể sạc thêm vài % dù helper báo đạt giới hạn.
        if b.isCharging && status.chargingKeys == "BCLM" { return .charging }
        switch status.reason {
        case .thermal: return .heat
        case .manualPause: return .paused
        case .limitReached: return .holding
        case .sailing: return .sailing
        case .topUp: return natural == .full ? .full : .topUp
        default: return natural
        }
    }

    /// Số phút để xả từ mức hiện tại về `target`, theo dòng xả hiện tại.
    static func dischargeMinutes(_ b: BatteryInfo, to target: Int) -> Int? {
        guard b.amperage < 0, b.maxCapacity > 0, b.percent > target else { return nil }
        let mAh = Double(b.percent - target) / 100 * Double(b.maxCapacity)
        return Int((mAh / Double(-b.amperage) * 60).rounded())
    }
}

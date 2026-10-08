import PowerCore
import SwiftUI

/// Thông báo theo ngữ cảnh ở đầu Tổng quan và bảng nhanh. Mỗi lúc chỉ hiện một banner, theo thứ tự ưu tiên
/// trong `AppModel.banners`.
enum AppBanner: Equatable, Identifiable {
    case helperMissing
    /// `"?"`: helper đã cài nhưng không nhận kết nối từ bản app này.
    case helperOutdated(String)
    case conflict(ConflictFinding)
    case foreignWrite(ForeignWrite)
    /// Chi tiết của helper (`EffectState.ineffective`) là tiếng Việt, chỉ hiện ở trang Hệ thống & helper.
    case ineffective
    case locked([String], fallback: String?)
    case unsupported
    case moveApp
    case heat(Double?, resume: Double?)
    case lowBattery(Int)
    /// Có bản mới trên GitHub (version không có "v", ví dụ "0.3.0").
    case update(String)

    enum Action: Equatable {
        case installHelper, reinstallHelper, openSystemPage, moveApp, reportIssue, showWhatsNew
    }

    var id: String {
        switch self {
        case .helperMissing: "helperMissing"
        case .helperOutdated: "helperOutdated"
        case .conflict: "conflict"
        case .foreignWrite: "foreignWrite"
        case .ineffective: "ineffective"
        case .locked: "locked"
        case .unsupported: "unsupported"
        case .moveApp: "moveApp"
        case .heat: "heat"
        case .lowBattery: "lowBattery"
        case .update: "update"
        }
    }

    var title: String {
        switch self {
        case .helperMissing: String(localized: "Chưa cài helper điều khiển sạc")
        case .helperOutdated("?"): String(localized: "Cần cài lại helper")
        case .helperOutdated(let version): String(localized: "Helper đã cũ (v\(version)), cần cập nhật")
        case .conflict(let app):
            if let limit = app.chargeLimit {
                String(localized: "\(app.name) cũng đang điều khiển sạc (giới hạn \(limit)%)")
            } else {
                String(localized: "\(app.name) cũng đang điều khiển sạc")
            }
        case .foreignWrite: String(localized: "Có ứng dụng khác đang ghi vào SMC")
        case .ineffective: String(localized: "Lệnh dừng sạc chưa có hiệu lực")
        case .locked: String(localized: "Firmware đã khóa một số key điều khiển")
        case .unsupported: String(localized: "Máy này chưa hỗ trợ điều khiển sạc")
        case .moveApp: String(localized: "App đang chạy từ vị trí tạm")
        case .heat: String(localized: "Tạm dừng sạc do pin nóng")
        case .lowBattery(let percent): String(localized: "Pin yếu (\(percent)%)")
        case .update(let version): String(localized: "Có bản cập nhật v\(version)")
        }
    }

    var message: String {
        switch self {
        case .helperMissing:
            Platform.isAppleSilicon
                ? String(localized: "Giới hạn sạc, xả pin và chống nóng cần một helper chạy quyền quản trị. App vẫn theo dõi pin bình thường.")
                : String(localized: "Máy Intel: điều khiển sạc đang thử nghiệm và cần một helper chạy quyền quản trị.")
        case .helperOutdated("?"):
            String(localized: "Helper đã cài nhưng không nhận kết nối từ bản app này (thường gặp sau khi cập nhật app). Cài lại để tiếp tục điều khiển sạc.")
        case .helperOutdated:
            String(localized: "Cập nhật helper để dùng đầy đủ tính năng của bản app này.")
        case .conflict(let app):
            String(localized: "Hai ứng dụng cùng ghi vào SMC có thể khiến sạc bật/tắt liên tục. Hãy thoát \(app.name) hoặc đặt giới hạn của nó về 100%.")
        case .foreignWrite(let write):
            String(localized: "Key \(write.key) bị đổi từ \(write.expected) thành \(write.found) lúc \(Format.time(write.at)).")
        case .ineffective:
            String(localized: "Pin vẫn nhận dòng sạc sau khi đã chặn sạc. Có thể macOS hoặc ứng dụng khác đang can thiệp.")
        case .locked(let keys, let fallback):
            if let fallback {
                String(localized: "Bị khóa: \(keys.joined(separator: ", ")). Helper đang dùng \(fallback) thay thế.")
            } else {
                String(localized: "Bị khóa: \(keys.joined(separator: ", ")). Không còn cách chặn sạc nào dùng được trên firmware này.")
            }
        case .unsupported:
            String(localized: "App vẫn hiển thị thông tin pin. Bạn có thể giúp mở rộng hỗ trợ bằng cách gửi kết quả `make probe` lên GitHub Issues.")
        case .moveApp:
            String(localized: "Chuyển vào Applications để app hoạt động ổn định.")
        case .heat(let temperature, let resume):
            if let resume {
                String(localized: "Pin \(Format.temperature(temperature)). Sẽ sạc lại khi nguội dưới \(Int(resume))°C.")
            } else {
                String(localized: "Pin \(Format.temperature(temperature)). Sẽ sạc lại khi pin nguội.")
            }
        case .lowBattery:
            String(localized: "Hãy cắm sạc.")
        case .update:
            String(localized: "Xem các cải tiến trong bản mới rồi tải về từ GitHub. Sau khi cập nhật, app sẽ nhắc cài lại helper.")
        }
    }

    var symbol: String {
        switch self {
        case .helperMissing, .helperOutdated: "lock.shield"
        case .conflict, .foreignWrite: "exclamationmark.2"
        case .ineffective: "bolt.trianglebadge.exclamationmark"
        case .locked: "lock.fill"
        case .unsupported: "questionmark.circle"
        case .moveApp: "folder.badge.plus"
        case .heat: "flame.fill"
        case .lowBattery: "battery.25percent"
        case .update: "arrow.down.circle"
        }
    }

    var tint: Color {
        switch self {
        case .helperMissing, .helperOutdated: .accentColor
        case .conflict, .foreignWrite, .ineffective, .locked: .yellow
        case .unsupported: .blue
        case .moveApp: .orange
        case .heat: .orange
        case .lowBattery: .red
        case .update: .blue
        }
    }

    var action: Action? {
        switch self {
        case .helperMissing: .installHelper
        case .helperOutdated: .reinstallHelper
        case .conflict, .foreignWrite, .ineffective, .locked: .openSystemPage
        case .unsupported: .reportIssue
        case .moveApp: .moveApp
        case .update: .showWhatsNew
        case .heat, .lowBattery: nil
        }
    }

    /// Nhãn nút ngắn cho banner một dòng ở bảng nhanh.
    var shortActionTitle: String {
        switch action {
        // Không dùng "Cài đặt…": khóa đó là mục "Settings…" của menu app.
        case .installHelper: String(localized: "Cài…")
        case .reinstallHelper: self == .helperOutdated("?") ? String(localized: "Cài lại…") : String(localized: "Cập nhật…")
        case .openSystemPage: String(localized: "Chi tiết")
        case .moveApp: String(localized: "Chuyển")
        case .reportIssue: String(localized: "Báo lỗi")
        case .showWhatsNew: String(localized: "Có gì mới")
        case nil: ""
        }
    }

    var actionTitle: String {
        switch action {
        case .installHelper: Platform.isAppleSilicon ? String(localized: "Cài helper…") : String(localized: "Cài helper (thử nghiệm)…")
        case .reinstallHelper:
            self == .helperOutdated("?") ? String(localized: "Cài lại helper…") : String(localized: "Cập nhật helper…")
        case .openSystemPage: String(localized: "Xem chi tiết")
        case .moveApp: String(localized: "Chuyển vào Applications")
        case .reportIssue: String(localized: "Mở GitHub Issues")
        case .showWhatsNew: String(localized: "Xem có gì mới")
        case nil: ""
        }
    }
}

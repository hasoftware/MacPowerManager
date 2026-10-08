import Foundation
import PowerCore
import UserNotifications

/// Gửi thông báo khi trạng thái pin thay đổi đáng chú ý. Mỗi sự kiện chỉ báo một lần
/// cho tới khi điều kiện kết thúc.
@MainActor
final class Notifier {
    private var lastReason: ChargeReason?
    private var lowBatteryNotified = false
    private var fullNotified = false
    private var wasDischarging = false
    private var lastTopUp: TopUpState?
    private var ineffectiveNotified = false
    private var notifiedControllers: Set<String> = []

    /// UNUserNotificationCenter chỉ dùng được khi chạy trong app bundle.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Quyền gửi thông báo hiện tại, nil khi không chạy trong app bundle.
    func authorizationStatus() async -> UNAuthorizationStatus? {
        guard let center else { return nil }
        return await center.notificationSettings().authorizationStatus
    }

    func evaluate(battery: BatteryInfo, temperature: Double?, helper: HelperStatus?, prefs: Preferences,
                  firmwareControlled: Bool = false, conflicts: [ConflictFinding] = []) {
        // Intel: firmware còn sạc (vượt giới hạn ~3% hoặc sạc bù) thì chưa thực sự "đạt giới hạn" hay "tạm dừng";
        // đang rút sạc thì cũng không có gì để báo. Bỏ qua để không báo nhầm và không báo lại sau mỗi lần sạc bù.
        let skipReason = firmwareControlled && (battery.isCharging || !battery.externalConnected)
        if !skipReason, let reason = helper?.reason, reason != lastReason {
            if lastReason != nil {
                if reason == .limitReached, prefs.notifyLimitReached {
                    post(id: "limit-reached", String(localized: "Đã đạt giới hạn sạc"),
                         String(localized: "Pin ở mức \(battery.percent)%. Máy sẽ dùng điện trực tiếp từ bộ sạc."))
                } else if reason == .thermal, prefs.notifyThermal {
                    let t = Format.temperature(temperature)
                    post(id: "thermal", String(localized: "Tạm dừng sạc do pin nóng"),
                         String(localized: "Nhiệt độ pin \(t). Sẽ sạc lại khi pin nguội."))
                }
            }
            lastReason = reason
        }

        let discharging = helper?.config.dischargeEnabled ?? false
        if wasDischarging && !discharging && prefs.notifyDischargeDone {
            post(id: "discharge-done", String(localized: "Đã xả pin xong"),
                 String(localized: "Pin hiện ở mức \(battery.percent)%."))
        }
        wasDischarging = discharging

        // Sạc đầy một lần kết thúc (đầy, rút sạc, hết hạn hoặc bị hủy).
        let topUp = helper?.topUp
        if lastTopUp != nil && topUp == nil && helper != nil && prefs.notifyTopUpEnded {
            let limit = helper?.config.chargeLimit ?? 100
            post(id: "topup-ended", String(localized: "Đã kết thúc sạc đầy một lần"),
                 String(localized: "Pin ở mức \(battery.percent)%. Giới hạn \(limit)% được áp dụng trở lại."))
        }
        if helper != nil { lastTopUp = topUp }

        // Không dùng chi tiết của helper (tiếng Việt, không dịch được) trong thông báo.
        if case .ineffective = helper?.effect {
            if !ineffectiveNotified && prefs.notifyIneffective {
                post(id: "effect-ineffective", String(localized: "Lệnh dừng sạc chưa có hiệu lực"),
                     String(localized: "Pin vẫn nhận dòng sạc. Có thể macOS hoặc ứng dụng khác đang can thiệp."))
            }
            ineffectiveNotified = true
        } else if helper?.effect != nil {
            ineffectiveNotified = false
        }

        // Ứng dụng điều khiển sạc khác: báo một lần cho mỗi ứng dụng mới chạy hoặc khi helper thấy key bị ghi đè.
        var controllers = Set(conflicts.filter(\.running).map(\.name))
        if let write = helper?.foreignWrites?.last { controllers.insert("key:\(write.key)") }
        let fresh = controllers.subtracting(notifiedControllers)
        if !fresh.isEmpty && prefs.notifyForeignController {
            if let app = conflicts.first(where: { $0.running && fresh.contains($0.name) }) {
                post(id: "foreign-controller", String(localized: "\(app.name) cũng đang điều khiển sạc"),
                     String(localized: "Hai ứng dụng cùng điều khiển sạc có thể khiến sạc bật/tắt liên tục. Hãy thoát một bên."))
            } else if let write = helper?.foreignWrites?.last {
                post(id: "foreign-controller", String(localized: "Có ứng dụng khác đang ghi vào SMC"),
                     String(localized: "Key \(write.key) bị thay đổi ngoài MacPowerManager."))
            }
        }
        notifiedControllers = controllers

        if !battery.externalConnected && battery.percent <= prefs.lowBatteryThreshold {
            if !lowBatteryNotified && prefs.notifyLowBattery {
                post(id: "low-battery", String(localized: "Pin yếu"),
                     String(localized: "Còn \(battery.percent)%. Hãy cắm sạc."))
            }
            lowBatteryNotified = true
        } else if battery.externalConnected || battery.percent > prefs.lowBatteryThreshold + 5 {
            lowBatteryNotified = false
        }

        let limitActive = (helper?.config.chargeLimitEnabled ?? false) && helper?.topUp == nil
        if battery.externalConnected && battery.percent >= 100 && !limitActive {
            if !fullNotified && prefs.notifyLimitReached {
                post(id: "full", String(localized: "Pin đã đầy"), String(localized: "Có thể rút sạc."))
            }
            fullNotified = true
        } else if battery.percent < 95 {
            fullNotified = false
        }
    }

    /// Định danh cố định theo loại sự kiện: thông báo mới thay thế thông báo cũ cùng loại thay vì chồng lên.
    private func post(id: String, _ title: String, _ body: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "com.hasoftware.MacPowerManager.\(id)", content: content, trigger: nil))
    }
}

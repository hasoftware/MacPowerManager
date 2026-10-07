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

    /// UNUserNotificationCenter chỉ dùng được khi chạy trong app bundle.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func evaluate(battery: BatteryInfo, temperature: Double?, helper: HelperStatus?, prefs: Preferences,
                  firmwareControlled: Bool = false) {
        // Intel: firmware còn sạc (vượt giới hạn ~3% hoặc sạc bù) thì chưa thực sự "đạt giới hạn" hay "tạm dừng";
        // đang rút sạc thì cũng không có gì để báo. Bỏ qua để không báo nhầm và không báo lại sau mỗi lần sạc bù.
        let skipReason = firmwareControlled && (battery.isCharging || !battery.externalConnected)
        if !skipReason, let reason = helper?.reason, reason != lastReason {
            if lastReason != nil {
                if reason == .limitReached, prefs.notifyLimitReached {
                    post(id: "limit-reached", "Đã đạt giới hạn sạc", "Pin ở mức \(battery.percent)%. Máy sẽ dùng điện trực tiếp từ adapter.")
                } else if reason == .thermal, prefs.notifyThermal {
                    post(id: "thermal", "Tạm dừng sạc do pin nóng",
                         "Nhiệt độ pin \(Format.temperature(temperature)). Sẽ sạc lại khi pin nguội.")
                }
            }
            lastReason = reason
        }

        let discharging = helper?.config.dischargeEnabled ?? false
        if wasDischarging && !discharging && prefs.notifyDischargeDone {
            post(id: "discharge-done", "Đã xả pin xong", "Pin hiện ở mức \(battery.percent)%.")
        }
        wasDischarging = discharging

        if !battery.externalConnected && battery.percent <= prefs.lowBatteryThreshold {
            if !lowBatteryNotified && prefs.notifyLowBattery {
                post(id: "low-battery", "Pin yếu", "Còn \(battery.percent)%. Hãy cắm sạc.")
            }
            lowBatteryNotified = true
        } else if battery.externalConnected || battery.percent > prefs.lowBatteryThreshold + 5 {
            lowBatteryNotified = false
        }

        let limitActive = helper?.config.chargeLimitEnabled ?? false
        if battery.externalConnected && battery.percent >= 100 && !limitActive {
            if !fullNotified && prefs.notifyLimitReached {
                post(id: "full", "Pin đã đầy", "Có thể rút sạc.")
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

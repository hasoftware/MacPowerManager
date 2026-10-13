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
    /// Mục tiêu xả ở lần helper báo đang xả gần nhất; nil khi không xả. Không đổi khi mất kết nối helper.
    private var dischargeTarget: Int?
    private var lastTopUp: TopUpState?
    private var lastCalibration: CalibrationState?
    private var unplugNotified = false
    private var ineffectiveNotified = false
    private var notifiedControllers: Set<String> = []

    private let defaults: UserDefaults
    /// Thay cho UNUserNotificationCenter (kiểm thử): nhận (id, tiêu đề, nội dung).
    private let sink: ((String, String, String) -> Void)?

    /// Lần ghi từ bên ngoài đã báo gần nhất (key + thời điểm), lưu lại để không báo lại sau khi mở lại app.
    static let foreignWriteAtKey = "notifier.foreignWrite.at"
    private static let foreignWritePostedKey = "notifier.foreignWrite.postedAt"
    static let foreignWriteKeyKey = "notifier.foreignWrite.key"
    /// Phiên bản mới đã báo gần nhất: mỗi phiên bản chỉ báo một lần, kể cả sau khi mở lại app.
    static let updateVersionKey = "notifier.update.version"
    /// Định danh của thông báo "Có phiên bản mới" (bấm vào sẽ mở cửa sổ Có gì mới).
    nonisolated static let updateNotificationID = "update-available"
    /// Mốc tính "đã lâu chưa hiệu chuẩn" khi chưa hiệu chuẩn lần nào (lần đầu app thấy helper có tính năng này).
    static let calibrationSinceKey = "notifier.calibration.since"
    static let calibrationRemindedKey = "notifier.calibration.remindedAt"
    static let calibrationInterval: TimeInterval = 60 * 24 * 3600
    static let calibrationRemindAgain: TimeInterval = 30 * 24 * 3600

    init(defaults: UserDefaults = .standard, sink: ((String, String, String) -> Void)? = nil) {
        self.defaults = defaults
        self.sink = sink
    }

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
                  firmwareControlled: Bool = false, conflicts: [ConflictFinding] = [], now: Date = Date()) {
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

        // Xả xong: chỉ khi helper tắt chế độ xả mà pin đã về tới mục tiêu. Người dùng dừng xả, sạc đầy một lần
        // hoặc đổi cấu hình (pin còn trên mục tiêu) không phải "xả xong"; mất kết nối helper thì bỏ qua lần này.
        if let helper {
            if let target = dischargeTarget, !helper.config.dischargeEnabled,
               battery.percent <= target, prefs.notifyDischargeDone {
                post(id: "discharge-done", String(localized: "Đã xả pin xong"),
                     String(localized: "Pin hiện ở mức \(battery.percent)%."))
            }
            dischargeTarget = helper.config.dischargeEnabled ? helper.config.dischargeTarget : nil
        }

        // Sạc đầy một lần kết thúc (đầy, rút sạc, hết hạn hoặc bị hủy).
        let topUp = helper?.topUp
        if lastTopUp != nil && topUp == nil && helper != nil && prefs.notifyTopUpEnded {
            let limit = helper?.config.chargeLimit ?? 100
            post(id: "topup-ended", String(localized: "Đã kết thúc sạc đầy một lần"),
                 String(localized: "Pin ở mức \(battery.percent)%. Giới hạn \(limit)% được áp dụng trở lại."))
        }
        if helper != nil { lastTopUp = topUp }

        if let helper { evaluateCalibration(helper, battery: battery, prefs: prefs, now: now) }

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

        // Ứng dụng điều khiển sạc khác: báo một lần cho mỗi ứng dụng mới chạy.
        let running = Set(conflicts.filter(\.running).map(\.name))
        let freshApp = conflicts.first { $0.running && !notifiedControllers.contains($0.name) }
        if let app = freshApp, prefs.notifyForeignController {
            post(id: "foreign-controller", String(localized: "\(app.name) cũng đang điều khiển sạc"),
                 String(localized: "Hai ứng dụng cùng điều khiển sạc có thể khiến sạc bật/tắt liên tục. Hãy thoát một bên."))
        }
        notifiedControllers = running

        // Helper thấy key bị ghi đè: báo theo "sự việc" chứ không theo từng lần ghi. Một tool khác ghi lại key
        // mỗi phút chỉ tạo một thông báo trong mỗi `AppModel.foreignWriteWindow`; nếu đã biết ứng dụng nào đang
        // chạy (đã báo ở trên) thì không báo thêm. Nhớ qua các lần mở app; mất kết nối helper (nil) không xóa.
        if let write = newForeignWrite(in: helper?.foreignWrites, now: now) {
            let lastPosted = defaults.object(forKey: Self.foreignWritePostedKey) as? Double
            let recentlyPosted = lastPosted.map { now.timeIntervalSinceReferenceDate - $0 < AppModel.foreignWriteWindow } ?? false
            if running.isEmpty && !recentlyPosted && prefs.notifyForeignController {
                defaults.set(now.timeIntervalSinceReferenceDate, forKey: Self.foreignWritePostedKey)
                post(id: "foreign-controller", String(localized: "Có ứng dụng khác đang ghi vào SMC"),
                     String(localized: "Key \(write.key) bị thay đổi ngoài MacPowerManager."))
            }
            defaults.set(write.at.timeIntervalSinceReferenceDate, forKey: Self.foreignWriteAtKey)
            defaults.set(write.key, forKey: Self.foreignWriteKeyKey)
        }

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

    /// Hiệu chuẩn: báo khi xong, khi cần người dùng rút sạc (máy không tự ngắt được bộ sạc), và nhắc định kỳ.
    private func evaluateCalibration(_ helper: HelperStatus, battery: BatteryInfo, prefs: Preferences, now: Date) {
        let calibration = helper.calibration
        if let last = lastCalibration, calibration == nil, let done = helper.lastCalibrationAt, done >= last.startedAt,
           prefs.notifyCalibration {
            let limit = helper.config.chargeLimitEnabled ? helper.config.chargeLimit : 100
            post(id: "calibration", String(localized: "Đã hiệu chuẩn pin xong"),
                 String(localized: "Pin trở về giới hạn \(limit)%. Số % và dung lượng tối đa giờ được đo lại chính xác hơn."))
        }
        lastCalibration = calibration

        if calibration?.phase == .discharge, calibration?.needsUnplug == true, battery.externalConnected {
            if !unplugNotified && prefs.notifyCalibration {
                post(id: "calibration", String(localized: "Rút sạc để tiếp tục hiệu chuẩn"),
                     String(localized: "Máy không tự ngắt được bộ sạc. Hãy rút sạc và dùng máy tới khi pin còn \(Calibration.lowPercent)%."))
            }
            unplugNotified = true
        } else {
            unplugNotified = false
        }

        // Nhắc định kỳ (không áp dụng cho Intel: chưa hỗ trợ hiệu chuẩn).
        guard prefs.calibrationReminder, calibration == nil, helper.chargingKeys != "BCLM" else { return }
        let since: Date
        if let last = helper.lastCalibrationAt {
            since = last
        } else if let first = defaults.object(forKey: Self.calibrationSinceKey) as? Date {
            since = first
        } else {
            defaults.set(now, forKey: Self.calibrationSinceKey)
            return
        }
        guard now.timeIntervalSince(since) >= Self.calibrationInterval else { return }
        if let reminded = defaults.object(forKey: Self.calibrationRemindedKey) as? Date,
           now.timeIntervalSince(reminded) < Self.calibrationRemindAgain { return }
        defaults.set(now, forKey: Self.calibrationRemindedKey)
        post(id: "calibration-reminder", String(localized: "Đã lâu chưa hiệu chuẩn pin"),
             String(localized: "Hiệu chuẩn vài tháng một lần giúp số % pin chính xác hơn. Mở MacPowerManager → Hiệu chuẩn."))
    }

    /// Có phiên bản mới: báo một lần cho mỗi phiên bản. `post` false (người dùng tự bấm kiểm tra và đã thấy kết quả)
    /// thì chỉ ghi nhận là đã báo.
    func updateAvailable(_ release: ReleaseInfo, prefs: Preferences, post shouldPost: Bool = true) {
        guard let version = release.version?.description,
              defaults.string(forKey: Self.updateVersionKey) != version else { return }
        defaults.set(version, forKey: Self.updateVersionKey)
        guard shouldPost, prefs.notifyUpdate else { return }
        post(id: Self.updateNotificationID, String(localized: "Có phiên bản mới"),
             String(localized: "MacPowerManager v\(version) đã sẵn sàng. Bấm để xem có gì mới."))
    }

    /// Định danh đầy đủ của một thông báo theo loại sự kiện.
    nonisolated static func requestIdentifier(_ id: String) -> String { "com.hasoftware.MacPowerManager.\(id)" }

    /// Lần ghi từ bên ngoài mới nhất chưa được báo, nil nếu đã báo (cùng key và thời điểm, hoặc cũ hơn lần đã
    /// báo) hoặc đã quá `AppModel.foreignWriteWindow` (sự việc cũ, ví dụ lần đầu chạy bản này).
    private func newForeignWrite(in writes: [ForeignWrite]?, now: Date) -> ForeignWrite? {
        guard let write = AppModel.recentForeignWrite(in: writes, now: now) else { return nil }
        let at = write.at.timeIntervalSinceReferenceDate
        if let lastAt = defaults.object(forKey: Self.foreignWriteAtKey) as? Double {
            if at < lastAt { return nil }
            if at == lastAt && write.key == defaults.string(forKey: Self.foreignWriteKeyKey) { return nil }
        }
        return write
    }

    /// Định danh cố định theo loại sự kiện: thông báo mới thay thế thông báo cũ cùng loại thay vì chồng lên.
    private func post(id: String, _ title: String, _ body: String) {
        if let sink { return sink(id, title, body) }
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: Self.requestIdentifier(id), content: content, trigger: nil))
    }
}

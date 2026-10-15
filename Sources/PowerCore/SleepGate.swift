import Foundation

/// Trạng thái thức/ngủ của máy theo góc nhìn của helper.
public enum WakePhase: String, Codable, Sendable {
    case awake
    /// Đã nhận WillSleep, máy sắp ngủ.
    case sleepPending
    /// Máy thức ngầm (Power Nap, sạc, bảo trì), màn hình chưa bật.
    case darkWake
}

/// Quy tắc khi máy sắp ngủ hoặc đang thức ngầm:
/// - Luôn bật adapter, kể cả khi đang bị ngắt (máy ngủ không được xả pin).
/// - Nếu người dùng chọn giữ mức pin khi ngủ và đang có giới hạn, helper chỉ được "siết lại":
///   có thể tắt sạc, không bật lại sạc. Nhờ vậy vòng lặp định kỳ không thể vô tình bật sạc ngay trước
///   khi ngủ và để pin sạc vượt giới hạn suốt lúc ngủ.
/// - Pin ở mức nguy hiểm (`.critical`) luôn được sạc, bất kể cấu hình.
/// - Đang sạc đầy một lần thì giới hạn hiệu lực là 100%, không giữ mức (xem `holdsLevelDuringSleep`).
/// - Ngoại lệ (v0.16.3): gập máy khi pin còn xa giới hạn thì vẫn được sạc, nếu helper hẹn được giờ đánh thức máy
///   (thức ngầm) trước lúc pin có thể chạm giới hạn (`SleepCharging`).
public enum SleepGate {
    public static func constrain(charging: Bool, adapter: Bool,
                                 currentCharging: Bool?, currentAdapter: Bool?,
                                 phase: WakePhase, reason: ChargeReason,
                                 holdsLevelDuringSleep: Bool,
                                 sleepChargingArmed: Bool = false) -> (charging: Bool, adapter: Bool) {
        guard phase != .awake, reason != .critical else { return (charging, adapter) }
        let charging = holdsLevelDuringSleep
            ? charging && ((currentCharging ?? false) || sleepChargingArmed)
            : charging
        return (charging, true)
    }

    /// Có áp dụng quy tắc "chỉ siết lại" cho việc sạc khi ngủ hay không.
    /// Đang sạc đầy một lần (`topUpActive`) thì giới hạn hiệu lực là 100%, không cần giữ mức.
    public static func holdsLevelDuringSleep(_ config: PowerConfig, topUpActive: Bool = false) -> Bool {
        config.disableChargingBeforeSleep && config.holdsLevel && !topUpActive
    }

    public static func holdsLevelDuringSleep(_ config: PowerConfig, state: ControllerState) -> Bool {
        holdsLevelDuringSleep(config, topUpActive: state.chargesToFull)
    }

    /// Trạng thái khi chuẩn bị ngủ: luôn bật adapter; giữ mức pin nếu người dùng chọn và đang có giới hạn;
    /// không bật sạc nếu đang tắt (ví dụ đang nóng); pin nguy hiểm thì luôn sạc.
    public static func sleepState(config: PowerConfig, currentCharging: Bool?, percent: Int?,
                                  topUpActive: Bool = false) -> (charging: Bool, adapter: Bool) {
        if let percent, percent <= PowerConstants.criticalPercent { return (true, true) }
        return (!holdsLevelDuringSleep(config, topUpActive: topUpActive) && (currentCharging ?? true), true)
    }

    public static func sleepState(config: PowerConfig, currentCharging: Bool?, percent: Int?,
                                  state: ControllerState) -> (charging: Bool, adapter: Bool) {
        sleepState(config: config, currentCharging: currentCharging, percent: percent,
                   topUpActive: state.chargesToFull)
    }
}

/// Sạc khi gập máy (v0.16.3). Trước đây helper tắt sạc suốt lúc ngủ nếu có giới hạn, nên gập máy cắm sạc ở 30% thì
/// pin đứng yên tới khi mở máy. Giờ helper vẫn để pin sạc khi còn xa giới hạn và hẹn đánh thức máy (thức ngầm, màn hình
/// không bật vì nắp đóng) trước lúc pin có thể chạm giới hạn; mỗi lần thức, helper tính lại và hẹn lần kế tiếp, tới khi
/// gần giới hạn thì tắt sạc như cũ.
public enum SleepCharging {
    /// Tốc độ sạc lớn nhất giả định (%/phút). Sạc nhanh thực tế đo được khoảng 1,8%/phút (sạc 140 W, M2 Pro).
    public static let maxPercentPerMinute = 3.0
    /// Còn cách giới hạn ít hơn mức này thì không sạc khi ngủ.
    public static let minimumHeadroom = 3
    /// Đang tạm dừng vì nóng: thức dậy kiểm tra lại sau khoảng này (pin nguội nhanh khi máy ngủ).
    public static let thermalRecheck: TimeInterval = 15 * 60
    public static let minimumWindow: TimeInterval = 60

    public struct Plan: Equatable, Sendable {
        /// Sạc trong lúc ngủ.
        public var charging: Bool
        /// Hẹn thức dậy sau khoảng này để kiểm tra lại (nil = không cần).
        public var checkAfter: TimeInterval?
        /// Chỉ được sạc nếu hẹn được giờ thức dậy.
        public var requiresWake: Bool

        public init(charging: Bool, checkAfter: TimeInterval? = nil, requiresWake: Bool = false) {
            self.charging = charging
            self.checkAfter = checkAfter
            self.requiresWake = requiresWake
        }

        public func charging(wakeArmed: Bool) -> Bool { charging && (!requiresWake || wakeArmed) }
    }

    /// Thời gian pin có thể sạc mà chắc chắn chưa chạm giới hạn (nil = quá gần giới hạn).
    public static func window(percent: Int, limit: Int) -> TimeInterval? {
        let headroom = limit - percent
        guard headroom >= minimumHeadroom else { return nil }
        return max(Double(headroom - 1) / maxPercentPerMinute * 60, minimumWindow)
    }

    /// Kế hoạch sạc cho lúc ngủ, dùng khi máy sắp ngủ và khi thức ngầm.
    /// - chargingAllowed: quyết định của bộ điều khiển (đã tính nhiệt độ, sailing, tạm dừng…).
    /// - holdsLevel: `SleepGate.holdsLevelDuringSleep`.
    /// - lidClosed: chỉ hẹn đánh thức khi nắp đóng, để không làm sáng màn hình lúc máy ngủ với nắp mở.
    public static func plan(chargingAllowed: Bool, reason: ChargeReason, percent: Int?, limit: Int,
                            holdsLevel: Bool, acPresent: Bool, lidClosed: Bool) -> Plan {
        if let percent, percent <= PowerConstants.criticalPercent { return Plan(charging: true) }
        guard holdsLevel else { return Plan(charging: chargingAllowed) }
        guard acPresent, lidClosed, let percent, let window = window(percent: percent, limit: limit) else {
            return Plan(charging: false)
        }
        if chargingAllowed { return Plan(charging: true, checkAfter: window, requiresWake: true) }
        if reason == .thermal { return Plan(charging: false, checkAfter: thermalRecheck) }
        return Plan(charging: false)
    }
}

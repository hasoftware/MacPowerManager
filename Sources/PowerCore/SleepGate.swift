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
public enum SleepGate {
    public static func constrain(charging: Bool, adapter: Bool,
                                 currentCharging: Bool?, currentAdapter: Bool?,
                                 phase: WakePhase, reason: ChargeReason,
                                 holdsLevelDuringSleep: Bool) -> (charging: Bool, adapter: Bool) {
        guard phase != .awake, reason != .critical else { return (charging, adapter) }
        let charging = holdsLevelDuringSleep ? charging && (currentCharging ?? false) : charging
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

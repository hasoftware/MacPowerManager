import Foundation

// HỢP ĐỒNG v0.3.0: các kiểu dùng chung giữa logic thuần (PowerCore/Logic), helper và app.
// Thay đổi ở đây ảnh hưởng tới mọi phần, hãy giữ tương thích khi giải mã (Codable).

public enum ChargeReason: String, Codable, Sendable {
    /// Đang sạc bình thường tới mức giới hạn.
    case normal
    /// Đang giữ ở (hoặc trên) mức giới hạn.
    case limitReached
    /// Dưới giới hạn nhưng trong khoảng sailing (limit - gap ... limit): chờ, chưa sạc lại.
    case sailing
    case manualPause
    case thermal
    case discharging
    /// Sạc đầy một lần: tạm bỏ giới hạn, sạc tới 100%.
    case topUp
    /// Đang xả nhưng nắp máy đóng: tạm ngừng xả (tránh vòng lặp ngủ/thức).
    case clamshellSuspended
    case critical

    public var label: String {
        switch self {
        case .normal: "Sạc bình thường"
        case .limitReached: "Đang giữ ở mức giới hạn"
        case .sailing: "Chờ sạc lại (trong khoảng giữ pin)"
        case .manualPause: "Tạm dừng sạc (dùng adapter)"
        case .thermal: "Tạm dừng do pin nóng"
        case .discharging: "Đang xả pin"
        case .topUp: "Đang sạc đầy một lần"
        case .clamshellSuspended: "Tạm ngừng xả (nắp máy đóng)"
        case .critical: "Pin yếu, cho phép sạc"
        }
    }
}

/// Sạc đầy một lần (Top Up). Kết thúc khi đầy, rút sạc, hết hạn, bị hủy hoặc máy khởi động lại.
public struct TopUpState: Codable, Equatable, Sendable {
    public var startedAt: Date
    public var expiresAt: Date
    /// `kern.bootsessionuuid` lúc bắt đầu: khác thì máy đã khởi động lại.
    public var bootSessionUUID: String

    public init(startedAt: Date, expiresAt: Date, bootSessionUUID: String) {
        self.startedAt = startedAt
        self.expiresAt = expiresAt
        self.bootSessionUUID = bootSessionUUID
    }
}

/// Trạng thái cần nhớ giữa các lần đánh giá. Helper lưu vào `state.json` (qua `RuntimeState`).
public struct ControllerState: Codable, Equatable, Sendable {
    public var thermalPaused = false
    public var holdingAtLimit = false
    /// "Sạc tới giới hạn ngay": bỏ qua khoảng sailing một lần, tự tắt khi đạt giới hạn.
    public var chargeToLimitOnce = false
    public var topUp: TopUpState?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        thermalPaused = (try? c.decodeIfPresent(Bool.self, forKey: .thermalPaused)) ?? nil ?? false
        holdingAtLimit = (try? c.decodeIfPresent(Bool.self, forKey: .holdingAtLimit)) ?? nil ?? false
        chargeToLimitOnce = (try? c.decodeIfPresent(Bool.self, forKey: .chargeToLimitOnce)) ?? nil ?? false
        topUp = (try? c.decodeIfPresent(TopUpState.self, forKey: .topUp)) ?? nil
    }
}

public struct ControllerInput: Equatable, Sendable {
    public var now: Date
    public var percent: Int
    public var temperature: Double?
    /// Adapter đang được cắm (về mặt vật lý). Khi chính helper ngắt adapter để xả, coi như vẫn cắm.
    public var acPresent: Bool
    public var lidClosed: Bool
    /// `kern.bootsessionuuid` hiện tại.
    public var bootSessionUUID: String

    public init(now: Date, percent: Int, temperature: Double?, acPresent: Bool = true,
                lidClosed: Bool = false, bootSessionUUID: String = "") {
        self.now = now
        self.percent = percent
        self.temperature = temperature
        self.acPresent = acPresent
        self.lidClosed = lidClosed
        self.bootSessionUUID = bootSessionUUID
    }
}

public enum TopUpEndReason: String, Codable, Sendable {
    case reachedFull, unplugged, expired, cancelled, newBoot
}

/// Hệ quả của một lần quyết định mà helper cần xử lý (lưu cấu hình, gửi sự kiện…).
public enum ControllerEffect: Codable, Equatable, Sendable {
    /// Đã xả tới mục tiêu: helper tắt `dischargeEnabled`.
    case dischargeFinished
    case topUpEnded(TopUpEndReason)
    /// Đã sạc tới giới hạn sau lệnh "sạc tới giới hạn ngay".
    case chargeToLimitDone
}

public struct ControlDecision: Equatable, Sendable {
    public var chargingEnabled: Bool
    public var adapterEnabled: Bool
    public var reason: ChargeReason
    /// Mức giới hạn đang áp dụng (100 khi tắt giới hạn hoặc đang sạc đầy một lần).
    public var effectiveLimit: Int
    public var effects: [ControllerEffect]

    public init(chargingEnabled: Bool, adapterEnabled: Bool, reason: ChargeReason,
                effectiveLimit: Int = 100, effects: [ControllerEffect] = []) {
        self.chargingEnabled = chargingEnabled
        self.adapterEnabled = adapterEnabled
        self.reason = reason
        self.effectiveLimit = effectiveLimit
        self.effects = effects
    }

    /// Tương thích với code cũ.
    public var dischargeFinished: Bool { effects.contains(.dischargeFinished) }
}

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
    /// Đang hiệu chuẩn pin (xem `CalibrationState`): sạc tới 100%, giữ, xả xuống thấp rồi sạc lại.
    case calibrating

    /// Mô tả cho giao diện. Dịch theo `Bundle.main` của app (helper không có bản dịch nên luôn là tiếng Việt).
    public var label: String {
        switch self {
        case .normal: String(localized: "Sạc bình thường")
        case .limitReached: String(localized: "Đang giữ ở mức giới hạn")
        case .sailing: String(localized: "Chờ sạc lại (trong khoảng giữ pin)")
        case .manualPause: String(localized: "Tạm dừng sạc (dùng adapter)")
        case .thermal: String(localized: "Tạm dừng do pin nóng")
        case .discharging: String(localized: "Đang xả pin")
        case .topUp: String(localized: "Đang sạc đầy một lần")
        case .clamshellSuspended: String(localized: "Tạm ngừng xả (nắp máy đóng)")
        case .critical: String(localized: "Pin yếu, cho phép sạc")
        case .calibrating: String(localized: "Đang hiệu chuẩn pin")
        }
    }
}

/// Sạc đầy một lần (Top Up). Kết thúc khi đầy, rút sạc, hết hạn, bị hủy hoặc máy khởi động lại.
public struct TopUpState: Codable, Equatable, Sendable {
    public var startedAt: Date
    public var expiresAt: Date
    /// `kern.bootsessionuuid` lúc bắt đầu: khác thì máy đã khởi động lại.
    public var bootSessionUUID: String
    /// Giờ hẹn pin đầy nếu phiên này do lịch sạc đầy bắt đầu (nil = người dùng bấm).
    public var scheduledFor: Date?

    public init(startedAt: Date, expiresAt: Date, bootSessionUUID: String, scheduledFor: Date? = nil) {
        self.startedAt = startedAt
        self.expiresAt = expiresAt
        self.bootSessionUUID = bootSessionUUID
        self.scheduledFor = scheduledFor
    }
}

/// Trạng thái cần nhớ giữa các lần đánh giá. Helper lưu vào `state.json` (qua `RuntimeState`).
public struct ControllerState: Codable, Equatable, Sendable {
    public var thermalPaused = false
    public var holdingAtLimit = false
    /// "Sạc tới giới hạn ngay": bỏ qua khoảng sailing một lần, tự tắt khi đạt giới hạn.
    public var chargeToLimitOnce = false
    public var topUp: TopUpState?
    /// Thời điểm bắt đầu ngắt adapter của lần xả hiện tại (hạn thuê I2). Nil khi không xả.
    public var dischargeStartedAt: Date?
    /// Giờ hẹn của lần sạc đầy theo lịch đã xử lý (đã bắt đầu, hoặc người dùng đã hủy): không bắt đầu lại lần nữa.
    public var scheduledChargeHandled: Date?
    /// Đang hiệu chuẩn pin (v0.9.0).
    public var calibration: CalibrationState?
    /// Lần hiệu chuẩn hoàn tất gần nhất.
    public var lastCalibrationAt: Date?

    /// Đang cần sạc tới 100% (sạc đầy một lần hoặc bước sạc của hiệu chuẩn): không giữ mức khi máy ngủ.
    public var chargesToFull: Bool { topUp != nil || calibration?.phase.chargesToFull == true }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        thermalPaused = (try? c.decodeIfPresent(Bool.self, forKey: .thermalPaused)) ?? nil ?? false
        holdingAtLimit = (try? c.decodeIfPresent(Bool.self, forKey: .holdingAtLimit)) ?? nil ?? false
        chargeToLimitOnce = (try? c.decodeIfPresent(Bool.self, forKey: .chargeToLimitOnce)) ?? nil ?? false
        topUp = (try? c.decodeIfPresent(TopUpState.self, forKey: .topUp)) ?? nil
        dischargeStartedAt = (try? c.decodeIfPresent(Date.self, forKey: .dischargeStartedAt)) ?? nil
        scheduledChargeHandled = (try? c.decodeIfPresent(Date.self, forKey: .scheduledChargeHandled)) ?? nil
        calibration = (try? c.decodeIfPresent(CalibrationState.self, forKey: .calibration)) ?? nil
        lastCalibrationAt = (try? c.decodeIfPresent(Date.self, forKey: .lastCalibrationAt)) ?? nil
    }
}

public struct ControllerInput: Equatable, Sendable {
    public var now: Date
    public var percent: Int
    public var temperature: Double?
    /// Adapter đang được cắm (về mặt vật lý), xem `ACPresence.resolve`. Khi adapter đang bị ngắt, IOKit không
    /// phân biệt được rút sạc với bị ngắt nên helper giữ giá trị biết được lần cuối (hạn thuê xả giới hạn việc này).
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

/// Lý do helper tự hủy xả pin (bật lại adapter và tắt `dischargeEnabled`).
public enum DischargeAbortReason: String, Codable, Sendable {
    /// Đã ngắt adapter quá `PowerConstants.dischargeMaxMinutes`.
    case leaseExpired
    /// Đã ngắt adapter nhưng pin không xả (dòng không âm) sau `PowerConstants.adapterCutVerifySeconds`.
    case adapterCutIneffective
}

/// Hệ quả của một lần quyết định mà helper cần xử lý (lưu cấu hình, gửi sự kiện…).
public enum ControllerEffect: Codable, Equatable, Sendable {
    /// Đã xả tới mục tiêu: helper tắt `dischargeEnabled`.
    case dischargeFinished
    /// Hủy xả trước khi tới mục tiêu: adapter đã bật lại, helper tắt `dischargeEnabled`.
    case dischargeAborted(DischargeAbortReason)
    case topUpEnded(TopUpEndReason)
    /// Đã sạc tới giới hạn sau lệnh "sạc tới giới hạn ngay".
    case chargeToLimitDone
    /// Hiệu chuẩn chuyển sang bước mới.
    case calibrationPhase(CalibrationPhase)
    case calibrationEnded(CalibrationEndReason)
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

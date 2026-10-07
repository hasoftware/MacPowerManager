import Foundation

/// Giới hạn sạc trên MacBook Intel (2018–2020, chip T2) bằng key `BCLM` (Battery Charge Level Max).
///
/// Khác Apple Silicon: firmware tự giữ giới hạn, kể cả khi máy ngủ hoặc tắt, nên helper chỉ cần
/// ghi mức mong muốn. `BCLM` không xả pin; nó chỉ ngừng sạc khi pin đạt mức đó (thường vượt ~3%
/// vì firmware dùng phần trăm phần cứng). Hỗ trợ ở mức thử nghiệm: chưa được kiểm chứng trên máy thật.
public final class IntelChargeLimiter {
    /// Không ghi thấp hơn mức này: hành vi dưới 50% chưa rõ, và `BCLM` được lưu lại sau khi tắt máy,
    /// nên một giá trị quá thấp có thể khiến máy không sạc được nếu helper gặp sự cố.
    public static let minimumLimit = 50
    public static let defaultLimit = 100

    private let smc: SMCAccess

    /// Trả về nil nếu không phải máy Intel hoặc `BCLM` không đúng dạng (ui8, 1 byte, ghi được).
    public init?(smc: SMCAccess, isAppleSilicon: Bool = Platform.isAppleSilicon) {
        guard !isAppleSilicon,
              let reading = smc.read("BCLM"),
              reading.type == "ui8 ", reading.bytes.count == 1, reading.isWritable else { return nil }
        self.smc = smc
    }

    public var currentLimit: Int? {
        smc.read("BCLM")?.bytes.first.map(Int.init)
    }

    /// Ghi `BCLM` rồi đọc lại để xác minh.
    public func setLimit(_ value: Int) throws {
        let clamped = UInt8(IntelPolicy.clamp(value))
        try smc.write("BCLM", [clamped])
        guard currentLimit == Int(clamped) else {
            throw SMCError(key: "BCLM", code: kIOReturnError)
        }
    }

    /// Phần trăm pin theo phần cứng (`BRSC`). Một số máy lưu giá trị ×256.
    public var hardwarePercent: Int? {
        guard let value = smc.read("BRSC")?.doubleValue else { return nil }
        return IntelPolicy.normalizeHardwarePercent(Int(value))
    }

    public var batteryTemperature: Double? { SMCSensors.batteryTemperature(smc) }

    /// Trả `BCLM` về 100%. Chỉ dùng khi gỡ cài đặt hoặc người dùng tắt giới hạn,
    /// không dùng khi tắt máy (firmware cần giữ giới hạn lúc máy tắt).
    @discardableResult
    public func restoreDefaults() -> Bool {
        (try? setLimit(Self.defaultLimit)) != nil
    }
}

/// Logic thuần cho backend Intel, tách riêng để kiểm thử.
public enum IntelPolicy {
    public static func clamp(_ value: Int) -> Int {
        min(max(value, IntelChargeLimiter.minimumLimit), 100)
    }

    /// Mức `BCLM` cần ghi theo quyết định của `ChargeController`.
    /// - Giới hạn / sạc bình thường: mức giới hạn (hoặc 100 nếu tắt giới hạn).
    /// - Tạm dừng thủ công / pin nóng: mức pin phần cứng hiện tại để firmware ngừng sạc ngay,
    ///   nhưng không thấp hơn 50 và không cao hơn mức giới hạn.
    /// - Pin nguy hiểm: luôn ≥ 50 nên firmware vẫn sạc.
    public static func firmwareLimit(config: PowerConfig, reason: ChargeReason,
                                     hardwarePercent: Int?, percent: Int) -> Int {
        let limit = config.chargeLimitEnabled ? clamp(config.chargeLimit) : IntelChargeLimiter.defaultLimit
        switch reason {
        case .manualPause, .thermal:
            return min(clamp(hardwarePercent ?? percent), limit)
        case .normal, .limitReached, .discharging, .critical:
            return limit
        }
    }

    public static func normalizeHardwarePercent(_ raw: Int) -> Int? {
        let value = raw > 100 ? raw >> 8 : raw
        return (0...100).contains(value) ? value : nil
    }
}

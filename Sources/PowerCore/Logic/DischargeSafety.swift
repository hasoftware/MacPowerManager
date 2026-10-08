import Foundation

/// Cắm sạc về mặt vật lý (`ControllerInput.acPresent`).
///
/// Khi adapter bị ngắt, IOKit `ExternalConnected` báo false dù cáp vẫn cắm, nên không phân biệt được rút sạc
/// với bị ngắt. Khi đó giữ giá trị biết được lần cuối lúc adapter còn bật; hạn thuê xả
/// (`PowerConstants.dischargeMaxMinutes`) giới hạn thời gian dựa vào giá trị cũ này.
public enum ACPresence {
    /// - externalConnected: IOKit `ExternalConnected`.
    /// - adapterEnabled: đọc lại từ SMC (nil nếu máy không có key adapter hoặc không đọc được).
    /// - lastKnown: giá trị vật lý biết được lần cuối khi adapter còn bật (nil nếu chưa có).
    /// Trả về giá trị dùng cho vòng điều khiển và giá trị `lastKnown` mới để helper lưu lại.
    public static func resolve(externalConnected: Bool, adapterEnabled: Bool?,
                               lastKnown: Bool?) -> (acPresent: Bool, lastKnown: Bool?) {
        guard adapterEnabled == false else { return (externalConnected, externalConnected) }
        // Adapter đang bị ngắt: IOKit luôn báo không cắm. Chưa biết gì thì coi như rút sạc,
        // để vòng điều khiển bật lại adapter và đọc lại trạng thái thật ở lần sau.
        return (lastKnown ?? false, lastKnown)
    }
}

/// Xác minh việc ngắt adapter có hiệu lực: sau khi ngắt, pin phải xả (dòng âm).
public enum AdapterCutCheck: Equatable, Sendable {
    /// Adapter không bị helper ngắt.
    case notApplicable
    case pending(since: Date)
    case verified
    /// Đã ngắt quá `PowerConstants.adapterCutVerifySeconds` mà pin không xả: phải hủy xả.
    case ineffective(detail: String)

    /// Việc ngắt adapter đang (hoặc có thể đang) có hiệu lực.
    public var isInEffect: Bool {
        switch self {
        case .pending, .verified: true
        case .notApplicable, .ineffective: false
        }
    }
}

public enum AdapterCutVerifier {
    /// - cutSince: thời điểm helper ngắt adapter (đọc lại thấy đã ngắt), nil nếu adapter đang bật.
    /// - batteryCurrentmA: dòng vào pin (dương = đang sạc), từ SMC `B0AC` hoặc IOKit `Amperage`.
    /// - previous: kết quả lần trước; đã xác minh thì giữ nguyên cho tới khi adapter bật lại.
    ///
    /// Dòng âm là đã hiệu lực. Không đọc được dòng thì không xác minh được, nên cũng hủy khi quá hạn.
    public static func evaluate(cutSince: Date?, now: Date, batteryCurrentmA: Int?,
                                previous: AdapterCutCheck) -> AdapterCutCheck {
        guard let since = cutSince else { return .notApplicable }
        if previous == .verified { return .verified }
        if let current = batteryCurrentmA, current < 0 { return .verified }
        let elapsed = now.timeIntervalSince(since)
        if elapsed.isFinite, elapsed >= 0, elapsed < PowerConstants.adapterCutVerifySeconds {
            return .pending(since: since)
        }
        let seconds = elapsed.isFinite ? String(format: "%.0f", elapsed) : "?"
        let reading = batteryCurrentmA.map { "pin vẫn nhận \($0) mA" } ?? "không đọc được dòng pin"
        return .ineffective(detail: "Đã ngắt adapter \(seconds) giây nhưng \(reading).")
    }

    /// Chỉ giữ assertion chặn ngủ khi adapter thực sự đang bị ngắt: đọc lại SMC thấy đã ngắt
    /// và việc ngắt chưa bị kết luận là không hiệu lực.
    public static func holdsSleepAssertion(adapterEnabled: Bool?, check: AdapterCutCheck) -> Bool {
        adapterEnabled == false && check.isInEffect
    }
}

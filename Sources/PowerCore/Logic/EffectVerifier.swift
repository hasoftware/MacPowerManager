import Foundation

/// Xác minh lệnh chặn sạc có hiệu lực: sau khi chặn sạc một khoảng thời gian, dòng sạc vào pin phải ≈ 0.
/// STUB của giai đoạn 0: gói việc "logic" sẽ hoàn thiện và viết test.
public enum EffectVerifier {
    /// - inhibitedSince: thời điểm helper bắt đầu chặn sạc (nil nếu đang cho sạc).
    /// - batteryCurrentmA: dòng vào pin (dương = đang sạc), từ SMC `B0AC` hoặc IOKit.
    public static func evaluate(inhibitedSince: Date?, now: Date, batteryCurrentmA: Int?,
                                acPresent: Bool, percent: Int) -> EffectState {
        .notApplicable
    }
}

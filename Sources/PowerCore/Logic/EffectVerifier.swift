import Foundation

/// Xác minh lệnh chặn sạc có hiệu lực: sau khi chặn sạc một khoảng thời gian, dòng sạc vào pin phải ≈ 0.
public enum EffectVerifier {
    /// - inhibitedSince: thời điểm helper bắt đầu chặn sạc (nil nếu đang cho sạc).
    /// - batteryCurrentmA: dòng vào pin (dương = đang sạc), từ SMC `B0AC` hoặc IOKit.
    ///
    /// Không cần xác minh khi không chặn sạc, không cắm sạc, pin gần đầy (≥ 99%, pin tự ngừng nhận dòng)
    /// hoặc không đọc được dòng. Dòng ≤ `effectCurrentThresholdmA` là đã hiệu lực; nếu chưa thì chờ
    /// `effectVerifySeconds` rồi mới kết luận không hiệu lực.
    public static func evaluate(inhibitedSince: Date?, now: Date, batteryCurrentmA: Int?,
                                acPresent: Bool, percent: Int) -> EffectState {
        guard let since = inhibitedSince, acPresent, percent < 99,
              let current = batteryCurrentmA else { return .notApplicable }
        if current <= PowerConstants.effectCurrentThresholdmA { return .verified }
        let elapsed = now.timeIntervalSince(since)
        if elapsed < PowerConstants.effectVerifySeconds { return .pending(since: since) }
        let seconds = String(format: "%.0f", elapsed)
        return .ineffective(detail: "Đã chặn sạc \(seconds) giây nhưng pin vẫn nhận \(current) mA "
                            + "(ngưỡng \(PowerConstants.effectCurrentThresholdmA) mA).")
    }
}

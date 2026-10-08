import Foundation

/// Quy tắc thuần cho việc kiểm tra và nhắc cập nhật (tách khỏi mạng và UserDefaults để kiểm thử).
public enum UpdatePolicy {
    /// Khoảng cách giữa hai lần tự kiểm tra khi app đang chạy.
    public static let checkInterval: TimeInterval = 24 * 3600
    /// Thử lại sau khi lần tự kiểm tra thất bại (mất mạng, GitHub giới hạn).
    public static let retryInterval: TimeInterval = 3600
    /// "Để sau": ẩn banner của bản này trong 24 giờ.
    public static let remindLaterInterval: TimeInterval = 24 * 3600

    /// Bản mới có cần được nhắc (banner, thông báo) hay không: mới hơn bản đang chạy, người dùng chưa bỏ qua
    /// chính bản này và chưa chọn "Để sau" cho nó trong vòng `remindLaterInterval`.
    public static func shouldAnnounce(_ release: ReleaseInfo, current: String, skippedVersion: String?,
                                      snoozedVersion: String?, snoozedUntil: Date?, now: Date) -> Bool {
        guard release.isNewer(than: current), let version = release.version else { return false }
        if let skipped = skippedVersion.flatMap(SemanticVersion.init), skipped == version { return false }
        if let snoozed = snoozedVersion.flatMap(SemanticVersion.init), snoozed == version,
           let until = snoozedUntil, now < until {
            return false
        }
        return true
    }

    /// Đã tới lúc tự kiểm tra lại chưa.
    public static func isDue(lastAttempt: Date?, lastFailed: Bool, now: Date) -> Bool {
        guard let lastAttempt else { return true }
        let interval = lastFailed ? retryInterval : checkInterval
        return now.timeIntervalSince(lastAttempt) >= interval || now < lastAttempt
    }
}

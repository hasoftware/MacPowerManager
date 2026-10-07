import Foundation

public enum PowerConstants {
    public static let appBundleID = "com.hasoftware.MacPowerManager"
    public static let helperLabel = "com.hasoftware.MacPowerManager.helper"
    public static let helperMachService = helperLabel

    public static let helperInstallPath = "/Library/PrivilegedHelperTools/\(helperLabel)"
    public static let launchDaemonPath = "/Library/LaunchDaemons/\(helperLabel).plist"
    public static let helperConfigURL = URL(fileURLWithPath: "/Library/Application Support/MacPowerManager/config.json")

    public static let helperStateURL = URL(fileURLWithPath: "/Library/Application Support/MacPowerManager/state.json")
    /// Danh sách cdhash của app được phép điều khiển helper, do script cài đặt (root) ghi.
    public static let trustedClientsURL = URL(fileURLWithPath: "/Library/Application Support/MacPowerManager/trusted-clients.json")

    /// Dưới mức này luôn bật adapter + cho phép sạc, bất kể cấu hình.
    public static let criticalPercent = 10
    /// Dưới mức này khoảng sailing không bao giờ chặn sạc.
    public static let sailingFloorPercent = 20
    /// Dưới mức này bảo vệ nhiệt không bao giờ chặn sạc.
    public static let thermalFloorPercent = 20
    /// Thời gian chờ trước khi kết luận lệnh chặn sạc không hiệu lực.
    public static let effectVerifySeconds: TimeInterval = 90
    /// Dòng sạc vào pin (mA) tối đa vẫn coi là "đã ngừng sạc".
    public static let effectCurrentThresholdmA = 50
    public static let topUpDefaultHours = 24
}

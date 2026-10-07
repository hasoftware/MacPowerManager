import Foundation

public enum PowerConstants {
    public static let appBundleID = "com.hasoftware.MacPowerManager"
    public static let helperLabel = "com.hasoftware.MacPowerManager.helper"
    public static let helperMachService = helperLabel
    /// Tăng mỗi khi helper thay đổi để app biết cần cài lại.
    public static let helperVersion = "1.0.0"

    public static let helperInstallPath = "/Library/PrivilegedHelperTools/\(helperLabel)"
    public static let launchDaemonPath = "/Library/LaunchDaemons/\(helperLabel).plist"
    public static let helperConfigURL = URL(fileURLWithPath: "/Library/Application Support/MacPowerManager/config.json")

    /// Dưới mức này luôn bật adapter + cho phép sạc, bất kể cấu hình.
    public static let criticalPercent = 10
}

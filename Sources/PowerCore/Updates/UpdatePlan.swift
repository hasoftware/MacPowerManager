import Foundation

/// Các bước kiểm tra trước khi thay app bằng bản cập nhật đã tải (thuần, để kiểm thử).
public enum UpdatePlan {
    public enum Failure: Error, Equatable {
        case badSignature
        case wrongBundle(String?)
        case notNewer(String?)
        case unsupportedLocation
    }

    /// Bản giải nén phải đúng app (bundle id) và mới hơn bản đang chạy.
    public static func validate(bundleIdentifier: String?, version: String?, expectedIdentifier: String,
                                currentVersion: String) -> Failure? {
        guard bundleIdentifier == expectedIdentifier else { return .wrongBundle(bundleIdentifier) }
        guard let version, let new = SemanticVersion(version) else { return .notNewer(version) }
        if let current = SemanticVersion(currentVersion), new <= current { return .notNewer(version) }
        return nil
    }

    /// Nơi cài bản mới: thay đúng chỗ app đang chạy nếu đó là một thư mục thật (không phải bản bị macOS
    /// "translocate" hay ổ đĩa .dmg chỉ đọc); ngược lại cài vào /Applications.
    public static func installLocation(runningBundlePath: String, isOnReadOnlyVolume: Bool) -> String {
        if InstallLocation.isTemporary(bundlePath: runningBundlePath, isOnReadOnlyVolume: isOnReadOnlyVolume) {
            return "/Applications/MacPowerManager.app"
        }
        return runningBundlePath
    }

    /// Script chạy sau khi app thoát: chờ tiến trình cũ kết thúc, thay app, gỡ cờ quarantine, mở bản mới.
    /// Bản cũ được giữ tạm để khôi phục nếu thay thất bại.
    public static func relaunchScript(pid: Int32, newApp: String, destination: String) -> String {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return """
        #!/bin/sh
        i=0
        while kill -0 \(pid) 2>/dev/null && [ $i -lt 100 ]; do sleep 0.2; i=$((i + 1)); done
        backup=\(q(destination)).old-$$
        if [ -e \(q(destination)) ]; then mv \(q(destination)) "$backup" || exit 1; fi
        if mv \(q(newApp)) \(q(destination)); then
            rm -rf "$backup"
        else
            [ -e "$backup" ] && mv "$backup" \(q(destination))
        fi
        xattr -dr com.apple.quarantine \(q(destination)) 2>/dev/null
        open \(q(destination))
        """
    }
}

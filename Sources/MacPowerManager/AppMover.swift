import AppKit
import PowerCore

/// Khi app chạy từ vị trí tạm (ổ đĩa .dmg hoặc bản bị macOS "translocate"), đề nghị chuyển vào /Applications.
/// Chạy từ vị trí tạm khiến "Mở cùng macOS" trỏ tới đường dẫn tạm và app có thể bị đóng khi eject ổ đĩa.
@MainActor
enum AppMover {
    static let destination = URL(fileURLWithPath: "/Applications/MacPowerManager.app")
    private static let suppressKey = "moveToApplications.suppressed"
    private static var isMoving = false

    static var needsMove: Bool {
        guard !UserDefaults.standard.bool(forKey: suppressKey) else { return false }
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app" else { return false }
        let readOnly = (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        return InstallLocation.isTemporary(bundlePath: url.path, isOnReadOnlyVolume: readOnly)
    }

    private static var canWriteApplications: Bool {
        FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path)
    }

    static func promptIfNeeded() {
        guard needsMove else { return }
        let alert = NSAlert()
        alert.messageText = "Chuyển MacPowerManager vào thư mục Applications?"
        alert.informativeText = "App đang chạy trực tiếp từ file tải về hoặc ổ đĩa .dmg. "
            + "Hãy chuyển vào Applications để app hoạt động ổn định (mở cùng macOS, không bị đóng khi eject ổ đĩa)."
        if canWriteApplications {
            alert.addButton(withTitle: "Chuyển vào Applications")
        } else {
            alert.informativeText += "\n\nTài khoản này không ghi được vào Applications: hãy nhờ tài khoản quản trị kéo app vào Applications trong Finder."
        }
        alert.addButton(withTitle: "Để sau")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Không hỏi lại"
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: suppressKey)
        }
        if canWriteApplications && response == .alertFirstButtonReturn {
            moveAndRelaunch()
        }
    }

    /// Đưa app vào /Applications (thay bản cũ hơn nếu có), mở bản đó rồi thoát bản đang chạy.
    static func moveAndRelaunch() {
        guard !isMoving else { return }
        isMoving = true
        do {
            try installToApplications()
        } catch {
            isMoving = false
            showManualInstructions(error)
            return
        }
        relaunch()
    }

    private static func installToApplications() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            let existing = Bundle(url: destination)
            // Không đụng vào một app khác trùng tên.
            guard existing?.bundleIdentifier == Bundle.main.bundleIdentifier else {
                throw CocoaError(.fileWriteFileExists)
            }
            let version = existing?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            if InstallLocation.version(version, isAtLeast: AppVersion.current) {
                // Giữ bản mới hơn hoặc bằng đã có. Bỏ quarantine để nó không bị translocate nữa.
                removeQuarantine(destination)
                return
            }
        }
        // Copy vào một thư mục tạm cạnh đích rồi mới thay bản cũ: nếu copy lỗi, bản cũ vẫn còn nguyên.
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".MacPowerManager-\(UUID().uuidString).app")
        do {
            try fm.copyItem(at: Bundle.main.bundleURL, to: staging)
        } catch {
            try? fm.removeItem(at: staging)  // không để lại bản copy dở dang
            throw error
        }
        // Bản copy bằng code giữ cờ quarantine nhưng thiếu cờ "đã được Finder di chuyển", nên macOS sẽ
        // translocate nó lần nữa và app lại hỏi chuyển. Người dùng đã cho phép chạy chính bản này.
        removeQuarantine(staging)
        do {
            if fm.fileExists(atPath: destination.path) {
                try terminateRunningInstances(at: destination)
                try fm.trashItem(at: destination, resultingItemURL: nil)
            }
            try fm.moveItem(at: staging, to: destination)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    private static func removeQuarantine(_ url: URL) {
        var paths = [url.path]
        if let enumerator = FileManager.default.enumerator(atPath: url.path) {
            while let relative = enumerator.nextObject() as? String {
                paths.append(url.appendingPathComponent(relative).path)
            }
        }
        for path in paths {
            removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
    }

    private static func runningInstances(at url: URL) -> [NSRunningApplication] {
        let own = getpid()
        return NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != own && $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }
    }

    /// Thoát bản cũ đang chạy trước khi thay nó.
    private static func terminateRunningInstances(at url: URL) throws {
        let apps = runningInstances(at: url)
        apps.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(5)
        while apps.contains(where: { !$0.isTerminated }) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        if apps.contains(where: { !$0.isTerminated }) {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    private static func relaunch() {
        // Bản trong Applications đang chạy sẵn: chỉ cần chuyển sang nó, không mở thêm bản mới.
        if let running = runningInstances(at: destination).first {
            running.activate()
            NSApp.terminate(nil)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    isMoving = false
                    showManualInstructions(error)
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private static func showManualInstructions(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Không thể tự chuyển app"
        alert.informativeText = "Hãy thoát MacPowerManager, kéo app vào thư mục Applications trong Finder, eject ổ đĩa .dmg rồi mở lại app từ Applications.\n\n(\(error.localizedDescription))"
        alert.runModal()
    }
}

import AppKit
import Foundation

/// Cài lệnh `mpm` vào `/usr/local/bin` (liên kết tới script trong app bundle, nên tự theo bản app mới sau khi cập nhật).
enum CommandLineInstaller {
    static let linkPath = "/usr/local/bin/mpm"

    /// Script `mpm` trong app bundle.
    static var scriptPath: String? { Bundle.main.path(forResource: "mpm", ofType: nil) }

    enum State: Equatable {
        case notInstalled, installed, other(String)
    }

    static var state: State {
        let fm = FileManager.default
        guard fm.fileExists(atPath: linkPath) || (try? fm.destinationOfSymbolicLink(atPath: linkPath)) != nil else {
            return .notInstalled
        }
        guard let target = try? fm.destinationOfSymbolicLink(atPath: linkPath) else { return .other(linkPath) }
        return target == scriptPath ? .installed : .other(target)
    }

    /// Hỏi mật khẩu quản trị một lần để tạo liên kết. Trả về thông báo lỗi, nil nếu thành công hoặc người dùng hủy.
    static func install() async -> String? {
        guard let script = scriptPath else { return String(localized: "Không tìm thấy lệnh mpm trong app bundle.") }
        return await runAsAdmin("/bin/mkdir -p /usr/local/bin && /bin/ln -sf \(quote(script)) \(quote(linkPath))")
    }

    static func uninstall() async -> String? {
        await runAsAdmin("/bin/rm -f \(quote(linkPath))")
    }

    private static func runAsAdmin(_ command: String) async -> String? {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        return await Task.detached { () -> String? in
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            // -128: người dùng bấm Hủy.
            guard let error, (error[NSAppleScript.errorNumber] as? Int) != -128 else { return nil }
            return error[NSAppleScript.errorMessage] as? String ?? String(localized: "Không cài được lệnh mpm.")
        }.value
    }

    private static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

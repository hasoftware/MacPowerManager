import AppKit
import Darwin
import Foundation

/// Một ứng dụng điều khiển sạc khác được tìm thấy trên máy.
struct ConflictFinding: Identifiable, Equatable, Sendable {
    enum Product: String, CaseIterable, Sendable {
        case aldente, batt, batteryToolkit, battery

        var name: String {
            switch self {
            case .aldente: "AlDente"
            case .batt: "batt"
            case .batteryToolkit: "Battery Toolkit"
            case .battery: "battery (actuallymentor)"
            }
        }
    }

    var product: Product
    /// Đường dẫn cài đặt tìm thấy (app, helper, LaunchDaemon…).
    var installedPaths: [String]
    /// Đang chạy: app đang mở hoặc helper/daemon của nó đang chạy.
    var running: Bool
    /// Tiến trình đang chạy tìm thấy (để hiển thị).
    var processes: [String] = []
    /// Giới hạn sạc đọc được từ cài đặt của ứng dụng đó (nếu có).
    var chargeLimit: Int?

    var id: Product { product }
    var name: String { product.name }
    var installed: Bool { !installedPaths.isEmpty || running }
}

/// Tìm các ứng dụng điều khiển sạc khác. Chỉ đọc (đường dẫn, tiến trình, cài đặt), không cần quyền root.
/// Chỉ khi ứng dụng kia đang chạy mới coi là xung đột; cài sẵn nhưng không chạy thì không cảnh báo.
enum ConflictScanner {
    private struct Signature {
        var product: ConflictFinding.Product
        /// Dấu hiệu đã cài; `~` là thư mục người dùng.
        var paths: [String]
        /// Tiền tố bundle identifier của app (so khớp không phân biệt hoa thường).
        var bundlePrefixes: [String]
        /// Tiền tố đường dẫn file thực thi của tiến trình.
        var processPrefixes: [String]
        /// Tên file thực thi (khớp chính xác).
        var processNames: [String]
    }

    private static let signatures: [Signature] = [
        Signature(
            product: .aldente,
            paths: ["/Applications/AlDente.app",
                    "/Library/PrivilegedHelperTools/com.apphousekitchen.aldente-pro.helper",
                    "/Library/LaunchDaemons/com.apphousekitchen.aldente-pro.helper.plist",
                    "/Library/PrivilegedHelperTools/com.apphousekitchen.aldente.helper",
                    "/Library/LaunchDaemons/com.apphousekitchen.aldente.helper.plist",
                    "/Library/PrivilegedHelperTools/com.davidwernhart.Helper",
                    "/Library/LaunchDaemons/com.davidwernhart.Helper.plist"],
            bundlePrefixes: ["com.apphousekitchen.aldente", "com.davidwernhart.aldente"],
            processPrefixes: ["/Library/PrivilegedHelperTools/com.apphousekitchen.aldente",
                              "/Library/PrivilegedHelperTools/com.davidwernhart.Helper"],
            processNames: []),
        Signature(
            product: .batt,
            paths: ["/Library/LaunchDaemons/cc.chlc.batt.plist",
                    "/Library/LaunchDaemons/homebrew.mxcl.batt.plist",
                    "/usr/local/bin/batt", "/opt/homebrew/bin/batt",
                    "/Applications/batt.app"],
            bundlePrefixes: ["cc.chlc.batt"],
            processPrefixes: [],
            processNames: ["batt"]),
        Signature(
            product: .batteryToolkit,
            paths: ["/Applications/Battery Toolkit.app",
                    "/Library/PrivilegedHelperTools/me.mhaeuser.batterytoolkitd",
                    "/Library/LaunchDaemons/me.mhaeuser.batterytoolkitd.plist"],
            bundlePrefixes: ["me.mhaeuser.batterytoolkit"],
            processPrefixes: [],
            processNames: ["me.mhaeuser.batterytoolkitd"]),
        Signature(
            product: .battery,
            paths: ["/usr/local/co.palokaj.battery", "/usr/local/bin/battery",
                    "/Applications/battery.app", "~/Library/LaunchAgents/battery.plist"],
            bundlePrefixes: ["co.palokaj.battery", "com.battery.app"],
            processPrefixes: ["/usr/local/co.palokaj.battery"],
            processNames: []),
    ]

    static func scan() -> [ConflictFinding] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> (String, String)? in
            guard let id = app.bundleIdentifier?.lowercased() else { return nil }
            return (id, app.localizedName ?? id)
        }
        let processes = processPaths()

        var findings: [ConflictFinding] = []
        for sig in signatures {
            let installed = sig.paths
                .map { $0.hasPrefix("~") ? home + $0.dropFirst() : $0 }
                .filter { fm.fileExists(atPath: $0) }
            var running: [String] = apps
                .filter { id, _ in sig.bundlePrefixes.contains { id.hasPrefix($0.lowercased()) } }
                .map(\.1)
            running += processes.filter { path in
                sig.processPrefixes.contains { path.hasPrefix($0) }
                    || sig.processNames.contains((path as NSString).lastPathComponent)
            }
            if sig.product == .battery, let pid = batteryScriptPID() {
                running.append("battery (pid \(pid))")
            }
            guard !installed.isEmpty || !running.isEmpty else { continue }
            var finding = ConflictFinding(product: sig.product, installedPaths: installed,
                                          running: !running.isEmpty, processes: Array(Set(running)).sorted())
            if sig.product == .aldente { finding.chargeLimit = aldenteLimit() }
            findings.append(finding)
        }
        return findings
    }

    /// Đường dẫn file thực thi của mọi tiến trình (đọc được cả tiến trình root mà không cần quyền).
    private static func processPaths() -> [String] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: 4096)
        return pids.prefix(Int(count)).compactMap { pid in
            guard pid > 0, proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
            return String(cString: buffer)
        }
    }

    /// actuallymentor/battery chạy bằng shell script, ghi pid vào ~/.battery/battery.pid.
    private static func batteryScriptPID() -> pid_t? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".battery/battery.pid")
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0,
              kill(pid, 0) == 0 || errno == EPERM else { return nil }
        return pid
    }

    /// Giới hạn sạc trong cài đặt của AlDente (khóa `chargeVal`).
    private static func aldenteLimit() -> Int? {
        for domain in ["com.apphousekitchen.aldente-pro", "com.apphousekitchen.aldente"] {
            if let value = CFPreferencesCopyAppValue("chargeVal" as CFString, domain as CFString) as? NSNumber {
                return value.intValue
            }
        }
        return nil
    }
}

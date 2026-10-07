import Foundation
import IOKit

/// Thông tin máy dùng cho chẩn đoán (smc-probe, báo lỗi) và cho helper.
public enum SystemInfo {
    public static var model: String { sysctlString("hw.model") ?? "?" }

    public static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// Ví dụ "iBoot-11881.121.1" trên Apple Silicon. Một số firmware mới khóa các SMC key điều khiển sạc.
    public static var firmwareVersion: String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/chosen")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        for key in ["system-firmware-version", "firmware-version"] {
            guard let data = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Data else { continue }
            let text = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
            if !text.isEmpty { return text }
        }
        return nil
    }

    /// `kern.bootsessionuuid`: đổi sau mỗi lần khởi động (rỗng nếu không đọc được).
    public static var bootSessionUUID: String { sysctlString("kern.bootsessionuuid") ?? "" }

    /// Nắp máy đang đóng (`AppleClamshellState` của IOPMrootDomain). Nil nếu máy không có nắp hoặc không đọc được.
    public static var lidClosed: Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        return (IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber)?.boolValue
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

// MARK: - Phiên khởi động

/// SMC được reset khi tắt máy, nên sau khi khởi động lại các giá trị helper đã ghi
/// và các chế độ một lần (sạc đầy, sạc tới giới hạn) không còn ý nghĩa.
public enum BootSession {
    /// Trả về trạng thái đã điều chỉnh theo phiên khởi động hiện tại và cho biết đây có phải phiên mới không.
    /// Phiên mới: bỏ sạc đầy một lần, trạng thái giữ ở giới hạn, "sạc tới giới hạn ngay" và `lastWritten`.
    public static func reconcile(_ state: RuntimeState, currentUUID: String) -> (state: RuntimeState, isNewBoot: Bool) {
        guard state.bootSessionUUID != currentUUID else { return (state, false) }
        var s = state
        s.controller.topUp = nil
        s.controller.holdingAtLimit = false
        s.controller.chargeToLimitOnce = false
        s.lastWritten = [:]
        s.bootSessionUUID = currentUUID
        return (s, true)
    }
}

// MARK: - Client được tin cậy (XPC)

/// Danh sách cdhash của app được phép điều khiển helper (`trusted-clients.json`, do script cài đặt ghi bằng root).
public enum TrustedClients {
    public struct File: Codable, Equatable, Sendable {
        public var cdhashes: [String]

        public init(cdhashes: [String]) {
            self.cdhashes = cdhashes
        }
    }

    /// cdhash hợp lệ: đúng 40 ký tự hex (SHA-256 rút gọn còn 20 byte). Trả về dạng chữ thường.
    public static func normalizedHash(_ text: String) -> String? {
        let hash = text.lowercased()
        guard hash.count == 40, hash.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else {
            return nil
        }
        return hash
    }

    /// Đọc danh sách cdhash từ nội dung file; bỏ giá trị không hợp lệ và trùng lặp.
    public static func hashes(from data: Data?) -> [String] {
        guard let data, let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return valid(file.cdhashes)
    }

    /// Code signing requirement cho kết nối XPC. Có cdhash hợp lệ thì ghim theo cdhash,
    /// không thì chỉ kiểm tra bundle identifier (như v0.2.0).
    /// Chỉ các giá trị đã kiểm tra là hex mới được ghép vào chuỗi, nên file hỏng không chèn thêm được điều kiện.
    public static func requirement(identifier: String = PowerConstants.appBundleID, cdhashes: [String]) -> String {
        let base = "identifier \"\(identifier)\""
        let hashes = valid(cdhashes)
        guard !hashes.isEmpty else { return base }
        return base + " and (" + hashes.map { "cdhash H\"\($0)\"" }.joined(separator: " or ") + ")"
    }

    private static func valid(_ hashes: [String]) -> [String] {
        var seen = Set<String>()
        return hashes.compactMap(normalizedHash).filter { seen.insert($0).inserted }
    }
}

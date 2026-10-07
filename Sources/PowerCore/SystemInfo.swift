import Foundation
import IOKit

/// Thông tin máy dùng cho chẩn đoán (smc-probe, báo lỗi).
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

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

import Foundation

/// Dò các SMC key điều khiển sạc trên máy hiện tại: có tồn tại không, có ghi được không.
/// Chỉ đọc, không bao giờ ghi.
public enum CapabilityProbe {
    /// Các control key helper có thể ghi (hoặc xóa khi khôi phục).
    public static let controlKeys = ["CHTE", "CH0B", "CH0C", "CHIE", "CH0I", "CH0J", "BCLM"]

    /// Kích thước (byte) đã biết của từng key. Khác kích thước thì không ghi (giá trị có thể mang nghĩa khác).
    public static let expectedSizes: [String: Int] = [
        "CHTE": 4, "CH0B": 1, "CH0C": 1, "CHIE": 1, "CH0I": 1, "CH0J": 1, "BCLM": 1,
    ]

    /// - present: đọc được và có dữ liệu.
    /// - writable: bit thuộc tính 0x40 và đúng kích thước đã biết.
    public static func capability(of key: String, in smc: SMCAccess, locked: Bool = false) -> KeyCapability {
        guard let reading = smc.read(key), !reading.bytes.isEmpty else {
            return KeyCapability(name: key, present: false, writable: false, locked: locked)
        }
        let sizeOK = expectedSizes[key].map { $0 == reading.bytes.count } ?? true
        return KeyCapability(name: key, present: true, writable: reading.isWritable && sizeOK, locked: locked)
    }

    public static func probe(_ smc: SMCAccess, keys: [String] = controlKeys,
                             locked: Set<String> = []) -> [KeyCapability] {
        keys.map { capability(of: $0, in: smc, locked: locked.contains($0)) }
    }

    /// Key dùng được để điều khiển: có, ghi được và chưa bị firmware khóa.
    public static func isUsable(_ capability: KeyCapability?) -> Bool {
        guard let capability else { return false }
        return capability.present && capability.writable && !capability.locked
    }
}

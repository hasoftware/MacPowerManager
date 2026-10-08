import Foundation

/// Phát hiện control key bị tiến trình khác thay đổi so với giá trị helper ghi lần cuối.
public enum ForeignWriteDetector {
    /// So từng key trong `lastWritten` với giá trị đọc được (bỏ qua key không đọc được).
    /// Kết quả sắp theo tên key, giá trị dạng hex chữ thường (ví dụ `01000000`).
    public static func detect(lastWritten: [String: [UInt8]], current: [String: [UInt8]], now: Date) -> [ForeignWrite] {
        lastWritten.keys.sorted().compactMap { key in
            guard let expected = lastWritten[key], let found = current[key], found != expected else { return nil }
            return ForeignWrite(key: key, expected: hex(expected), found: hex(found), at: now)
        }
    }

    /// Key ngắt adapter (`CHIE`, `CH0I`, `CH0J`) helper chưa từng ghi nhưng đang khác 0 khi helper không xả:
    /// một tiến trình khác (AlDente, batt…) đã ngắt adapter. Giá trị mong đợi là `00…`.
    /// Không báo khi helper đang xả (`discharging`), vì khi đó adapter bị ngắt là chủ ý.
    public static func detectUnownedAdapterCuts(lastWritten: [String: [UInt8]], current: [String: [UInt8]],
                                                discharging: Bool, now: Date) -> [ForeignWrite] {
        guard !discharging else { return [] }
        return ChargingControl.allAdapterKeys.compactMap { key in
            guard lastWritten[key] == nil, let found = current[key], found.contains(where: { $0 != 0 }) else { return nil }
            return ForeignWrite(key: key, expected: hex(Array(repeating: 0, count: found.count)), found: hex(found), at: now)
        }
    }

    public static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

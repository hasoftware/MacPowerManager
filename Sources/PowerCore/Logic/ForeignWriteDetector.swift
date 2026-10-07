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

    public static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

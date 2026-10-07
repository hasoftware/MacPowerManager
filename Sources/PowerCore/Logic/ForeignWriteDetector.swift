import Foundation

/// Phát hiện control key bị tiến trình khác thay đổi so với giá trị helper ghi lần cuối.
/// STUB của giai đoạn 0: gói việc "logic" sẽ hoàn thiện và viết test.
public enum ForeignWriteDetector {
    public static func detect(lastWritten: [String: [UInt8]], current: [String: [UInt8]], now: Date) -> [ForeignWrite] {
        []
    }
}

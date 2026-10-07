import PowerCore

/// Bọc SMC thật và báo lại mọi lần ghi thành công, để helper nhớ giá trị đã ghi cho từng control key
/// (phát hiện tiến trình khác ghi đè). Đọc thì chuyển thẳng xuống SMC.
final class RecordingSMC: SMCAccess {
    private let base: SMCAccess
    var onWrite: ((String, [UInt8]) -> Void)?

    init(base: SMCAccess) {
        self.base = base
    }

    func read(_ key: String) -> SMCReading? { base.read(key) }

    func write(_ key: String, _ bytes: [UInt8]) throws {
        try base.write(key, bytes)
        onWrite?(key, bytes)
    }
}

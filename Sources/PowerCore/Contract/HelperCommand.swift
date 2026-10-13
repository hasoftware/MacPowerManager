import Foundation

/// Lệnh app gửi tới helper qua `PowerHelperProtocol.perform(command:reply:)` (JSON).
public enum HelperCommand: Codable, Equatable, Sendable {
    /// Thay toàn bộ cấu hình (helper luôn chạy `sanitized()`).
    case setConfig(PowerConfig)
    /// Sạc đầy một lần; `hours` nil = mặc định `PowerConstants.topUpDefaultHours`.
    case startTopUp(hours: Int?)
    case cancelTopUp
    /// Bỏ qua khoảng sailing một lần và sạc tới giới hạn.
    case chargeToLimitNow
    /// Helper tự cập nhật từ bản phát hành đã tải và đã ký (v0.6.0+): kiểm tra lại chữ ký, thay helper,
    /// ghim cdhash của app mới rồi tự khởi động lại. Không cần mật khẩu quản trị.
    case installUpdate(archivePath: String, signature: String)
}

public enum HelperError: String, Codable, Sendable {
    case invalidArgument
    /// Lệnh cần cắm sạc (ví dụ sạc đầy một lần).
    case notPluggedIn
    case unsupported
    case notAuthorized
    case failed
}

public struct HelperResponse: Codable, Sendable {
    public var ok: Bool
    public var error: HelperError?
    public var message: String?
    public var status: HelperStatus?

    public init(ok: Bool, error: HelperError? = nil, message: String? = nil, status: HelperStatus? = nil) {
        self.ok = ok
        self.error = error
        self.message = message
        self.status = status
    }
}

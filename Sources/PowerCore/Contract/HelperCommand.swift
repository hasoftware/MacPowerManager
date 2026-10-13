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
    /// Hiệu chuẩn pin (v0.9.0): sạc đầy, xả xuống thấp, sạc đầy lại rồi trở về giới hạn.
    case startCalibration
    case cancelCalibration
    /// Đặt thử màu đèn MagSafe vài giây (v0.10.0), để người dùng xem máy có hỗ trợ không.
    case testMagSafeLED(MagSafeLEDColor)
    /// Danh sách tiến trình của mọi người dùng (v0.14.0, chỉ đọc). App chỉ tự đọc được tiến trình của chính mình.
    case processes
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
    /// Trả lời `HelperCommand.processes`.
    public var processes: [ProcessSample]?

    public init(ok: Bool, error: HelperError? = nil, message: String? = nil, status: HelperStatus? = nil,
                processes: [ProcessSample]? = nil) {
        self.ok = ok
        self.error = error
        self.message = message
        self.status = status
        self.processes = processes
    }
}

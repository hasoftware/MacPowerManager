import Foundation

/// Khả năng của một SMC key điều khiển trên máy hiện tại.
public struct KeyCapability: Codable, Equatable, Sendable {
    public var name: String
    public var present: Bool
    public var writable: Bool
    /// Ghi bị từ chối với kIOReturnNotPrivileged dù chạy bằng root (firmware khóa).
    public var locked: Bool

    public init(name: String, present: Bool, writable: Bool, locked: Bool = false) {
        self.name = name
        self.present = present
        self.writable = writable
        self.locked = locked
    }
}

public struct Capabilities: Codable, Equatable, Sendable {
    /// Phương thức chặn sạc đang dùng: "CHTE", "CH0B/CH0C", "BCLM" hoặc nil (không hỗ trợ).
    public var chargeMethod: String?
    /// Phương thức ngắt adapter đang dùng: "CHIE", "CH0J", "CH0I" hoặc nil.
    public var adapterMethod: String?
    public var keys: [KeyCapability]

    public init(chargeMethod: String? = nil, adapterMethod: String? = nil, keys: [KeyCapability] = []) {
        self.chargeMethod = chargeMethod
        self.adapterMethod = adapterMethod
        self.keys = keys
    }
}

/// Kết quả xác minh lệnh chặn sạc có thực sự hiệu lực (dòng sạc vào pin ≈ 0).
public enum EffectState: Codable, Equatable, Sendable {
    /// Không cần xác minh (đang sạc, không cắm sạc, pin đầy, máy Intel…).
    case notApplicable
    case pending(since: Date)
    case verified
    /// Đã chặn sạc quá `PowerConstants.effectVerifySeconds` mà pin vẫn nhận dòng sạc.
    case ineffective(detail: String)
}

/// Một control key bị tiến trình khác thay đổi (ví dụ AlDente, batt).
public struct ForeignWrite: Codable, Equatable, Sendable {
    public var key: String
    public var expected: String   // hex helper đã ghi
    public var found: String      // hex đọc được
    public var at: Date

    public init(key: String, expected: String, found: String, at: Date) {
        self.key = key
        self.expected = expected
        self.found = found
        self.at = at
    }
}

/// Trạng thái helper lưu vào `state.json`; không bao giờ gửi từ app.
public struct RuntimeState: Codable, Equatable, Sendable {
    public var controller = ControllerState()
    /// Giá trị helper ghi lần cuối cho mỗi control key (để phát hiện ghi từ bên ngoài).
    public var lastWritten: [String: [UInt8]] = [:]
    public var bootSessionUUID: String?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        controller = (try? c.decodeIfPresent(ControllerState.self, forKey: .controller)) ?? nil ?? ControllerState()
        lastWritten = (try? c.decodeIfPresent([String: [UInt8]].self, forKey: .lastWritten)) ?? nil ?? [:]
        bootSessionUUID = (try? c.decodeIfPresent(String.self, forKey: .bootSessionUUID)) ?? nil
    }
}

import Foundation

/// Giao thức XPC giữa app và helper. Dữ liệu phức tạp được mã hóa JSON trong `Data`.
@objc public protocol PowerHelperProtocol {
    func version(reply: @escaping (String) -> Void)
    /// Trả về `HelperStatus` dạng JSON.
    func status(reply: @escaping (Data?) -> Void)
    /// Nhận `PowerConfig` dạng JSON. Trả về thông báo lỗi hoặc nil.
    func apply(config: Data, reply: @escaping (String?) -> Void)
    /// Khôi phục mặc định (bật sạc, bật adapter) trước khi gỡ helper.
    func restoreDefaults(reply: @escaping () -> Void)
}

public struct HelperStatus: Codable, Equatable, Sendable {
    public var version: String
    public var config: PowerConfig
    public var chargingKeys: String?
    public var adapterKeys: String?
    public var chargingEnabled: Bool?
    public var adapterEnabled: Bool?
    public var reason: ChargeReason
    public var temperature: Double?
    public var lastError: String?

    public init(version: String, config: PowerConfig, chargingKeys: String?, adapterKeys: String?,
                chargingEnabled: Bool?, adapterEnabled: Bool?, reason: ChargeReason,
                temperature: Double?, lastError: String?) {
        self.version = version
        self.config = config
        self.chargingKeys = chargingKeys
        self.adapterKeys = adapterKeys
        self.chargingEnabled = chargingEnabled
        self.adapterEnabled = adapterEnabled
        self.reason = reason
        self.temperature = temperature
        self.lastError = lastError
    }
}

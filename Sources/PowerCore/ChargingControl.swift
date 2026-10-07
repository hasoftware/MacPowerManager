import Foundation

/// Bật/tắt sạc và adapter qua SMC.
///
/// Apple không có API công khai cho việc này. Key được dò theo firmware:
/// - Firmware mới (macOS 26+): `CHTE` (sạc) và `CHIE` (adapter).
/// - Firmware cũ hơn: `CH0B`/`CH0C` (sạc) và `CH0I` (adapter).
public final class ChargingControl {
    public enum ChargingKeys: String, Codable, Sendable { case chte = "CHTE", ch0bc = "CH0B/CH0C" }
    public enum AdapterKeys: String, Codable, Sendable { case chie = "CHIE", ch0i = "CH0I" }

    private let smc: SMC
    public let chargingKeys: ChargingKeys?
    public let adapterKeys: AdapterKeys?

    public init(smc: SMC) {
        self.smc = smc
        guard Platform.isAppleSilicon else {
            chargingKeys = nil
            adapterKeys = nil
            return
        }
        if smc.hasKey("CHTE") {
            chargingKeys = .chte
        } else if smc.hasKey("CH0B") && smc.hasKey("CH0C") {
            chargingKeys = .ch0bc
        } else {
            chargingKeys = nil
        }
        if smc.hasKey("CHIE") {
            adapterKeys = .chie
        } else if smc.hasKey("CH0I") {
            adapterKeys = .ch0i
        } else {
            adapterKeys = nil
        }
    }

    // MARK: Sạc

    public var isChargingEnabled: Bool? {
        switch chargingKeys {
        case .chte:
            return smc.read("CHTE").map { $0.bytes.allSatisfy { $0 == 0 } }
        case .ch0bc:
            guard let b = smc.read("CH0B"), let c = smc.read("CH0C") else { return nil }
            return b.bytes.allSatisfy { $0 == 0 } && c.bytes.allSatisfy { $0 == 0 }
        case nil:
            return nil
        }
    }

    public func setChargingEnabled(_ enabled: Bool) throws {
        switch chargingKeys {
        case .chte:
            try smc.write("CHTE", enabled ? [0x00, 0x00, 0x00, 0x00] : [0x01, 0x00, 0x00, 0x00])
        case .ch0bc:
            let v: UInt8 = enabled ? 0x00 : 0x02
            try smc.write("CH0B", [v])
            try smc.write("CH0C", [v])
        case nil:
            throw SMCError(key: "charging", code: kIOReturnUnsupported)
        }
    }

    // MARK: Adapter (tắt adapter = máy chạy bằng pin dù đang cắm sạc)

    public var isAdapterEnabled: Bool? {
        switch adapterKeys {
        case .chie: return smc.read("CHIE").map { $0.bytes.allSatisfy { $0 == 0 } }
        case .ch0i: return smc.read("CH0I").map { $0.bytes.allSatisfy { $0 == 0 } }
        case nil: return nil
        }
    }

    public func setAdapterEnabled(_ enabled: Bool) throws {
        switch adapterKeys {
        case .chie: try smc.write("CHIE", [enabled ? 0x00 : 0x08])
        case .ch0i: try smc.write("CH0I", [enabled ? 0x00 : 0x01])
        case nil: throw SMCError(key: "adapter", code: kIOReturnUnsupported)
        }
    }

    // MARK: Cảm biến

    /// Nhiệt độ pin cao nhất trong các cảm biến TB0T…TB2T (°C).
    public var batteryTemperature: Double? { SMCSensors.batteryTemperature(smc) }

    /// Các key ngắt adapter đã biết. Khi gỡ cài đặt, xóa hết về 0 dù không phải do app ghi.
    static let allAdapterKeys = ["CHIE", "CH0I", "CH0J"]

    /// Đưa mọi thứ về mặc định của macOS: bật adapter (mọi key ngắt adapter) và cho phép sạc.
    /// Trả về true nếu đọc lại thấy đúng trạng thái mặc định.
    @discardableResult
    public func restoreDefaults() -> Bool {
        guard Platform.isAppleSilicon else { return true }
        for key in Self.allAdapterKeys {
            guard let r = smc.read(key), r.bytes.contains(where: { $0 != 0 }) else { continue }
            try? smc.write(key, Array(repeating: 0, count: r.bytes.count))
        }
        if chargingKeys != nil { try? setChargingEnabled(true) }
        let adaptersClear = Self.allAdapterKeys.allSatisfy { key in
            smc.read(key).map { $0.bytes.allSatisfy { $0 == 0 } } ?? true
        }
        return adaptersClear && (chargingKeys == nil || isChargingEnabled == true)
    }
}

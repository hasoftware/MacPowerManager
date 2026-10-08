import Foundation

/// Bật/tắt sạc và adapter qua SMC.
///
/// Apple không có API công khai cho việc này. Phương thức được chọn theo khả năng của từng key
/// (`CapabilityProbe`), không theo phiên bản macOS:
/// - Sạc: `CHTE`, nếu không có thì `CH0C` (phương thức cũ, tên hiển thị "CH0B/CH0C"). Chỉ ghi `CH0C`:
///   macOS dùng `CH0B` cho Sạc tối ưu, ghi vào đó là tranh chấp với hệ thống.
/// - Adapter: `CHIE`, nếu không có thì `CH0I`. `CH0J` chưa rõ giá trị ngắt nên chỉ được xóa khi khôi phục.
///
/// Firmware có thể khóa key (ghi bị từ chối với kIOReturnNotPrivileged dù chạy bằng root). Khi đó key bị đánh dấu
/// khóa và chuyển sang phương thức kế tiếp; key bị khóa không bao giờ được thử ghi lại trong vòng điều khiển.
public final class ChargingControl {
    public enum ChargingKeys: String, Codable, Sendable, CaseIterable {
        case chte = "CHTE", ch0bc = "CH0B/CH0C"

        /// Các key phương thức này ghi (và cần ghi được để chọn). `.ch0bc` giữ tên cũ để tương thích
        /// nhưng chỉ ghi `CH0C`.
        var keys: [String] {
            switch self {
            case .chte: ["CHTE"]
            case .ch0bc: ["CH0C"]
            }
        }
    }

    public enum AdapterKeys: String, Codable, Sendable, CaseIterable {
        case chie = "CHIE", ch0i = "CH0I"

        var key: String { rawValue }
    }

    private let smc: SMCAccess
    private let isAppleSilicon: Bool
    public private(set) var chargingKeys: ChargingKeys?
    public private(set) var adapterKeys: AdapterKeys?
    /// Khả năng của các control key; cờ `locked` được cập nhật khi ghi bị firmware từ chối.
    public private(set) var keys: [KeyCapability]

    public convenience init(smc: SMCAccess) {
        self.init(smc: smc, isAppleSilicon: Platform.isAppleSilicon)
    }

    public init(smc: SMCAccess, isAppleSilicon: Bool) {
        self.smc = smc
        self.isAppleSilicon = isAppleSilicon
        keys = CapabilityProbe.probe(smc)
        selectMethods()
    }

    public var capabilities: Capabilities {
        Capabilities(chargeMethod: chargingKeys?.rawValue, adapterMethod: adapterKeys?.rawValue, keys: keys)
    }

    public var lockedKeys: Set<String> { Set(keys.filter(\.locked).map(\.name)) }

    private func capability(_ key: String) -> KeyCapability? { keys.first { $0.name == key } }

    private func usable(_ key: String) -> Bool { CapabilityProbe.isUsable(capability(key)) }

    private func selectMethods() {
        guard isAppleSilicon else {
            chargingKeys = nil
            adapterKeys = nil
            return
        }
        chargingKeys = ChargingKeys.allCases.first { $0.keys.allSatisfy(usable) }
        adapterKeys = AdapterKeys.allCases.first { usable($0.key) }
    }

    /// Đánh dấu key bị firmware khóa và chọn lại phương thức.
    private func lock(_ key: String) {
        guard let index = keys.firstIndex(where: { $0.name == key }) else { return }
        keys[index].locked = true
        selectMethods()
    }

    private static func isNotPrivileged(_ error: Error) -> Bool {
        (error as? SMCError)?.code == kIOReturnNotPrivileged
    }

    /// Ghi rồi đọc lại để xác minh; sai thì thử lại một lần.
    private func write(_ key: String, _ bytes: [UInt8]) throws {
        try smc.write(key, bytes)
        guard smc.read(key)?.bytes != bytes else { return }
        try smc.write(key, bytes)
        guard smc.read(key)?.bytes == bytes else { throw SMCError(key: key, code: kIOReturnError) }
    }

    // MARK: Sạc

    public var isChargingEnabled: Bool? {
        switch chargingKeys {
        case .chte:
            return smc.read("CHTE").map { $0.bytes.allSatisfy { $0 == 0 } }
        case .ch0bc:
            // Chỉ xét CH0C: CH0B thuộc về Sạc tối ưu của macOS.
            return smc.read("CH0C").map { $0.bytes.allSatisfy { $0 == 0 } }
        case nil:
            return nil
        }
    }

    public func setChargingEnabled(_ enabled: Bool) throws {
        // Mỗi phương thức chỉ được thử một lần: key bị khóa thì chuyển sang phương thức kế tiếp.
        while let method = chargingKeys {
            do {
                try write(method, enabled: enabled)
                return
            } catch let error as SMCError where Self.isNotPrivileged(error) {
                lock(error.key)
                if chargingKeys == method { throw error }
            }
        }
        throw SMCError(key: "charging", code: kIOReturnUnsupported)
    }

    private func write(_ method: ChargingKeys, enabled: Bool) throws {
        switch method {
        case .chte:
            try write("CHTE", enabled ? [0x00, 0x00, 0x00, 0x00] : [0x01, 0x00, 0x00, 0x00])
        case .ch0bc:
            // 02 như v0.2 (batt ghi 02; Battery-Toolkit ghi 01 vào CH0C, chưa xác minh trên phần cứng).
            try write("CH0C", [enabled ? 0x00 : 0x02])
        }
    }

    // MARK: Adapter (tắt adapter = máy chạy bằng pin dù đang cắm sạc)

    public var isAdapterEnabled: Bool? {
        guard let adapterKeys else { return nil }
        return smc.read(adapterKeys.key).map { $0.bytes.allSatisfy { $0 == 0 } }
    }

    public func setAdapterEnabled(_ enabled: Bool) throws {
        guard adapterKeys != nil else { throw SMCError(key: "adapter", code: kIOReturnUnsupported) }
        do {
            try writeAdapter(enabled: enabled)
        } catch let error where enabled {
            // Không bật lại được adapter: xóa mọi key ngắt adapter để máy không kẹt ở chế độ chạy pin.
            clearAdapterKeys()
            guard Self.allAdapterKeys.allSatisfy(isZeroOrAbsent) else { throw error }
        }
    }

    private func writeAdapter(enabled: Bool) throws {
        while let method = adapterKeys {
            do {
                switch method {
                case .chie: try write("CHIE", [enabled ? 0x00 : 0x08])
                case .ch0i: try write("CH0I", [enabled ? 0x00 : 0x01])
                }
                return
            } catch let error as SMCError where Self.isNotPrivileged(error) {
                lock(error.key)
                if adapterKeys == method { throw error }
            }
        }
        throw SMCError(key: "adapter", code: kIOReturnUnsupported)
    }

    // MARK: Cảm biến

    /// Nhiệt độ pin cao nhất trong các cảm biến TB0T…TB2T (°C).
    public var batteryTemperature: Double? { SMCSensors.batteryTemperature(smc) }

    /// Dòng điện vào pin (mA, dương = đang sạc) từ `B0AC` (si16). Nil nếu không có key.
    public var batteryCurrentmA: Int? {
        guard let reading = smc.read("B0AC"), reading.type == "si16", let value = reading.doubleValue else { return nil }
        return Int(value)
    }

    // MARK: Khôi phục

    /// Các key ngắt adapter đã biết. Khi khôi phục, xóa hết về 0 dù không phải do app ghi.
    public static let allAdapterKeys = ["CHIE", "CH0I", "CH0J"]

    private func isZeroOrAbsent(_ key: String) -> Bool {
        smc.read(key).map { $0.bytes.allSatisfy { $0 == 0 } } ?? true
    }

    /// Xóa mọi key ngắt adapter đang khác 0, kể cả key không thuộc phương thức đang dùng
    /// (ví dụ `CH0I` còn lại sau khi phiên trước chuyển phương thức). Trả về các key đã xóa được.
    @discardableResult
    public func clearAdapterKeys() -> [String] {
        guard isAppleSilicon else { return [] }
        var cleared: [String] = []
        for key in Self.allAdapterKeys {
            guard let r = smc.read(key), r.bytes.contains(where: { $0 != 0 }) else { continue }
            if (try? write(key, Array(repeating: 0, count: r.bytes.count))) != nil { cleared.append(key) }
        }
        return cleared
    }

    /// Đưa mọi thứ về mặc định của macOS: bật adapter (mọi key ngắt adapter) và cho phép sạc.
    /// - extraKeys: các key chặn sạc helper từng ghi (`RuntimeState.lastWritten`), ví dụ `CH0B` khi phiên trước
    ///   dùng phương thức cũ của v0.2. `CH0C` luôn được xóa; `CH0B` chỉ xóa khi có trong danh sách này
    ///   (macOS dùng nó cho Sạc tối ưu), kể cả khi đang dùng phương thức `.ch0bc`.
    /// Trả về true nếu đọc lại thấy đúng trạng thái mặc định.
    @discardableResult
    public func restoreDefaults(clearing extraKeys: Set<String> = []) -> Bool {
        guard isAppleSilicon else { return true }
        clearAdapterKeys()
        if chargingKeys != nil { try? setChargingEnabled(true) }
        let chargeKeys = ["CHTE", "CH0C"] + (extraKeys.contains("CH0B") ? ["CH0B"] : [])
        for key in chargeKeys where !isZeroOrAbsent(key) {
            guard let r = smc.read(key), r.isWritable else { continue }
            try? write(key, Array(repeating: 0, count: r.bytes.count))
        }
        let adaptersClear = Self.allAdapterKeys.allSatisfy(isZeroOrAbsent)
        return adaptersClear && (chargingKeys == nil || isChargingEnabled == true)
    }
}

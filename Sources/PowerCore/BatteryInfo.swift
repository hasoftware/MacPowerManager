import Foundation
import IOKit
import IOKit.ps

public struct BatteryInfo: Codable, Equatable, Sendable {
    public var percent = 0
    public var isCharging = false
    public var externalConnected = false
    public var fullyCharged = false
    public var cycleCount = 0
    public var designCycleCount = 1000
    public var designCapacity = 0       // mAh
    public var maxCapacity = 0          // mAh, dung lượng thực tế khi đầy
    public var currentCapacity = 0      // mAh
    public var voltage = 0              // mV
    public var amperage = 0             // mA, âm khi xả
    public var temperature: Double?     // °C
    public var timeRemaining: Int?      // phút
    public var adapterWatts: Int?
    public var adapterName: String?
    public var systemPowerIn: Double?   // W, công suất từ adapter
    public var systemLoad: Double?      // W, công suất hệ thống tiêu thụ
    public var serial: String?

    public init() {}

    /// Sức khỏe pin: dung lượng thực tế so với thiết kế.
    public var health: Double {
        guard designCapacity > 0 else { return 0 }
        return min(Double(maxCapacity) / Double(designCapacity) * 100, 100)
    }

    /// Công suất vào/ra pin (W). Dương = đang nạp.
    public var batteryPower: Double { Double(voltage) * Double(amperage) / 1_000_000 }
}

public enum BatteryReader {
    /// Đọc thông tin pin từ IORegistry (`AppleSmartBattery`). Không cần quyền root.
    public static func read() -> BatteryInfo? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }

        func int(_ key: String) -> Int? { (dict[key] as? NSNumber)?.intValue }
        func bool(_ key: String) -> Bool { (dict[key] as? NSNumber)?.boolValue ?? false }

        var info = BatteryInfo()
        let current = int("CurrentCapacity") ?? 0
        let max = int("MaxCapacity") ?? 100
        info.percent = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : 0
        info.isCharging = bool("IsCharging")
        info.externalConnected = bool("ExternalConnected")
        info.fullyCharged = bool("FullyCharged")
        info.cycleCount = int("CycleCount") ?? 0
        info.designCycleCount = int("DesignCycleCount9C") ?? 1000
        info.designCapacity = int("DesignCapacity") ?? 0
        info.maxCapacity = int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity") ?? 0
        info.currentCapacity = int("AppleRawCurrentCapacity") ?? 0
        info.voltage = int("Voltage") ?? 0
        info.amperage = int("InstantAmperage") ?? int("Amperage") ?? 0
        info.temperature = int("Temperature").map { Double($0) / 100 }
        info.serial = dict["Serial"] as? String

        if let t = int("TimeRemaining"), t > 0, t < 65535 { info.timeRemaining = t }

        if let adapter = dict["AdapterDetails"] as? [String: Any] {
            info.adapterWatts = (adapter["Watts"] as? NSNumber)?.intValue
            info.adapterName = adapter["Name"] as? String
        }
        if let telemetry = dict["PowerTelemetryData"] as? [String: Any] {
            info.systemPowerIn = (telemetry["SystemPowerIn"] as? NSNumber).map { $0.doubleValue / 1000 }
            info.systemLoad = (telemetry["SystemLoad"] as? NSNumber).map { $0.doubleValue / 1000 }
        }
        return info
    }

    /// Đăng ký callback khi nguồn điện thay đổi (cắm/rút sạc, % thay đổi).
    /// Giữ lại giá trị trả về; giải phóng nó sẽ hủy đăng ký.
    public static func observeChanges(_ handler: @escaping () -> Void) -> PowerSourceObserver {
        PowerSourceObserver(handler: handler)
    }
}

public final class PowerSourceObserver {
    private let handler: () -> Void
    private var source: CFRunLoopSource?

    init(handler: @escaping () -> Void) {
        self.handler = handler
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<PowerSourceObserver>.fromOpaque(ctx).takeUnretainedValue().handler()
        }, context)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
    }
}

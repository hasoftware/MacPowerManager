import Foundation
import Observation
import PowerCore

@MainActor
@Observable
final class AppModel {
    private(set) var battery: BatteryInfo?
    private(set) var smcTemperature: Double?
    let helper = HelperClient()
    let history = HistoryStore()
    let notifier = Notifier()
    var prefs = Preferences.load() {
        didSet { prefs.save() }
    }

    @ObservationIgnored private var started = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observer: PowerSourceObserver?
    @ObservationIgnored private let sensors: ChargingControl? = (try? SMC()).map(ChargingControl.init)

    func start() {
        guard !started else { return }
        started = true
        notifier.requestAuthorization()
        refresh()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            AppMover.promptIfNeeded()
        }
        Task { await helper.refresh() }

        observer = BatteryReader.observeChanges { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                await self?.helper.refresh()
            }
        }
    }

    func refresh() {
        battery = BatteryReader.read()
        smcTemperature = sensors?.batteryTemperature
        guard let battery else { return }
        history.record(battery: battery, temperature: temperature)
        notifier.evaluate(battery: battery, temperature: temperature, helper: helper.status, prefs: prefs,
                          firmwareControlled: isIntelBackend)
    }

    /// Máy Intel dùng `BCLM`: firmware tự quyết định ngừng sạc theo phần trăm phần cứng.
    var isIntelBackend: Bool { helper.status?.chargingKeys == "BCLM" }

    /// Helper đã cài nhưng máy không có key điều khiển sạc nào dùng được.
    var controlUnsupported: Bool {
        helper.isReady && helper.status?.chargingKeys == nil
    }

    /// Cấu hình đang được helper thực thi, hoặc nil nếu chưa có helper / máy không hỗ trợ.
    var activeConfig: PowerConfig? {
        helper.isReady && !controlUnsupported ? helper.config : nil
    }

    /// Ưu tiên cảm biến SMC (sát thực tế hơn), dự phòng bằng giá trị từ IOKit.
    var temperature: Double? { smcTemperature ?? battery?.temperature }

    var batterySymbol: String {
        guard let battery else { return "battery.0percent" }
        if battery.isCharging { return "battery.100percent.bolt" }
        switch battery.percent {
        case 88...: return "battery.100percent"
        case 63...: return "battery.75percent"
        case 38...: return "battery.50percent"
        case 13...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    /// Mô tả ngắn trạng thái hiện tại.
    var statusText: String {
        guard let battery else { return "Không tìm thấy pin" }
        if let status = helper.status, status.reason != .normal {
            // Intel: firmware vẫn sạc tới mức BCLM (vượt giới hạn ~3%, hoặc tạm dừng dưới 50%).
            if isIntelBackend && battery.isCharging {
                return "Đang sạc tới \(status.firmwareLimit.map { "\($0)%" } ?? "giới hạn") (giới hạn firmware)"
            }
            return status.reason.label
        }
        if battery.isCharging {
            // Khi có giới hạn, ước tính thời gian tới giới hạn chứ không phải tới 100%.
            if let config = activeConfig, config.chargeLimitEnabled, config.chargeLimit < 100 {
                let time = battery.minutesToCharge(to: config.chargeLimit)
                    .map { " · tới \(config.chargeLimit)% sau \(Format.duration(minutes: $0))" } ?? ""
                return "Đang sạc\(time)"
            }
            let time = battery.timeRemaining.map { " · đầy sau \(Format.duration(minutes: $0))" } ?? ""
            return "Đang sạc\(time)"
        }
        if battery.externalConnected {
            return battery.fullyCharged ? "Đã sạc đầy" : "Đang cắm sạc"
        }
        let time = battery.timeRemaining.map { " · còn \(Format.duration(minutes: $0))" } ?? ""
        return "Đang dùng pin\(time)"
    }
}

struct Preferences: Codable, Equatable {
    var showPercentInMenuBar = true
    var notifyLimitReached = true
    var notifyLowBattery = true
    var lowBatteryThreshold = 20
    var notifyThermal = true
    var notifyDischargeDone = true

    private static let key = "preferences"

    init() {}

    /// Trường thiếu (từ bản cũ) dùng giá trị mặc định thay vì reset toàn bộ cài đặt.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        showPercentInMenuBar = value(.showPercentInMenuBar, d.showPercentInMenuBar)
        notifyLimitReached = value(.notifyLimitReached, d.notifyLimitReached)
        notifyLowBattery = value(.notifyLowBattery, d.notifyLowBattery)
        lowBatteryThreshold = value(.lowBatteryThreshold, d.lowBatteryThreshold)
        notifyThermal = value(.notifyThermal, d.notifyThermal)
        notifyDischargeDone = value(.notifyDischargeDone, d.notifyDischargeDone)
    }

    static func load() -> Preferences {
        guard let data = UserDefaults.standard.data(forKey: key),
              let prefs = try? JSONDecoder().decode(Preferences.self, from: data) else { return Preferences() }
        return prefs
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }
}

enum Format {
    static func duration(minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        return h > 0 ? "\(h) giờ \(m) phút" : "\(m) phút"
    }

    static func temperature(_ value: Double?) -> String {
        value.map { String(format: "%.1f°C", $0) } ?? "—"
    }

    static func watts(_ value: Double?) -> String {
        value.map { String(format: "%.1f W", $0) } ?? "—"
    }
}

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
        notifier.evaluate(battery: battery, temperature: temperature, helper: helper.status, prefs: prefs)
    }

    /// Cấu hình đang được helper thực thi, hoặc nil nếu chưa có helper (hoặc máy Intel).
    var activeConfig: PowerConfig? {
        Platform.isAppleSilicon && helper.isReady ? helper.config : nil
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
            return status.reason.label
        }
        if battery.isCharging {
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

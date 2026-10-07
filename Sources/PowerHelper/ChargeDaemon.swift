import Foundation
import IOKit
import IOKit.pwr_mgt
import PowerCore

// Các hằng số kIOMessage* là macro C nên không được import sang Swift.
private let kMsgCanSystemSleep: UInt32 = 0xE000_0270
private let kMsgSystemWillSleep: UInt32 = 0xE000_0280
private let kMsgSystemWillNotSleep: UInt32 = 0xE000_0290
private let kMsgSystemHasPoweredOn: UInt32 = 0xE000_0300

/// Bit "Graphics" trong `System Capabilities` của IOPMrootDomain: có nghĩa là máy đã thức hẳn
/// (màn hình bật), không phải dark wake.
private let kCapabilityGraphics = 0x2

final class ChargeDaemon {
    private let smc: SMC
    private let control: ChargingControl
    private(set) var config: PowerConfig
    private var state = ControllerState()
    private var lastDecision: ControlDecision?
    private var lastTemperature: Double?
    private var lastError: String?
    private var phase: WakePhase = .awake
    private var sleepPendingSince: Date?

    private var timer: DispatchSourceTimer?
    private var powerObserver: PowerSourceObserver?
    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var sleepAssertion: IOPMAssertionID = 0

    init() throws {
        smc = try SMC()
        control = ChargingControl(smc: smc)
        config = Self.loadConfig()
        log("Key sạc: \(control.chargingKeys?.rawValue ?? "không có"), adapter: \(control.adapterKeys?.rawValue ?? "không có")")

        // Trạng thái an toàn khi khởi động: nếu lần chạy trước bị dừng đột ngột lúc đang xả pin,
        // adapter có thể vẫn bị ngắt. Bật lại ngay, giữ nguyên trạng thái chặn sạc để tránh sạc thoáng qua.
        if control.isAdapterEnabled == false {
            log("Adapter đang bị ngắt khi khởi động, bật lại")
            try? control.setAdapterEnabled(true)
        }
    }

    func start() {
        evaluate()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 10, repeating: 10, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in self?.evaluate() }
        timer.resume()
        self.timer = timer

        powerObserver = BatteryReader.observeChanges { [weak self] in self?.evaluate() }
        registerForSleep()
    }

    // MARK: Vòng điều khiển

    func evaluate() {
        updatePhase()
        guard let battery = BatteryReader.read() else {
            lastError = "Không đọc được thông tin pin"
            return
        }
        let temperature = control.batteryTemperature ?? battery.temperature
        lastTemperature = temperature

        let decision = ChargeController.decide(percent: battery.percent, temperature: temperature,
                                               config: config, state: &state)
        if decision.dischargeFinished && config.dischargeEnabled {
            log("Đã xả xong tới \(battery.percent)%")
            config.dischargeEnabled = false
            saveConfig()
        }
        if decision != lastDecision {
            log("\(battery.percent)% \(temperature.map { String(format: "%.1f°C", $0) } ?? "") -> \(decision.reason.rawValue)")
        }
        lastDecision = decision
        let gated = SleepGate.constrain(charging: decision.chargingEnabled, adapter: decision.adapterEnabled,
                                        currentCharging: control.isChargingEnabled,
                                        currentAdapter: control.isAdapterEnabled, phase: phase,
                                        reason: decision.reason,
                                        holdsLevelDuringSleep: SleepGate.holdsLevelDuringSleep(config))
        applyToHardware(charging: gated.charging, adapter: gated.adapter)
        updateSleepAssertion(preventSleep: !gated.adapter)
    }

    /// Chuyển từ dark wake / sắp ngủ về trạng thái thức khi máy đã thức hẳn.
    private func updatePhase() {
        switch phase {
        case .awake:
            break
        case .darkWake:
            if isFullWake() {
                log("Máy đã thức hẳn")
                phase = .awake
            }
        case .sleepPending:
            // Không nhận được HasPoweredOn hoặc WillNotSleep (ngủ bị hủy): thoát sau 2 phút nếu máy đang thức.
            if let since = sleepPendingSince, Date().timeIntervalSince(since) > 120, isFullWake() {
                phase = .awake
            }
        }
    }

    private func isFullWake() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return true }
        defer { IOObjectRelease(root) }
        guard let caps = IORegistryEntryCreateCFProperty(root, "System Capabilities" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else { return true }
        return caps.intValue & kCapabilityGraphics != 0
    }

    private func applyToHardware(charging: Bool, adapter: Bool) {
        do {
            if control.chargingKeys != nil, control.isChargingEnabled != charging {
                try control.setChargingEnabled(charging)
            }
            if control.adapterKeys != nil, control.isAdapterEnabled != adapter {
                try control.setAdapterEnabled(adapter)
            }
            lastError = nil
        } catch {
            lastError = "\(error)"
            log("Ghi SMC thất bại: \(error)")
        }
    }

    /// Ngăn máy ngủ khi đang xả pin bằng cách ngắt adapter.
    private func updateSleepAssertion(preventSleep: Bool) {
        if preventSleep && sleepAssertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "MacPowerManager đang xả pin" as CFString,
                                        &sleepAssertion)
        } else if !preventSleep && sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
    }

    // MARK: Ngủ / thức

    private func registerForSleep() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(refcon, &notifyPort, { refcon, _, messageType, argument in
            guard let refcon else { return }
            let daemon = Unmanaged<ChargeDaemon>.fromOpaque(refcon).takeUnretainedValue()
            daemon.handlePower(message: messageType, argument: argument)
        }, &notifier)
        if let notifyPort {
            IONotificationPortSetDispatchQueue(notifyPort, .main)
        }
    }

    private func handlePower(message: UInt32, argument: UnsafeMutableRawPointer?) {
        switch message {
        case kMsgCanSystemSleep:
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case kMsgSystemWillSleep:
            phase = .sleepPending
            sleepPendingSince = Date()
            prepareForSleep()
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case kMsgSystemWillNotSleep:
            phase = .awake
            evaluate()
        case kMsgSystemHasPoweredOn:
            // Dark wake (Power Nap, sạc, bảo trì): chỉ được siết lại cho tới khi máy thức hẳn.
            phase = isFullWake() ? .awake : .darkWake
            log(phase == .awake ? "Máy thức dậy" : "Máy thức ngầm (dark wake)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.evaluate() }
        default:
            break
        }
    }

    private func prepareForSleep() {
        // Không bao giờ để máy ngủ khi adapter đang bị ngắt.
        let state = SleepGate.sleepState(config: config, currentCharging: control.isChargingEnabled,
                                         percent: BatteryReader.read()?.percent)
        log("Chuẩn bị ngủ: adapter bật, sạc \(state.charging ? "bật" : "tắt")")
        applyToHardware(charging: state.charging, adapter: state.adapter)
        updateSleepAssertion(preventSleep: false)
    }

    // MARK: Cấu hình

    func update(config newConfig: PowerConfig) {
        let wasDischarging = config.dischargeEnabled
        config = newConfig.sanitized()
        if config.dischargeEnabled && !wasDischarging {
            state.holdingAtLimit = false
        }
        saveConfig()
        evaluate()
    }

    func restoreDefaults() {
        updateSleepAssertion(preventSleep: false)
        if !control.restoreDefaults() {
            log("Khôi phục mặc định chưa xác minh được")
        }
    }

    func status() -> HelperStatus {
        HelperStatus(version: AppVersion.current,
                     config: config,
                     chargingKeys: control.chargingKeys?.rawValue,
                     adapterKeys: control.adapterKeys?.rawValue,
                     chargingEnabled: control.isChargingEnabled,
                     adapterEnabled: control.isAdapterEnabled,
                     reason: lastDecision?.reason ?? .normal,
                     temperature: lastTemperature,
                     lastError: lastError)
    }

    private static func loadConfig() -> PowerConfig {
        guard let data = try? Data(contentsOf: PowerConstants.helperConfigURL),
              let config = try? JSONDecoder().decode(PowerConfig.self, from: data) else {
            return PowerConfig()
        }
        // Không tiếp tục xả pin sau khi khởi động lại.
        var c = config.sanitized()
        c.dischargeEnabled = false
        return c
    }

    private func saveConfig() {
        let url = PowerConstants.helperConfigURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(config).write(to: url, options: .atomic)
        } catch {
            log("Không lưu được cấu hình: \(error)")
        }
    }
}

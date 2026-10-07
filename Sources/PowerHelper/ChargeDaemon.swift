import Foundation
import IOKit
import IOKit.pwr_mgt
import PowerCore

// Các hằng số kIOMessage* là macro C nên không được import sang Swift.
private let kMsgCanSystemSleep: UInt32 = 0xE000_0270
private let kMsgSystemWillSleep: UInt32 = 0xE000_0280
private let kMsgSystemHasPoweredOn: UInt32 = 0xE000_0300

final class ChargeDaemon {
    private let smc: SMC
    private let control: ChargingControl
    private(set) var config: PowerConfig
    private var state = ControllerState()
    private var lastDecision: ControlDecision?
    private var lastTemperature: Double?
    private var lastError: String?

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
        applyToHardware(charging: decision.chargingEnabled, adapter: decision.adapterEnabled)
        updateSleepAssertion(preventSleep: !decision.adapterEnabled)
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
            prepareForSleep()
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case kMsgSystemHasPoweredOn:
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.evaluate() }
        default:
            break
        }
    }

    private func prepareForSleep() {
        // Không bao giờ để máy ngủ khi adapter đang bị ngắt.
        let wantsHold = config.chargeLimitEnabled || config.pauseCharging || config.dischargeEnabled
        let charging = !(config.disableChargingBeforeSleep && wantsHold)
        log("Chuẩn bị ngủ: adapter bật, sạc \(charging ? "bật" : "tắt")")
        applyToHardware(charging: charging, adapter: true)
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
        control.restoreDefaults()
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

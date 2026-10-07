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
    /// Máy Intel: firmware tự giữ giới hạn qua `BCLM` (thử nghiệm). Nil trên Apple Silicon.
    private let intel: IntelChargeLimiter?
    private var lastIntelLimit: Int?
    private(set) var config: PowerConfig
    private var state = ControllerState()
    private var lastDecision: ControlDecision?
    private var lastTemperature: Double?
    private var lastError: String?
    private var phase: WakePhase = .awake
    /// Sau khi app yêu cầu khôi phục để gỡ cài đặt, ngừng ghi SMC một lúc để vòng lặp không ghi đè
    /// trước khi script gỡ dừng helper. Tự hết hạn nếu người dùng hủy việc gỡ.
    private var suspendedUntil: Date?
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
        intel = IntelChargeLimiter(smc: smc)
        config = Self.loadConfig()
        if let intel {
            log("Máy Intel: dùng BCLM (thử nghiệm), hiện tại \(intel.currentLimit.map(String.init) ?? "?")%")
        } else {
            log("Key sạc: \(control.chargingKeys?.rawValue ?? "không có"), adapter: \(control.adapterKeys?.rawValue ?? "không có")")
        }

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
        if let until = suspendedUntil {
            guard Date() >= until else { return }
            suspendedUntil = nil
            log("Tiếp tục điều khiển sạc (không có việc gỡ cài đặt nào diễn ra)")
        }
        updatePhase()
        guard let battery = BatteryReader.read() else {
            lastError = "Không đọc được thông tin pin"
            return
        }
        let temperature = intel?.batteryTemperature ?? control.batteryTemperature ?? battery.temperature
        lastTemperature = temperature

        // Intel không xả pin được: bỏ qua chế độ xả.
        var effective = config
        if intel != nil { effective.dischargeEnabled = false }
        let decision = ChargeController.decide(percent: battery.percent, temperature: temperature,
                                               config: effective, state: &state)
        if decision.dischargeFinished && config.dischargeEnabled {
            log("Đã xả xong tới \(battery.percent)%")
            config.dischargeEnabled = false
            saveConfig()
        }
        if decision != lastDecision {
            log("\(battery.percent)% \(temperature.map { String(format: "%.1f°C", $0) } ?? "") -> \(decision.reason.rawValue)")
        }
        lastDecision = decision
        if let intel {
            applyIntel(intel, decision: decision, battery: battery)
            return
        }
        let gated = SleepGate.constrain(charging: decision.chargingEnabled, adapter: decision.adapterEnabled,
                                        currentCharging: control.isChargingEnabled,
                                        currentAdapter: control.isAdapterEnabled, phase: phase,
                                        reason: decision.reason,
                                        holdsLevelDuringSleep: SleepGate.holdsLevelDuringSleep(config))
        applyToHardware(charging: gated.charging, adapter: gated.adapter)
        updateSleepAssertion(preventSleep: !gated.adapter)
    }

    /// Intel: ghi mức `BCLM` mong muốn. Firmware tự ngừng sạc khi đạt mức đó, kể cả lúc ngủ hoặc tắt máy,
    /// nên không cần cổng ngủ. Ghi lại nếu firmware/macOS tự đổi giá trị (ví dụ sau khi reset SMC).
    private func applyIntel(_ intel: IntelChargeLimiter, decision: ControlDecision, battery: BatteryInfo) {
        let target = IntelPolicy.firmwareLimit(config: config, reason: decision.reason,
                                               hardwarePercent: intel.hardwarePercent, percent: battery.percent)
        let current = intel.currentLimit
        guard current != target else {
            lastIntelLimit = target
            lastError = nil
            return
        }
        if let last = lastIntelLimit, current != last {
            log("BCLM bị đổi từ bên ngoài: \(last)% -> \(current.map(String.init) ?? "?")%, ghi lại")
        }
        do {
            try intel.setLimit(target)
            lastIntelLimit = target
            lastError = nil
            log("BCLM = \(target)%")
        } catch {
            lastError = "Không ghi được BCLM: \(error)"
            log("Ghi BCLM thất bại: \(error)")
        }
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
        guard intel == nil else { return }  // Intel: firmware tự giữ giới hạn khi ngủ.
        // Không bao giờ để máy ngủ khi adapter đang bị ngắt.
        let state = SleepGate.sleepState(config: config, currentCharging: control.isChargingEnabled,
                                         percent: BatteryReader.read()?.percent)
        log("Chuẩn bị ngủ: adapter bật, sạc \(state.charging ? "bật" : "tắt")")
        applyToHardware(charging: state.charging, adapter: state.adapter)
        updateSleepAssertion(preventSleep: false)
    }

    // MARK: Cấu hình

    func update(config newConfig: PowerConfig) {
        suspendedUntil = nil
        let wasDischarging = config.dischargeEnabled
        config = newConfig.sanitized()
        if config.dischargeEnabled && !wasDischarging {
            state.holdingAtLimit = false
        }
        saveConfig()
        evaluate()
    }

    /// - forUninstall false (tắt máy, launchd dừng helper): Apple Silicon trả SMC về mặc định để không
    ///   kẹt ở trạng thái chặn sạc/ngắt adapter; Intel giữ nguyên `BCLM` để firmware tiếp tục giới hạn khi máy tắt.
    /// - forUninstall true: trả mọi thứ về mặc định của macOS, kể cả `BCLM` = 100.
    func restoreDefaults(forUninstall: Bool) {
        updateSleepAssertion(preventSleep: false)
        if !control.restoreDefaults() {
            log("Khôi phục mặc định chưa xác minh được")
        }
        if forUninstall, let intel, !intel.restoreDefaults() {
            log("Không trả được BCLM về 100%")
        }
        if forUninstall {
            suspendedUntil = Date().addingTimeInterval(120)
        }
    }

    func status() -> HelperStatus {
        HelperStatus(version: AppVersion.current,
                     config: config,
                     chargingKeys: intel != nil ? "BCLM" : control.chargingKeys?.rawValue,
                     adapterKeys: control.adapterKeys?.rawValue,
                     chargingEnabled: control.isChargingEnabled,
                     adapterEnabled: control.isAdapterEnabled,
                     reason: lastDecision?.reason ?? .normal,
                     temperature: lastTemperature,
                     lastError: lastError,
                     firmwareLimit: intel?.currentLimit)
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

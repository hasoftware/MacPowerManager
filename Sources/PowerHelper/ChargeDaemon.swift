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

/// Sau khi khởi động hoặc thức dậy, SMC có thể vừa bị reset (ngủ sâu): giá trị khác với lần ghi trước
/// không phải do tiến trình khác, nên không kiểm tra ghi từ bên ngoài trong khoảng này.
private let auditGraceSeconds: TimeInterval = 30
private let maxForeignWrites = 10

final class ChargeDaemon {
    private let smc: RecordingSMC
    private let control: ChargingControl
    /// Máy Intel: firmware tự giữ giới hạn qua `BCLM` (thử nghiệm). Nil trên Apple Silicon.
    private let intel: IntelChargeLimiter?
    private var lastIntelLimit: Int?
    private(set) var config: PowerConfig
    /// Lưu ở `state.json`: trạng thái bộ điều khiển và giá trị đã ghi cho từng control key.
    private var runtime: RuntimeState
    private var savedRuntime: RuntimeState?
    private var lastSaveError: String?
    private let bootSessionUUID: String
    private let firmware: String?
    private var lastDecision: ControlDecision?
    private var lastTemperature: Double?
    private var lastError: String?
    private var lidClosed: Bool?
    private var phase: WakePhase = .awake
    /// Sau khi app yêu cầu khôi phục để gỡ cài đặt, ngừng ghi SMC một lúc để vòng lặp không ghi đè
    /// trước khi script gỡ dừng helper. Tự hết hạn nếu người dùng hủy việc gỡ.
    private var suspendedUntil: Date?
    private var sleepPendingSince: Date?

    /// Thời điểm bắt đầu chặn sạc khi đang cắm sạc (để xác minh lệnh có hiệu lực).
    private var inhibitedSince: Date?
    private var effect: EffectState = .notApplicable
    private var lastCapabilities: Capabilities

    private var auditSuppressedUntil: Date?
    private var foreignWrites: [ForeignWrite] = []
    /// Ghi từ bên ngoài đã báo (key -> giá trị hex) để mỗi lần thay đổi chỉ ghi log một lần.
    private var reportedForeign: [String: String] = [:]

    private var timer: DispatchSourceTimer?
    private var powerObserver: PowerSourceObserver?
    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var sleepAssertion: IOPMAssertionID = 0

    init() throws {
        let smc = RecordingSMC(base: try SMC())
        self.smc = smc
        control = ChargingControl(smc: smc)
        intel = IntelChargeLimiter(smc: smc)
        config = Self.loadConfig()
        bootSessionUUID = SystemInfo.bootSessionUUID
        firmware = SystemInfo.firmwareVersion
        let saved = Self.loadRuntime()
        let reconciled = BootSession.reconcile(saved ?? RuntimeState(), currentUUID: bootSessionUUID)
        runtime = reconciled.state
        savedRuntime = saved
        lastCapabilities = control.capabilities
        auditSuppressedUntil = Date().addingTimeInterval(auditGraceSeconds)
        smc.onWrite = { [weak self] key, bytes in
            guard CapabilityProbe.controlKeys.contains(key) else { return }
            self?.runtime.lastWritten[key] = bytes
        }

        if reconciled.isNewBoot, saved != nil {
            log("Phiên khởi động mới: bỏ trạng thái sạc đầy một lần và trạng thái giữ mức của phiên trước")
        }
        if let intel {
            log("Máy Intel: dùng BCLM (thử nghiệm), hiện tại \(intel.currentLimit.map(String.init) ?? "?")%")
        } else {
            log("Key sạc: \(control.chargingKeys?.rawValue ?? "không có"), adapter: \(control.adapterKeys?.rawValue ?? "không có")")
        }

        // Trạng thái an toàn khi khởi động: nếu lần chạy trước bị dừng đột ngột lúc đang xả pin,
        // adapter có thể vẫn bị ngắt. Bật lại ngay (mọi key ngắt adapter, kể cả do tiến trình khác ghi),
        // giữ nguyên trạng thái chặn sạc để tránh sạc thoáng qua.
        let cleared = control.clearAdapterKeys()
        if !cleared.isEmpty {
            log("Adapter đang bị ngắt khi khởi động (\(cleared.joined(separator: ", "))), bật lại")
        }
        saveRuntimeIfChanged()
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
        let now = Date()
        let temperature = intel?.batteryTemperature ?? control.batteryTemperature ?? battery.temperature
        lastTemperature = temperature
        lidClosed = SystemInfo.lidClosed
        let acPresent = isACPresent(battery)

        // Kiểm tra trước khi ghi, để so với giá trị helper ghi ở vòng trước.
        auditForeignWrites(now: now)

        // Intel không xả pin được: bỏ qua chế độ xả.
        var effective = config
        if intel != nil { effective.dischargeEnabled = false }
        let input = ControllerInput(now: now, percent: battery.percent, temperature: temperature,
                                    acPresent: acPresent, lidClosed: lidClosed ?? false,
                                    bootSessionUUID: bootSessionUUID)
        let decision = ChargeController.decide(input: input, config: effective, state: &runtime.controller)
        handle(effects: decision.effects, percent: battery.percent)
        if decision != lastDecision {
            log("\(battery.percent)% \(temperature.map { String(format: "%.1f°C", $0) } ?? "")"
                + " -> \(decision.reason.rawValue) (giới hạn \(decision.effectiveLimit)%)")
        }
        lastDecision = decision

        if let intel {
            applyIntel(intel, decision: decision, battery: battery)
            effect = .notApplicable
        } else {
            let topUpActive = runtime.controller.topUp != nil
            let gated = SleepGate.constrain(charging: decision.chargingEnabled, adapter: decision.adapterEnabled,
                                            currentCharging: control.isChargingEnabled,
                                            currentAdapter: control.isAdapterEnabled, phase: phase,
                                            reason: decision.reason,
                                            holdsLevelDuringSleep: SleepGate.holdsLevelDuringSleep(config, topUpActive: topUpActive))
            applyToHardware(charging: gated.charging, adapter: gated.adapter)
            updateSleepAssertion(preventSleep: !gated.adapter)
            updateEffect(now: now, acPresent: acPresent, battery: battery)
        }
        finishLoop(now: now)
    }

    /// Cắm sạc về mặt vật lý. Khi chính helper ngắt adapter để xả, IOKit báo không cắm sạc nên vẫn coi là đang cắm.
    private func isACPresent(_ battery: BatteryInfo) -> Bool {
        battery.externalConnected || control.isAdapterEnabled == false
    }

    private func handle(effects: [ControllerEffect], percent: Int) {
        for item in effects {
            switch item {
            case .dischargeFinished:
                guard config.dischargeEnabled else { continue }
                log("Đã xả xong tới \(percent)%")
                config.dischargeEnabled = false
                saveConfig()
            case .topUpEnded(let reason):
                log("Kết thúc sạc đầy một lần (\(reason.rawValue)) ở \(percent)%")
            case .chargeToLimitDone:
                log("Đã sạc tới giới hạn (\(percent)%)")
            }
        }
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
        var errors: [String] = []
        func attempt(_ body: () throws -> Void) {
            do {
                try body()
            } catch {
                errors.append("\(error)")
                log("Ghi SMC thất bại: \(error)")
            }
        }
        // Bật adapter trước khi đổi trạng thái sạc; ngắt adapter sau cùng.
        if adapter, control.adapterKeys != nil, control.isAdapterEnabled != true {
            attempt { try control.setAdapterEnabled(true) }
        }
        if control.chargingKeys != nil, control.isChargingEnabled != charging {
            attempt { try control.setChargingEnabled(charging) }
        }
        if !adapter, control.adapterKeys != nil, control.isAdapterEnabled != false {
            attempt { try control.setAdapterEnabled(false) }
        }
        if !charging, control.chargingKeys == nil, !control.lockedKeys.isEmpty {
            errors.append("Firmware từ chối ghi \(control.lockedKeys.sorted().joined(separator: ", ")) nên không chặn sạc được")
        }
        lastError = errors.isEmpty ? nil : errors.joined(separator: "; ")
        noteCapabilityChanges()
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

    // MARK: Xác minh và kiểm tra

    /// Chặn sạc khi đang cắm mà pin vẫn nhận dòng sạc sau một khoảng thời gian: lệnh không có hiệu lực.
    private func updateEffect(now: Date, acPresent: Bool, battery: BatteryInfo) {
        if acPresent, control.isChargingEnabled == false {
            if inhibitedSince == nil { inhibitedSince = now }
        } else {
            inhibitedSince = nil
        }
        let state = EffectVerifier.evaluate(inhibitedSince: inhibitedSince, now: now,
                                            batteryCurrentmA: control.batteryCurrentmA ?? battery.amperage,
                                            acPresent: acPresent, percent: battery.percent)
        if Self.kind(of: state) != Self.kind(of: effect) {
            switch state {
            case .ineffective(let detail):
                log("CẢNH BÁO: lệnh chặn sạc (\(control.chargingKeys?.rawValue ?? "?")) chưa có hiệu lực: \(detail)")
            case .verified:
                log("Đã xác minh: pin không còn nhận dòng sạc")
            case .pending:
                log("Đang xác minh lệnh chặn sạc")
            case .notApplicable:
                break
            }
        }
        effect = state
    }

    private static func kind(of state: EffectState) -> Int {
        switch state {
        case .notApplicable: 0
        case .pending: 1
        case .verified: 2
        case .ineffective: 3
        }
    }

    /// So giá trị hiện tại của các control key với giá trị helper ghi lần cuối.
    private func auditForeignWrites(now: Date) {
        if let until = auditSuppressedUntil {
            guard now >= until else { return }
            auditSuppressedUntil = nil
        }
        guard !runtime.lastWritten.isEmpty else { return }
        let detected = ForeignWriteDetector.detect(lastWritten: runtime.lastWritten,
                                                   current: currentBytes(of: runtime.lastWritten.keys), now: now)
        for write in detected where reportedForeign[write.key] != write.found {
            log("\(write.key) bị tiến trình khác thay đổi: \(write.expected) -> \(write.found)")
            foreignWrites.append(write)
        }
        if foreignWrites.count > maxForeignWrites {
            foreignWrites.removeFirst(foreignWrites.count - maxForeignWrites)
        }
        // Key đã trở lại đúng giá trị thì lần thay đổi sau được báo lại.
        reportedForeign = Dictionary(detected.map { ($0.key, $0.found) }, uniquingKeysWith: { _, last in last })
    }

    private func currentBytes<S: Sequence>(of keys: S) -> [String: [UInt8]] where S.Element == String {
        var current: [String: [UInt8]] = [:]
        for key in keys {
            if let reading = smc.read(key) { current[key] = reading.bytes }
        }
        return current
    }

    private func finishLoop(now: Date) {
        // Ngay sau khi khởi động hoặc thức dậy: đã ghi lại theo quyết định ở trên, nhận giá trị hiện tại làm mốc.
        if let until = auditSuppressedUntil, now < until {
            runtime.lastWritten.merge(currentBytes(of: runtime.lastWritten.keys)) { _, current in current }
        }
        saveRuntimeIfChanged()
    }

    private var currentCapabilities: Capabilities {
        guard intel != nil else { return control.capabilities }
        return Capabilities(chargeMethod: "BCLM", adapterMethod: nil, keys: control.keys)
    }

    private func noteCapabilityChanges() {
        let caps = control.capabilities
        guard caps != lastCapabilities else { return }
        lastCapabilities = caps
        let locked = control.lockedKeys.sorted().joined(separator: ", ")
        log("Firmware khóa \(locked.isEmpty ? "?" : locked): chuyển sang sạc \(caps.chargeMethod ?? "không có"),"
            + " adapter \(caps.adapterMethod ?? "không có")")
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
            // SMC có thể đã bị reset khi ngủ sâu: không coi là ghi từ bên ngoài, xác minh lại từ đầu.
            auditSuppressedUntil = Date().addingTimeInterval(auditGraceSeconds)
            inhibitedSince = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.evaluate() }
        default:
            break
        }
    }

    private func prepareForSleep() {
        guard intel == nil else { return }  // Intel: firmware tự giữ giới hạn khi ngủ.
        // Không bao giờ để máy ngủ khi adapter đang bị ngắt.
        let state = SleepGate.sleepState(config: config, currentCharging: control.isChargingEnabled,
                                         percent: BatteryReader.read()?.percent,
                                         topUpActive: runtime.controller.topUp != nil)
        log("Chuẩn bị ngủ: adapter bật, sạc \(state.charging ? "bật" : "tắt")")
        applyToHardware(charging: state.charging, adapter: state.adapter)
        updateSleepAssertion(preventSleep: false)
        saveRuntimeIfChanged()
    }

    // MARK: Cấu hình và lệnh

    func update(config newConfig: PowerConfig) {
        suspendedUntil = nil
        let old = config
        config = newConfig.sanitized()
        let startedDischarge = config.dischargeEnabled && !old.dischargeEnabled
        let startedPause = config.pauseCharging && !old.pauseCharging
        if startedDischarge {
            runtime.controller.holdingAtLimit = false
        }
        if runtime.controller.topUp != nil, startedDischarge || startedPause {
            ControllerCommands.cancelTopUp(state: &runtime.controller)
            log("Hủy sạc đầy một lần vì bật \(startedDischarge ? "xả pin" : "tạm dừng sạc")")
        }
        saveConfig()
        evaluate()
        saveRuntimeIfChanged()
    }

    /// Xử lý lệnh từ app (`PowerHelperProtocol.perform`). Luôn đánh giá lại ngay và trả kèm trạng thái mới.
    func handle(_ command: HelperCommand) -> HelperResponse {
        switch command {
        case .setConfig(let newConfig):
            update(config: newConfig)
        case .startTopUp(let hours):
            suspendedUntil = nil
            let acPresent = BatteryReader.read().map { isACPresent($0) } ?? false
            if let error = ControllerCommands.startTopUp(state: &runtime.controller, now: Date(), hours: hours,
                                                         acPresent: acPresent, bootSessionUUID: bootSessionUUID) {
                return HelperResponse(ok: false, error: error, message: Self.message(for: error), status: status())
            }
            log("Bắt đầu sạc đầy một lần, hết hạn lúc \(runtime.controller.topUp.map { "\($0.expiresAt)" } ?? "?")")
            // Sạc đầy thay cho tạm dừng sạc và xả pin.
            if config.pauseCharging || config.dischargeEnabled {
                config.pauseCharging = false
                config.dischargeEnabled = false
                saveConfig()
            }
            evaluate()
        case .cancelTopUp:
            suspendedUntil = nil
            if runtime.controller.topUp != nil { log("Hủy sạc đầy một lần") }
            ControllerCommands.cancelTopUp(state: &runtime.controller)
            evaluate()
        case .chargeToLimitNow:
            suspendedUntil = nil
            log("Sạc tới giới hạn ngay")
            ControllerCommands.chargeToLimitNow(state: &runtime.controller)
            evaluate()
        }
        saveRuntimeIfChanged()
        return HelperResponse(ok: true, message: lastError, status: status())
    }

    private static func message(for error: HelperError) -> String {
        switch error {
        case .notPluggedIn: "Cần cắm sạc để thực hiện lệnh này"
        case .invalidArgument: "Tham số không hợp lệ"
        case .unsupported: "Máy này không hỗ trợ lệnh này"
        case .notAuthorized: "Không có quyền thực hiện lệnh này"
        case .failed: "Helper không thực hiện được lệnh"
        }
    }

    /// - forUninstall false (tắt máy, launchd dừng helper): Apple Silicon trả SMC về mặc định để không
    ///   kẹt ở trạng thái chặn sạc/ngắt adapter; Intel giữ nguyên `BCLM` để firmware tiếp tục giới hạn khi máy tắt.
    /// - forUninstall true: trả mọi thứ về mặc định của macOS, kể cả `BCLM` = 100.
    func restoreDefaults(forUninstall: Bool) {
        updateSleepAssertion(preventSleep: false)
        if !control.restoreDefaults(clearing: Set(runtime.lastWritten.keys)) {
            log("Khôi phục mặc định chưa xác minh được")
        }
        if forUninstall, let intel, !intel.restoreDefaults() {
            log("Không trả được BCLM về 100%")
        }
        if forUninstall {
            suspendedUntil = Date().addingTimeInterval(120)
        }
        inhibitedSince = nil
        saveRuntimeIfChanged()
    }

    /// Helper bị dừng (SIGTERM: tắt máy, gỡ hoặc cài lại): sạc đầy một lần kết thúc, rồi khôi phục như `restoreDefaults`.
    func prepareForExit() {
        if runtime.controller.topUp != nil {
            ControllerCommands.cancelTopUp(state: &runtime.controller)
            log("Kết thúc sạc đầy một lần vì helper dừng")
            // Intel giữ BCLM khi tắt máy: ghi lại mức giới hạn thay vì để 100%.
            if intel != nil { evaluate() }
        }
        restoreDefaults(forUninstall: false)
    }

    func status() -> HelperStatus {
        var status = HelperStatus(version: AppVersion.current,
                                  config: config,
                                  chargingKeys: intel != nil ? "BCLM" : control.chargingKeys?.rawValue,
                                  adapterKeys: control.adapterKeys?.rawValue,
                                  chargingEnabled: control.isChargingEnabled,
                                  adapterEnabled: control.isAdapterEnabled,
                                  reason: lastDecision?.reason ?? .normal,
                                  temperature: lastTemperature,
                                  lastError: lastError,
                                  firmwareLimit: intel?.currentLimit)
        status.capabilities = currentCapabilities
        status.effect = effect
        status.effectiveLimit = lastDecision?.effectiveLimit
        status.topUp = runtime.controller.topUp
        status.chargeToLimitOnce = runtime.controller.chargeToLimitOnce
        status.foreignWrites = foreignWrites
        status.lidClosed = lidClosed
        status.firmware = firmware
        return status
    }

    // MARK: Lưu trữ

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

    /// Nil nếu chưa có file hoặc file hỏng (giải mã từng trường, trường hỏng dùng mặc định).
    static func loadRuntime() -> RuntimeState? {
        guard let data = try? Data(contentsOf: PowerConstants.helperStateURL) else { return nil }
        return try? JSONDecoder().decode(RuntimeState.self, from: data)
    }

    private func saveConfig() {
        do {
            try Self.write(JSONEncoder().encode(config), to: PowerConstants.helperConfigURL)
        } catch {
            log("Không lưu được cấu hình: \(error)")
        }
    }

    /// Chỉ ghi `state.json` khi trạng thái thay đổi.
    private func saveRuntimeIfChanged() {
        guard runtime != savedRuntime else { return }
        do {
            try Self.write(JSONEncoder().encode(runtime), to: PowerConstants.helperStateURL)
            savedRuntime = runtime
            lastSaveError = nil
        } catch {
            let message = "\(error)"
            if message != lastSaveError { log("Không lưu được trạng thái: \(message)") }
            lastSaveError = message
        }
    }

    /// Ghi nguyên tử; thư mục của root 0755, file 0644 (app đọc trạng thái qua XPC, không cần ghi).
    private static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    }
}

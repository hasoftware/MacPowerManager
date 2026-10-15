import AppKit
import Foundation
import Observation
import PowerCore

@MainActor
@Observable
final class AppModel {
    private(set) var battery: BatteryInfo?
    private(set) var smcTemperature: Double?
    /// Sức khỏe pin theo macOS (System Settings → Battery), đọc qua system_profiler.
    private(set) var macOSHealth: MacOSBatteryHealth?
    @ObservationIgnored private var healthFetchedAt: Date?
    /// Ứng dụng điều khiển sạc khác tìm thấy trên máy.
    private(set) var conflicts: [ConflictFinding] = []
    /// Banner "chạy từ vị trí tạm" (đọc lại định kỳ vì người dùng có thể chọn "Không hỏi lại").
    private(set) var needsMove = false
    let helper: HelperClient
    let history: HistoryStore
    /// Nhật ký sức khỏe pin dài hạn (mỗi ngày một điểm).
    let healthLog: HealthStore
    /// Số liệu hệ thống (CPU, bộ nhớ…), chỉ đo khi bảng điều khiển đang mở.
    let system: SystemMonitor
    /// Tiến trình (trang Tiến trình, Năng lượng, các bảng "dùng nhiều nhất").
    let processes: ProcessMonitor
    let notifier = Notifier()
    /// Kiểm tra bản mới trên GitHub (yêu cầu mạng duy nhất của app).
    let updates: UpdateChecker
    /// Tải và cài bản cập nhật ngay trong app.
    let installer = UpdateInstaller()
    var prefs: Preferences {
        didSet {
            guard prefs != oldValue, !isPreview else { return }
            prefs.save()
            if started && prefs.autoCheckUpdates != oldValue.autoCheckUpdates {
                updates.setAutomatic(prefs.autoCheckUpdates)
            }
        }
    }

    // Tần suất đo theo ngữ cảnh (RefreshPolicy): chỉ đo dày khi có giao diện đang hiển thị.
    @ObservationIgnored private var dashboardVisible = false
    @ObservationIgnored private var popoverVisible = false
    /// Màn hình đang bật và phiên đăng nhập không bị khóa.
    @ObservationIgnored private var screenAvailable = true
    @ObservationIgnored private var batteryInterval: TimeInterval = 0
    @ObservationIgnored private var lastOnBattery: Bool?
    @ObservationIgnored private var systemObservers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var started = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observer: PowerSourceObserver?
    @ObservationIgnored private var ticks = 0
    /// Mô hình dữ liệu giả (chụp giao diện): không đọc phần cứng, không ghi file.
    @ObservationIgnored let isPreview: Bool
    @ObservationIgnored private lazy var sensors: ChargingControl? = isPreview ? nil : (try? SMC()).map(ChargingControl.init)

    init() {
        helper = HelperClient()
        history = HistoryStore()
        healthLog = HealthStore()
        system = SystemMonitor()
        processes = ProcessMonitor { [helper] in await helper.processes() }
        prefs = Preferences.load()
        updates = UpdateChecker()
        isPreview = false
        updates.onAnnounce = { [weak self] release, manual in
            guard let self else { return }
            self.notifier.updateAvailable(release, prefs: self.prefs, post: !manual)
        }
    }

    func start() {
        guard !started, !isPreview else { return }
        started = true
        notifier.requestAuthorization()
        UpdateInstaller.removeLeftovers()
        installer.updateHelper = { [helper] path, signature in
            await helper.installUpdate(archivePath: path, signature: signature)
        }
        needsMove = AppMover.needsMove
        refresh()
        scanConflicts()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            AppMover.promptIfNeeded()
            needsMove = AppMover.needsMove
        }
        Task {
            await helper.refresh()
            await promptHelperReinstallAfterUpdate()
        }
        updates.setAutomatic(prefs.autoCheckUpdates)

        observer = BatteryReader.observeChanges { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        observeSystemState()
        applyRefreshPolicy()
    }

    // MARK: Tần suất đo

    func setDashboardVisible(_ visible: Bool) {
        guard visible != dashboardVisible else { return }
        dashboardVisible = visible
        applyRefreshPolicy()
    }

    func setPopoverVisible(_ visible: Bool) {
        guard visible != popoverVisible else { return }
        popoverVisible = visible
        if visible { refresh() }
        applyRefreshPolicy()
    }

    private func context(dashboardOnly: Bool) -> RefreshPolicy.Context {
        let shown = dashboardOnly ? dashboardVisible : (dashboardVisible || popoverVisible)
        return RefreshPolicy.Context(uiVisible: screenAvailable && shown,
                                     onBattery: !(battery?.externalConnected ?? true),
                                     lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    /// Áp dụng `RefreshPolicy` cho các bộ đo và vòng cập nhật pin. Gọi khi cửa sổ/popover hiện hoặc ẩn, màn hình
    /// tắt/khóa, cắm/rút sạc, bật/tắt Low Power Mode.
    func applyRefreshPolicy() {
        guard started, !isPreview else { return }
        let dashboard = context(dashboardOnly: true)
        system.setInterval(RefreshPolicy.systemInterval(dashboard))
        processes.setInterval(RefreshPolicy.processInterval(dashboard, chosen: processes.chosenInterval))
        let interval = RefreshPolicy.batteryInterval(context(dashboardOnly: false))
        guard interval != batteryInterval || timer == nil else { return }
        batteryInterval = interval
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                await self.helper.refresh()
                self.ticks += 1
                // Khoảng 30 giây khi đang xem, vài phút khi không.
                if self.ticks % max(Int(30 / interval), 1) == 0 {
                    self.scanConflicts()
                    self.needsMove = AppMover.needsMove
                }
            }
        }
        timer.tolerance = RefreshPolicy.tolerance(for: interval)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Màn hình tắt/bật, khóa/mở khóa, chuyển người dùng, Low Power Mode.
    private func observeSystemState() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        func on(_ center: NotificationCenter, _ name: Notification.Name, available: Bool?) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let available { self.screenAvailable = available }
                    self.applyRefreshPolicy()
                }
            }
            systemObservers.append((center, token))
        }
        on(workspace, NSWorkspace.screensDidSleepNotification, available: false)
        on(workspace, NSWorkspace.screensDidWakeNotification, available: true)
        on(workspace, NSWorkspace.sessionDidResignActiveNotification, available: false)
        on(workspace, NSWorkspace.sessionDidBecomeActiveNotification, available: true)
        on(distributed, Notification.Name("com.apple.screenIsLocked"), available: false)
        on(distributed, Notification.Name("com.apple.screenIsUnlocked"), available: true)
        on(NotificationCenter.default, .NSProcessInfoPowerStateDidChange, available: nil)
    }

    func refresh() {
        guard !isPreview else { return }
        // IOKit làm mới khoảng mỗi phút; dòng điện từ SMC cho trạng thái sạc tức thì (Apple Silicon).
        battery = BatteryReader.read().map {
            Platform.isAppleSilicon
                ? $0.applyingLiveTelemetry(currentmA: sensors?.batteryCurrentmA, voltagemV: sensors?.batteryVoltagemV)
                : $0
        }
        smcTemperature = sensors?.batteryTemperature
        // Cắm/rút sạc đổi tần suất đo (chạy pin thì đo thưa hơn).
        let onBattery = !(battery?.externalConnected ?? true)
        if onBattery != lastOnBattery {
            lastOnBattery = onBattery
            applyRefreshPolicy()
        }
        refreshMacOSHealthIfNeeded()
        guard let battery else { return }
        history.record(battery: battery, temperature: temperature, limit: summary.limit)
        healthLog.record(battery: battery, macOS: macOSHealth)
        notifier.evaluate(battery: battery, temperature: temperature, helper: helper.status, prefs: prefs,
                          firmwareControlled: isIntelBackend, conflicts: conflicts)
    }

    /// Sức khỏe pin hiển thị: ưu tiên con số của macOS, sau đó ước tính từ dung lượng danh định, cuối cùng là số đo tức thời.
    func healthPercent(_ battery: BatteryInfo) -> Double {
        if let percent = macOSHealth?.maximumCapacityPercent { return Double(percent) }
        return battery.nominalHealth ?? battery.health
    }

    /// Đọc lại sức khỏe theo macOS lúc mở app và mỗi 6 giờ (macOS cũng chỉ cập nhật con số này định kỳ).
    private func refreshMacOSHealthIfNeeded() {
        if let fetched = healthFetchedAt, Date().timeIntervalSince(fetched) < 6 * 3600 { return }
        healthFetchedAt = Date()
        Task {
            let health = await Task.detached(priority: .utility) { () -> MacOSBatteryHealth? in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
                process.arguments = ["SPPowerDataType", "-json"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { return nil }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return MacOSBatteryHealth.parse(data)
            }.value
            if let health { macOSHealth = health } else { healthFetchedAt = nil }
        }
    }

    /// Vừa tự cập nhật xong: bản app mới có cdhash khác nên helper cũ không nhận lệnh; nhắc cài lại helper ngay.
    private func promptHelperReinstallAfterUpdate() async {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: UpdateInstaller.pendingHelperReinstallKey) else { return }
        defaults.removeObject(forKey: UpdateInstaller.pendingHelperReinstallKey)
        guard helper.installState != .installed, helper.installState != .notInstalled || helperPlistExists else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Đã cập nhật lên MacPowerManager \(AppVersion.current)")
        alert.informativeText = String(localized: "Cần cài lại helper để app tiếp tục điều khiển sạc. macOS sẽ hỏi mật khẩu quản trị.")
        alert.addButton(withTitle: String(localized: "Cài lại helper"))
        alert.addButton(withTitle: String(localized: "Để sau"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            await helper.install()
        }
    }

    private var helperPlistExists: Bool {
        FileManager.default.fileExists(atPath: PowerConstants.launchDaemonPath)
    }

    /// Quét ứng dụng điều khiển sạc khác ở luồng nền (đọc file và danh sách tiến trình).
    func scanConflicts() {
        guard !isPreview else { return }
        Task {
            let found = await Task.detached(priority: .utility) { ConflictScanner.scan() }.value
            if found != conflicts { conflicts = found }
        }
    }

    // MARK: Trạng thái suy ra

    /// Máy Intel dùng `BCLM`: firmware tự quyết định ngừng sạc theo phần trăm phần cứng.
    var isIntelBackend: Bool { helper.status?.chargingKeys == "BCLM" }

    /// Máy Intel (theo phần cứng hoặc phương thức helper đang dùng): không có xả pin, khoảng sạc lại, tùy chọn khi ngủ.
    var isIntel: Bool { !Platform.isAppleSilicon || isIntelBackend }

    /// Helper đã cài nhưng máy không có key điều khiển sạc nào dùng được.
    var controlUnsupported: Bool {
        helper.isReady && helper.status?.chargingKeys == nil && helper.status?.capabilities?.chargeMethod == nil
    }

    /// Cấu hình đang được helper thực thi, hoặc nil nếu chưa có helper / máy không hỗ trợ.
    var activeConfig: PowerConfig? {
        helper.isReady && !controlUnsupported ? helper.config : nil
    }

    /// Có điều khiển được sạc hay không (để bật/tắt các điều khiển trong giao diện).
    var canControl: Bool { activeConfig != nil }

    /// Ưu tiên cảm biến SMC (sát thực tế hơn), dự phòng bằng giá trị từ IOKit.
    var temperature: Double? { smcTemperature ?? battery?.temperature }

    var summary: PowerSummary {
        PowerSummary.make(battery: battery, status: helper.status, config: activeConfig,
                          temperature: temperature, lowThreshold: prefs.lowBatteryThreshold, intel: isIntel)
    }

    /// Ứng dụng điều khiển sạc khác đang chạy.
    var runningConflicts: [ConflictFinding] { conflicts.filter(\.running) }

    /// Các key điều khiển bị firmware khóa.
    var lockedKeys: [String] {
        (helper.status?.capabilities?.keys ?? []).filter(\.locked).map(\.name)
    }

    /// Key bị khóa đáng cảnh báo: key chính (CHTE chặn sạc, CHIE ngắt adapter) hoặc khi không còn phương thức nào.
    /// Một key dự phòng bị khóa trong khi key chính vẫn chạy tốt thì không ảnh hưởng gì.
    var relevantLockedKeys: [String] {
        let locked = lockedKeys
        guard !locked.isEmpty else { return [] }
        let capabilities = helper.status?.capabilities
        if capabilities?.chargeMethod == nil || capabilities?.adapterMethod == nil { return locked }
        return locked.filter { $0 == "CHTE" || $0 == "CHIE" }
    }

    var effectIneffective: Bool {
        if case .ineffective = helper.status?.effect { return true }
        return false
    }

    /// Có vấn đề cần người dùng chú ý ở trang Hệ thống & helper.
    var hasSystemIssue: Bool {
        !helper.isReady || !runningConflicts.isEmpty || recentForeignWrite != nil
            || !relevantLockedKeys.isEmpty || controlUnsupported || effectIneffective
    }

    /// Lần ghi từ bên ngoài gần nhất còn đáng cảnh báo (trong `foreignWriteWindow`). Helper giữ lại các lần ghi
    /// cũ để hiển thị ở trang Hệ thống & helper, nhưng banner và huy hiệu chỉ dành cho sự việc vừa xảy ra.
    var recentForeignWrite: ForeignWrite? {
        Self.recentForeignWrite(in: helper.status?.foreignWrites, now: Date())
    }

    /// Banner "có ứng dụng khác ghi vào SMC" chỉ hiện trong 30 phút sau lần ghi gần nhất.
    nonisolated static let foreignWriteWindow: TimeInterval = 30 * 60

    nonisolated static func recentForeignWrite(in writes: [ForeignWrite]?, now: Date) -> ForeignWrite? {
        guard let latest = writes?.max(by: { $0.at < $1.at }) else { return nil }
        return now.timeIntervalSince(latest.at) <= foreignWriteWindow ? latest : nil
    }

    /// Các banner đang áp dụng, theo thứ tự ưu tiên. Giao diện chỉ hiện banner đầu tiên.
    /// Banner an toàn (pin yếu, pin nóng) luôn đứng trên banner mang tính thông tin (key bị khóa, ghi từ bên
    /// ngoài, chuyển app vào Applications) để không bị che mất.
    var banners: [AppBanner] {
        var result: [AppBanner] = []
        switch helper.installState {
        case .notInstalled: result.append(.helperMissing)
        case .outdated(let version): result.append(.helperOutdated(version))
        case .unknown, .installed: break
        }
        if let app = runningConflicts.first {
            result.append(.conflict(app))
        }
        if effectIneffective {
            result.append(.ineffective)
        }
        // An toàn
        if let battery, !battery.externalConnected, battery.percent <= prefs.lowBatteryThreshold {
            result.append(.lowBattery(battery.percent))
        }
        if summary.state == .heat {
            result.append(.heat(temperature, resume: activeConfig?.thermalResumeBelow))
        }
        // Thông tin
        if controlUnsupported {
            result.append(.unsupported)
        } else if !relevantLockedKeys.isEmpty {
            result.append(.locked(relevantLockedKeys, fallback: helper.status?.capabilities?.chargeMethod))
        }
        if runningConflicts.isEmpty, let write = recentForeignWrite {
            result.append(.foreignWrite(write))
        }
        if needsMove { result.append(.moveApp) }
        // Thấp nhất: chỉ là thông tin, không ảnh hưởng tới pin.
        if let release = updates.announcement, let version = release.version {
            result.append(.update(version.description))
        }
        return result
    }

    var banner: AppBanner? { banners.first }

    #if DEBUG
    /// Mô hình với dữ liệu giả cho chế độ chụp giao diện. Không đọc phần cứng, không ghi file hay cài đặt.
    init(preview battery: BatteryInfo?, status: HelperStatus?, installState: HelperClient.InstallState,
         samples: [HistorySample], healthPoints: [HealthPoint] = [], system: SystemMonitor? = nil, processes: [ProcessMonitor.Row] = [], conflicts: [ConflictFinding] = [], temperature: Double? = nil,
         prefs: Preferences = Preferences(), needsMove: Bool = false, update: UpdateChecker.State = .idle) {
        helper = HelperClient()
        updates = UpdateChecker(defaults: nil) { _ in throw URLError(.notConnectedToInternet) }
        updates.setPreview(state: update)
        history = HistoryStore(samples: samples)
        healthLog = HealthStore(points: healthPoints)
        self.system = system ?? SystemMonitor(preview: [], activity: SystemActivity(load1: 0, load5: 0, load15: 0, processCount: 0,
                                                                                   bootTime: nil),
                                              topology: .current)
        self.processes = ProcessMonitor(preview: processes)
        self.prefs = prefs
        isPreview = true
        self.battery = battery
        self.smcTemperature = temperature
        self.conflicts = conflicts
        self.needsMove = needsMove
        helper.setPreview(status: status, installState: installState)
    }
    #endif
}

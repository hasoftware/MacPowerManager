import Foundation
import Observation
import PowerCore

@MainActor
@Observable
final class AppModel {
    private(set) var battery: BatteryInfo?
    private(set) var smcTemperature: Double?
    /// Ứng dụng điều khiển sạc khác tìm thấy trên máy.
    private(set) var conflicts: [ConflictFinding] = []
    /// Banner "chạy từ vị trí tạm" (đọc lại định kỳ vì người dùng có thể chọn "Không hỏi lại").
    private(set) var needsMove = false
    let helper: HelperClient
    let history: HistoryStore
    let notifier = Notifier()
    var prefs: Preferences {
        didSet { if prefs != oldValue && !isPreview { prefs.save() } }
    }

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
        prefs = Preferences.load()
        isPreview = false
    }

    func start() {
        guard !started, !isPreview else { return }
        started = true
        notifier.requestAuthorization()
        needsMove = AppMover.needsMove
        refresh()
        scanConflicts()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            AppMover.promptIfNeeded()
            needsMove = AppMover.needsMove
        }
        Task { await helper.refresh() }

        observer = BatteryReader.observeChanges { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                await self.helper.refresh()
                self.ticks += 1
                if self.ticks % 6 == 0 {
                    self.scanConflicts()
                    self.needsMove = AppMover.needsMove
                }
            }
        }
    }

    func refresh() {
        guard !isPreview else { return }
        battery = BatteryReader.read()
        smcTemperature = sensors?.batteryTemperature
        guard let battery else { return }
        history.record(battery: battery, temperature: temperature, limit: summary.limit)
        notifier.evaluate(battery: battery, temperature: temperature, helper: helper.status, prefs: prefs,
                          firmwareControlled: isIntelBackend, conflicts: conflicts)
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
        !helper.isReady || !runningConflicts.isEmpty || !(helper.status?.foreignWrites ?? []).isEmpty
            || !relevantLockedKeys.isEmpty || controlUnsupported || effectIneffective
    }

    /// Các banner đang áp dụng, theo thứ tự ưu tiên. Giao diện chỉ hiện banner đầu tiên.
    var banners: [AppBanner] {
        var result: [AppBanner] = []
        switch helper.installState {
        case .notInstalled: result.append(.helperMissing)
        case .outdated(let version): result.append(.helperOutdated(version))
        case .unknown, .installed: break
        }
        if let app = runningConflicts.first {
            result.append(.conflict(app))
        } else if let write = helper.status?.foreignWrites?.last {
            result.append(.foreignWrite(write))
        }
        if effectIneffective {
            result.append(.ineffective)
        }
        if controlUnsupported {
            result.append(.unsupported)
        } else if !relevantLockedKeys.isEmpty {
            result.append(.locked(relevantLockedKeys, fallback: helper.status?.capabilities?.chargeMethod))
        }
        if needsMove { result.append(.moveApp) }
        if summary.state == .heat {
            result.append(.heat(temperature, resume: activeConfig?.thermalResumeBelow))
        }
        if let battery, !battery.externalConnected, battery.percent <= prefs.lowBatteryThreshold {
            result.append(.lowBattery(battery.percent))
        }
        return result
    }

    var banner: AppBanner? { banners.first }

    #if DEBUG
    /// Mô hình với dữ liệu giả cho chế độ chụp giao diện. Không đọc phần cứng, không ghi file hay cài đặt.
    init(preview battery: BatteryInfo?, status: HelperStatus?, installState: HelperClient.InstallState,
         samples: [HistorySample], conflicts: [ConflictFinding] = [], temperature: Double? = nil,
         prefs: Preferences = Preferences(), needsMove: Bool = false) {
        helper = HelperClient()
        history = HistoryStore(samples: samples)
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

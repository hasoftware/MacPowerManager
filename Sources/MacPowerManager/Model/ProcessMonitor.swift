import AppKit
import Foundation
import Observation
import PowerCore

/// Danh sách tiến trình cho trang Tiến trình, Năng lượng và các bảng "dùng nhiều nhất". Chỉ đo khi có trang cần và
/// cửa sổ đang hiển thị, theo khoảng người dùng chọn (mặc định 5 giây, xem `RefreshPolicy`). Helper (root) cho danh
/// sách đầy đủ; không có helper thì chỉ thấy tiến trình của người dùng này.
@MainActor
@Observable
final class ProcessMonitor {
    struct Row: Identifiable, Equatable {
        var id: Int32 { pid }
        var pid: Int32
        var name: String
        var user: String
        var isMine: Bool
        var isApp: Bool
        var bundleURL: URL?
        var path: String?
        var cpu: Double
        var power: Double
        var memory: UInt64
        var virtualMemory: UInt64
        var threads: Int32
        /// Giây.
        var cpuTime: Double
        var diskReadRate: Double
        var diskWriteRate: Double
        var diskRead: UInt64
        var diskWritten: UInt64
        var wakeupsPerSecond: Double
        var started: Date?

        var diskRate: Double { diskReadRate + diskWriteRate }
    }

    /// Lịch sử ngắn của từng tiến trình (CPU, bộ nhớ) cho bảng chi tiết.
    struct Point: Equatable {
        var cpu: Double
        var memory: UInt64
    }

    static let historyLength = 60
    private static let chosenIntervalKey = "processes.interval"

    private(set) var rows: [Row] = []
    /// Danh sách gồm cả tiến trình của hệ thống và người dùng khác (lấy từ helper).
    private(set) var includesAllUsers = false
    /// Khoảng làm mới người dùng chọn (2/5/10 giây); khoảng thực tế có thể thưa hơn khi chạy pin.
    var chosenInterval: TimeInterval = UserDefaults.standard.object(forKey: chosenIntervalKey) as? TimeInterval
        ?? RefreshPolicy.defaultProcessInterval {
        didSet { UserDefaults.standard.set(chosenInterval, forKey: Self.chosenIntervalKey) }
    }
    /// Lịch sử CPU/bộ nhớ của từng tiến trình. Không để SwiftUI theo dõi: cập nhật vài trăm mảng mỗi lần đo không
    /// được làm cả bảng vẽ lại (bảng đã vẽ lại theo `rows`).
    @ObservationIgnored private(set) var history: [Int32: [Point]] = [:]

    var totalPower: Double { rows.reduce(0) { $0 + $1.power } }
    var threadCount: Int { rows.reduce(0) { $0 + Int($1.threads) } }

    @ObservationIgnored private let fetchFromHelper: () async -> [ProcessSample]?
    @ObservationIgnored private var consumers = 0
    @ObservationIgnored private var timer: Timer?
    /// Khoảng đo hiện tại; nil = tạm dừng.
    @ObservationIgnored private(set) var interval: TimeInterval? = RefreshPolicy.defaultProcessInterval
    @ObservationIgnored private var previous: (date: Date, samples: [ProcessSample])?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var userNames: [UInt32: String] = [:]
    @ObservationIgnored private var paths: [Int32: (started: Date?, path: String?)] = [:]
    @ObservationIgnored private let isPreview: Bool

    init(fetchFromHelper: @escaping () async -> [ProcessSample]?) {
        self.fetchFromHelper = fetchFromHelper
        isPreview = false
    }

    /// Dữ liệu cố định (chụp giao diện).
    init(preview rows: [Row]) {
        fetchFromHelper = { nil }
        self.rows = rows
        includesAllUsers = true
        isPreview = true
    }

    func retain() {
        consumers += 1
        guard consumers == 1, !isPreview else { return }
        start()
    }

    func release() {
        consumers = max(consumers - 1, 0)
        guard consumers == 0 else { return }
        stop()
    }

    /// Đổi khoảng đo theo `RefreshPolicy` (nil = tạm dừng). Không làm gì nếu không đổi.
    func setInterval(_ value: TimeInterval?) {
        guard value != interval else { return }
        interval = value
        guard consumers > 0, !isPreview else { return }
        stop()
        start()
    }

    private func start() {
        guard let interval, timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = RefreshPolicy.tolerance(for: interval)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        previous = nil
    }

    func top(_ count: Int, by value: (Row) -> Double) -> [Row] {
        Array(rows.filter { value($0) > 0 }.sorted { value($0) > value($1) }.prefix(count))
    }

    // MARK: Đo

    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            defer { refreshing = false }
            let fromHelper = await fetchFromHelper()
            let samples: [ProcessSample]
            if let fromHelper {
                samples = fromHelper
            } else {
                samples = await Task.detached(priority: .utility) { ProcessSampler.sample() }.value
            }
            apply(samples, allUsers: fromHelper != nil, now: Date())
        }
    }

    private func apply(_ samples: [ProcessSample], allUsers: Bool, now: Date) {
        let usages: [ProcessUsage]
        if let previous {
            usages = ProcessUsage.between(previous.samples, samples, elapsed: now.timeIntervalSince(previous.date))
        } else {
            usages = samples.map { ProcessUsage(sample: $0) }
        }
        previous = (now, samples)
        includesAllUsers = allUsers
        let me = getuid()
        let apps = Dictionary(NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) },
                              uniquingKeysWith: { first, _ in first })
        rows = usages.map { usage in
            let s = usage.sample
            let app = apps[s.pid]
            return Row(pid: s.pid, name: app?.localizedName ?? s.name, user: userName(s.uid), isMine: s.uid == me,
                       isApp: app?.activationPolicy == .regular, bundleURL: app?.bundleURL, path: path(of: s),
                       cpu: usage.cpu, power: usage.power, memory: s.resident, virtualMemory: s.virtual, threads: s.threads,
                       cpuTime: Double(s.cpuTime) / 1e9, diskReadRate: usage.diskReadRate, diskWriteRate: usage.diskWriteRate,
                       diskRead: s.diskRead, diskWritten: s.diskWritten, wakeupsPerSecond: usage.wakeupsPerSecond,
                       started: s.started)
        }
        let alive = Set(rows.map(\.pid))
        history = history.filter { alive.contains($0.key) }
        for row in rows {
            var points = history[row.pid] ?? []
            points.append(Point(cpu: row.cpu, memory: row.memory))
            if points.count > Self.historyLength { points.removeFirst(points.count - Self.historyLength) }
            history[row.pid] = points
        }
        paths = paths.filter { alive.contains($0.key) }
    }

    private func userName(_ uid: UInt32) -> String {
        if let name = userNames[uid] { return name }
        let name = getpwuid(uid).map { String(cString: $0.pointee.pw_name) } ?? "\(uid)"
        userNames[uid] = name
        return name
    }

    /// Đường dẫn file thực thi (chỉ đọc được với tiến trình của chính người dùng khi không chạy bằng root).
    private func path(of sample: ProcessSample) -> String? {
        if let cached = paths[sample.pid], cached.started == sample.started { return cached.path }
        var buffer = [CChar](repeating: 0, count: 4096)
        let path = proc_pidpath(sample.pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
        paths[sample.pid] = (sample.started, path)
        return path
    }

    // MARK: Thao tác

    /// Thoát (SIGTERM, hoặc yêu cầu ứng dụng tự thoát) hoặc buộc thoát (SIGKILL). Chỉ với tiến trình của người dùng này.
    @discardableResult
    func quit(_ row: Row, force: Bool) -> Bool {
        guard row.isMine, row.pid != getpid() else { return false }
        if let app = NSRunningApplication(processIdentifier: row.pid) {
            return force ? app.forceTerminate() : app.terminate()
        }
        return kill(row.pid, force ? SIGKILL : SIGTERM) == 0
    }
}

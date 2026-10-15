import Foundation
import Observation
import PowerCore

/// Số liệu hệ thống (CPU, bộ nhớ…) cho các trang Hệ thống. Chỉ đo khi có trang cần và cửa sổ đang thực sự hiển thị
/// (xem `RefreshPolicy`), giữ tối đa 1 giờ trong bộ nhớ. App chăm sóc pin không được tự làm hao pin khi không ai xem.
@MainActor
@Observable
final class SystemMonitor {
    struct Sample: Equatable {
        var date: Date
        var cpu: CPUUsage
        var memory: MemorySnapshot
        /// Trang/giây trong khoảng vừa qua.
        var pageinsPerSecond: Double
        var swapoutsPerSecond: Double
        var cpuTemperature: Double?
        var cpuHottest: Double?
        var gpuTemperature: Double?
        /// Công suất cả máy (W), từ IOKit.
        var systemPower: Double?
        var gpu: GPUSnapshot?
        /// Byte/giây.
        var diskRead: Double = 0
        var diskWrite: Double = 0
        var networkIn: Double = 0
        var networkOut: Double = 0
    }

    enum Range: Int, CaseIterable, Identifiable {
        case minute = 60, fiveMinutes = 300, fifteenMinutes = 900, hour = 3600
        var id: Int { rawValue }
        var seconds: TimeInterval { TimeInterval(rawValue) }
        var title: String {
            switch self {
            case .minute: "1m"
            case .fiveMinutes: "5m"
            case .fifteenMinutes: "15m"
            case .hour: "1h"
            }
        }
    }

    static let capacity = 3600

    private(set) var samples: [Sample] = []
    private(set) var activity = SystemActivity(load1: 0, load5: 0, load15: 0, processCount: 0, bootTime: nil)
    /// Byte đã đọc/ghi từ lúc khởi động (mọi ổ).
    private(set) var diskTotals: DiskCounters?
    /// Byte đã nhận/gửi từ lúc khởi động: mốc từ `netstat`, cộng dồn phần tăng sau đó.
    private(set) var networkTotals: (received: UInt64, sent: UInt64)?
    private(set) var volumes: [VolumeInfo] = []
    private(set) var primaryInterface: NetworkInterfaceInfo?
    var range: Range = .minute
    /// Tạm dừng: giữ nguyên biểu đồ, không đo thêm.
    var paused = false
    let topology: CPUTopology

    var latest: Sample? { samples.last }

    @ObservationIgnored private var consumers = 0
    @ObservationIgnored private var timer: Timer?
    /// Khoảng đo hiện tại; nil = tạm dừng (cửa sổ bị che, thu nhỏ, màn hình tắt…).
    @ObservationIgnored private(set) var interval: TimeInterval? = 1
    @ObservationIgnored private var lastSlowRefresh: Date?
    @ObservationIgnored private var lastTicks: [CPUTicks]?
    @ObservationIgnored private var lastCounters: (date: Date, pageins: UInt64, swapouts: UInt64)?
    @ObservationIgnored private var lastDisk: DiskCounters?
    @ObservationIgnored private var lastNetwork: NetworkCounters?
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private var smc: SMC?
    @ObservationIgnored private var temperatureKeys: [String]?
    @ObservationIgnored private var gpuTemperatureKeys: [String] = []
    @ObservationIgnored private var discoveringKeys = false
    /// Đọc nhiệt độ mỗi 3 giây (khoảng 60 cảm biến), các lần giữa dùng lại giá trị trước.
    @ObservationIgnored private var lastTemperature: (date: Date, value: (average: Double, hottest: Double)?, gpu: Double?)?
    @ObservationIgnored private let isPreview: Bool

    init() {
        topology = .current
        isPreview = false
    }

    /// Dữ liệu cố định (chụp giao diện).
    init(preview samples: [Sample], activity: SystemActivity, topology: CPUTopology, volumes: [VolumeInfo] = [],
         primaryInterface: NetworkInterfaceInfo? = nil, diskTotals: DiskCounters? = nil,
         networkTotals: (received: UInt64, sent: UInt64)? = nil) {
        self.samples = samples
        self.activity = activity
        self.topology = topology
        self.volumes = volumes
        self.primaryInterface = primaryInterface
        self.diskTotals = diskTotals
        self.networkTotals = networkTotals
        isPreview = true
    }

    // MARK: Bật/tắt theo người xem

    func retain() {
        consumers += 1
        guard consumers == 1, !isPreview else { return }
        networkTotals = nil
        Task.detached(priority: .utility) {
            let totals = NetworkCounters.bootTotals()
            await MainActor.run { [weak self] in
                guard let self, let totals else { return }
                self.networkTotals = totals
            }
        }
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
        refreshSlowIfDue(force: true)
        sample()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        timer.tolerance = RefreshPolicy.tolerance(for: interval)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        // Lần đo sau bắt đầu lại từ mốc mới, không tính khoảng nghỉ vào tốc độ.
        lastTicks = nil
        lastCounters = nil
        lastDisk = nil
        lastNetwork = nil
    }

    /// Ổ đĩa và giao diện mạng thay đổi ít: đọc lúc bắt đầu đo và mỗi 30 giây.
    private func refreshSlowIfDue(force: Bool = false) {
        let now = Date()
        if !force, let last = lastSlowRefresh, now.timeIntervalSince(last) < 30 { return }
        lastSlowRefresh = now
        volumes = VolumeInfo.mounted()
        primaryInterface = NetworkInterfaceInfo.primary()
    }

    // MARK: Đo

    private func sample() {
        guard !paused, let ticks = CPUReader.ticks(), let memory = MemoryReader.snapshot() else { return }
        let now = Date()
        let disk = DiskCounters.read()
        let network = NetworkCounters.read()
        defer {
            lastTicks = ticks
            lastCounters = (now, memory.pageins, memory.swapouts)
            lastDisk = disk
            lastNetwork = network
            diskTotals = disk
        }
        guard let previous = lastTicks, let counters = lastCounters else { return }
        let elapsed = max(now.timeIntervalSince(counters.date), 0.001)
        func rate(_ current: UInt64, _ before: UInt64) -> Double { current >= before ? Double(current - before) / elapsed : 0 }
        let temperature: (average: Double, hottest: Double)?
        let gpuTemperature: Double?
        if let last = lastTemperature, now.timeIntervalSince(last.date) < 3 {
            temperature = last.value
            gpuTemperature = last.gpu
        } else {
            temperature = readTemperature()
            gpuTemperature = smc.flatMap { SMCSensors.cpuTemperature($0, keys: gpuTemperatureKeys)?.average }
            lastTemperature = (now, temperature, gpuTemperature)
        }
        let sample = Sample(date: now, cpu: CPUUsage.between(previous, ticks), memory: memory,
                            pageinsPerSecond: rate(memory.pageins, counters.pageins),
                            swapoutsPerSecond: rate(memory.swapouts, counters.swapouts),
                            cpuTemperature: temperature?.average, cpuHottest: temperature?.hottest,
                            gpuTemperature: gpuTemperature,
                            systemPower: BatteryReader.read()?.systemLoad, gpu: GPUReader.snapshot())
        var withIO = sample
        if let lastDisk {
            withIO.diskRead = Double(disk.bytesRead &- min(lastDisk.bytesRead, disk.bytesRead)) / elapsed
            withIO.diskWrite = Double(disk.bytesWritten &- min(lastDisk.bytesWritten, disk.bytesWritten)) / elapsed
        }
        if let lastNetwork {
            let delta = NetworkCounters.delta(from: lastNetwork, to: network)
            withIO.networkIn = Double(delta.received) / elapsed
            withIO.networkOut = Double(delta.sent) / elapsed
            if let totals = networkTotals {
                networkTotals = (totals.received &+ delta.received, totals.sent &+ delta.sent)
            }
        }
        samples.append(withIO)
        self.ticks += 1
        refreshSlowIfDue()
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
        activity = SystemActivity.read()
    }

    /// Nhiệt độ CPU từ SMC. Lần đầu tìm danh sách cảm biến ở luồng nền (liệt kê vài nghìn key mất khoảng 1 giây).
    private func readTemperature() -> (average: Double, hottest: Double)? {
        if let keys = temperatureKeys, let smc { return SMCSensors.cpuTemperature(smc, keys: keys) }
        guard !discoveringKeys else { return nil }
        discoveringKeys = true
        Task.detached(priority: .utility) {
            let smc = try? SMC()
            let all = smc?.allKeys() ?? []
            let keys = smc.map { SMCSensors.cpuTemperatureKeys($0, allKeys: all) } ?? []
            let gpuKeys = smc.map { SMCSensors.gpuTemperatureKeys($0, allKeys: all) } ?? []
            await MainActor.run { [weak self] in
                self?.smc = smc
                self?.temperatureKeys = keys
                self?.gpuTemperatureKeys = gpuKeys
            }
        }
        return nil
    }

    // MARK: Dữ liệu cho biểu đồ

    /// Mẫu trong khoảng đang xem.
    var visibleSamples: [Sample] {
        guard let last = samples.last else { return [] }
        let start = last.date.addingTimeInterval(-range.seconds)
        return samples.filter { $0.date > start }
    }

    /// Chia khoảng đang xem thành `count` cột (cũ → mới), mỗi cột là trung bình các mẫu trong đó.
    /// Cột chưa có dữ liệu (mới mở) là nil. `value` trả về các tầng xếp chồng (0…1).
    func columns(_ count: Int, _ value: (Sample) -> [Double]) -> [[Double]?] {
        guard count > 0, let last = samples.last else { return Array(repeating: nil, count: max(count, 0)) }
        let end = last.date.timeIntervalSinceReferenceDate
        let width = range.seconds / Double(count)
        var sums = [[Double]?](repeating: nil, count: count)
        var counts = [Int](repeating: 0, count: count)
        for sample in samples.reversed() {
            let age = end - sample.date.timeIntervalSinceReferenceDate
            guard age < range.seconds else { break }
            let index = count - 1 - min(Int(age / width), count - 1)
            let v = value(sample)
            sums[index] = sums[index].map { zip($0, v).map(+) } ?? v
            counts[index] += 1
        }
        return zip(sums, counts).map { sum, n in sum.map { $0.map { $0 / Double(n) } } }
    }

    /// Trung bình và cao nhất của một giá trị trong khoảng đang xem.
    func stats(_ value: (Sample) -> Double) -> (average: Double, peak: Double)? {
        let values = visibleSamples.map(value)
        guard let peak = values.max() else { return nil }
        return (values.reduce(0, +) / Double(values.count), peak)
    }
}

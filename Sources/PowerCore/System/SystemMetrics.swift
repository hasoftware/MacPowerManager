import Darwin
import Foundation

// Số liệu hệ thống (CPU, bộ nhớ, tải) đọc bằng API công khai của Mach/sysctl, không cần quyền root.
// Phần tính toán tách thành hàm thuần để kiểm thử.

// MARK: - CPU

/// Số tick tích lũy của một nhân từ lúc khởi động.
public struct CPUTicks: Equatable, Sendable {
    public var user: UInt64
    public var system: UInt64
    public var idle: UInt64
    public var nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

/// Mức dùng CPU trong một khoảng (0…1).
public struct CPUUsage: Equatable, Sendable {
    public var user: Double
    public var system: Double
    public var perCore: [Double]
    public var total: Double { user + system }

    public static let zero = CPUUsage(user: 0, system: 0, perCore: [])

    public init(user: Double, system: Double, perCore: [Double]) {
        self.user = user
        self.system = system
        self.perCore = perCore
    }

    /// Từ hai lần đọc tick. Bộ đếm bị đặt lại hoặc số nhân thay đổi thì bỏ qua nhân đó (coi như 0).
    public static func between(_ previous: [CPUTicks], _ current: [CPUTicks]) -> CPUUsage {
        guard previous.count == current.count, !current.isEmpty else { return .zero }
        var user = 0.0, system = 0.0, all = 0.0
        var perCore: [Double] = []
        for (p, c) in zip(previous, current) {
            guard c.user >= p.user, c.system >= p.system, c.idle >= p.idle, c.nice >= p.nice else {
                perCore.append(0)
                continue
            }
            let u = Double(c.user - p.user + c.nice - p.nice), s = Double(c.system - p.system)
            let total = u + s + Double(c.idle - p.idle)
            perCore.append(total > 0 ? min((u + s) / total, 1) : 0)
            user += u
            system += s
            all += total
        }
        guard all > 0 else { return CPUUsage(user: 0, system: 0, perCore: perCore) }
        return CPUUsage(user: user / all, system: system / all, perCore: perCore)
    }
}

public enum CPUReader {
    /// Tick của từng nhân logic.
    public static func ticks() -> [CPUTicks]? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let states = Int(CPU_STATE_MAX)
        return (0..<Int(count)).map { core in
            func tick(_ state: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[core * states + Int(state)])) }
            return CPUTicks(user: tick(CPU_STATE_USER), system: tick(CPU_STATE_SYSTEM),
                            idle: tick(CPU_STATE_IDLE), nice: tick(CPU_STATE_NICE))
        }
    }
}

/// Cấu trúc chip: số nhân hiệu năng / tiết kiệm điện, tên chip.
public struct CPUTopology: Equatable, Sendable {
    public var brand: String
    public var logicalCores: Int
    /// Nhân hiệu năng (perflevel0) và tiết kiệm điện (perflevel1). Intel: tất cả là nhân hiệu năng.
    public var performanceCores: Int
    public var efficiencyCores: Int
    public var performanceName: String?

    public init(brand: String, logicalCores: Int, performanceCores: Int, efficiencyCores: Int, performanceName: String? = nil) {
        self.brand = brand
        self.logicalCores = logicalCores
        self.performanceCores = performanceCores
        self.efficiencyCores = efficiencyCores
        self.performanceName = performanceName
    }

    public static let current: CPUTopology = {
        let logical = Sysctl.int("hw.logicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount
        let levels = Sysctl.int("hw.nperflevels") ?? 1
        let p = levels > 1 ? Sysctl.int("hw.perflevel0.logicalcpu") ?? logical : logical
        let e = levels > 1 ? Sysctl.int("hw.perflevel1.logicalcpu") ?? 0 : 0
        return CPUTopology(brand: Sysctl.string("machdep.cpu.brand_string") ?? "CPU", logicalCores: logical,
                           performanceCores: p, efficiencyCores: e,
                           performanceName: levels > 1 ? Sysctl.string("hw.perflevel0.name") : nil)
    }()

    /// Apple Silicon đánh số nhân tiết kiệm điện trước (0 … e-1), rồi tới nhân hiệu năng.
    public func isEfficiency(core index: Int) -> Bool { index < efficiencyCores }
}

// MARK: - Bộ nhớ

/// Bộ nhớ theo cách Activity Monitor hiển thị (byte).
public struct MemorySnapshot: Equatable, Sendable {
    public var total: UInt64
    public var app: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    /// File được cache (có thể giải phóng ngay).
    public var cached: UInt64
    public var free: UInt64
    public var swapUsed: UInt64
    public var swapTotal: UInt64
    /// Bộ đếm tích lũy (trang), để tính tốc độ.
    public var pageins: UInt64
    public var swapouts: UInt64
    /// 1 bình thường, 2 cảnh báo, 4 nghiêm trọng (`kern.memorystatus_vm_pressure_level`).
    public var pressureLevel: Int
    /// Áp lực bộ nhớ 0…100 (100 - `kern.memorystatus_level`).
    public var pressurePercent: Int?

    public var used: UInt64 { app + wired + compressed }

    public init(total: UInt64, app: UInt64, wired: UInt64, compressed: UInt64, cached: UInt64, free: UInt64,
                swapUsed: UInt64 = 0, swapTotal: UInt64 = 0, pageins: UInt64 = 0, swapouts: UInt64 = 0,
                pressureLevel: Int = 1, pressurePercent: Int? = nil) {
        self.total = total
        self.app = app
        self.wired = wired
        self.compressed = compressed
        self.cached = cached
        self.free = free
        self.swapUsed = swapUsed
        self.swapTotal = swapTotal
        self.pageins = pageins
        self.swapouts = swapouts
        self.pressureLevel = pressureLevel
        self.pressurePercent = pressurePercent
    }

    /// Đếm trang của `vm_statistics64` → các nhóm như Activity Monitor:
    /// đã dùng = active + inactive + speculative + wired + compressed − purgeable − file cache;
    /// App = đã dùng − wired − compressed; Cache = purgeable + file cache.
    public static func from(pageSize: UInt64, total: UInt64, active: UInt64, inactive: UInt64, speculative: UInt64,
                            wired: UInt64, compressed: UInt64, purgeable: UInt64, external: UInt64) -> MemorySnapshot {
        let page = pageSize
        let usedPages = active + inactive + speculative + wired + compressed
        let reclaimable = min(purgeable + external, usedPages)
        let used = (usedPages - reclaimable) * page
        let wiredBytes = wired * page, compressedBytes = compressed * page
        let app = used > wiredBytes + compressedBytes ? used - wiredBytes - compressedBytes : 0
        let cached = (purgeable + external) * page
        let free = total > used + cached ? total - used - cached : 0
        return MemorySnapshot(total: total, app: app, wired: wiredBytes, compressed: compressedBytes, cached: cached, free: free)
    }
}

public enum MemoryReader {
    public static func snapshot() -> MemorySnapshot? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var snapshot = MemorySnapshot.from(
            pageSize: UInt64(vm_kernel_page_size), total: ProcessInfo.processInfo.physicalMemory,
            active: UInt64(stats.active_count), inactive: UInt64(stats.inactive_count),
            speculative: UInt64(stats.speculative_count), wired: UInt64(stats.wire_count),
            compressed: UInt64(stats.compressor_page_count), purgeable: UInt64(stats.purgeable_count),
            external: UInt64(stats.external_page_count))
        snapshot.pageins = stats.pageins
        snapshot.swapouts = stats.swapouts
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            snapshot.swapUsed = swap.xsu_used
            snapshot.swapTotal = swap.xsu_total
        }
        snapshot.pressureLevel = Sysctl.int("kern.memorystatus_vm_pressure_level") ?? 1
        snapshot.pressurePercent = Sysctl.int("kern.memorystatus_level").map { min(max(100 - $0, 0), 100) }
        return snapshot
    }
}

// MARK: - Tải hệ thống

public struct SystemActivity: Equatable, Sendable {
    public var load1: Double
    public var load5: Double
    public var load15: Double
    public var processCount: Int
    public var bootTime: Date?

    public init(load1: Double, load5: Double, load15: Double, processCount: Int, bootTime: Date?) {
        self.load1 = load1
        self.load5 = load5
        self.load15 = load15
        self.processCount = processCount
        self.bootTime = bootTime
    }

    public static func read() -> SystemActivity {
        var loads = [Double](repeating: 0, count: 3)
        _ = getloadavg(&loads, 3)
        let pids = proc_listallpids(nil, 0)
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        let bootTime = sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0
            ? Date(timeIntervalSince1970: Double(boot.tv_sec) + Double(boot.tv_usec) / 1_000_000) : nil
        return SystemActivity(load1: loads[0], load5: loads[1], load15: loads[2], processCount: max(Int(pids), 0),
                              bootTime: bootTime)
    }
}

// MARK: - sysctl

public enum Sysctl {
    public static func int(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        // Một số khóa là int32: chỉ 4 byte đầu được ghi.
        return size == 4 ? Int(Int32(truncatingIfNeeded: value)) : Int(value)
    }

    public static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

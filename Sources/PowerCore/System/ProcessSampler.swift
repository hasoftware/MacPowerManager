import Darwin
import Foundation

/// Một lần đọc của một tiến trình (bộ đếm tích lũy). App đọc được tiến trình của chính người dùng; helper (root) đọc
/// được tất cả và gửi qua XPC (`HelperCommand.processes`).
public struct ProcessSample: Codable, Equatable, Sendable {
    public var pid: Int32
    public var uid: UInt32
    public var name: String
    /// Thời gian CPU (người dùng + hệ thống), nano giây.
    public var cpuTime: UInt64
    public var resident: UInt64
    public var virtual: UInt64
    public var threads: Int32
    /// Năng lượng tích lũy (nano jun), 0 nếu hệ thống không cung cấp.
    public var energy: UInt64
    public var diskRead: UInt64
    public var diskWritten: UInt64
    /// Lần đánh thức CPU (ngắt + thoát trạng thái nghỉ).
    public var wakeups: UInt64
    public var started: Date?

    public init(pid: Int32, uid: UInt32, name: String, cpuTime: UInt64, resident: UInt64, virtual: UInt64 = 0,
                threads: Int32, energy: UInt64 = 0, diskRead: UInt64 = 0, diskWritten: UInt64 = 0, wakeups: UInt64 = 0,
                started: Date? = nil) {
        self.pid = pid
        self.uid = uid
        self.name = name
        self.cpuTime = cpuTime
        self.resident = resident
        self.virtual = virtual
        self.threads = threads
        self.energy = energy
        self.diskRead = diskRead
        self.diskWritten = diskWritten
        self.wakeups = wakeups
        self.started = started
    }
}

/// Mức dùng của một tiến trình trong khoảng giữa hai lần đọc.
public struct ProcessUsage: Equatable, Sendable {
    public var sample: ProcessSample
    /// 1 = một nhân dùng hết (như Activity Monitor: có thể vượt 100%).
    public var cpu: Double
    /// W
    public var power: Double
    /// Byte/giây
    public var diskReadRate: Double
    public var diskWriteRate: Double
    public var wakeupsPerSecond: Double

    public init(sample: ProcessSample, cpu: Double = 0, power: Double = 0, diskReadRate: Double = 0,
                diskWriteRate: Double = 0, wakeupsPerSecond: Double = 0) {
        self.sample = sample
        self.cpu = cpu
        self.power = power
        self.diskReadRate = diskReadRate
        self.diskWriteRate = diskWriteRate
        self.wakeupsPerSecond = wakeupsPerSecond
    }

    /// Ghép hai lần đọc theo PID. Tiến trình mới (hoặc PID bị dùng lại, bộ đếm giảm) thì mức dùng là 0 ở lần này.
    public static func between(_ previous: [ProcessSample], _ current: [ProcessSample], elapsed: TimeInterval) -> [ProcessUsage] {
        let seconds = max(elapsed, 0.001)
        let old = Dictionary(previous.map { ($0.pid, $0) }, uniquingKeysWith: { _, last in last })
        return current.map { now in
            guard let before = old[now.pid], before.started == now.started, now.cpuTime >= before.cpuTime else {
                return ProcessUsage(sample: now)
            }
            func rate(_ a: UInt64, _ b: UInt64) -> Double { b >= a ? Double(b - a) / seconds : 0 }
            return ProcessUsage(sample: now, cpu: rate(before.cpuTime, now.cpuTime) / 1e9,
                                power: rate(before.energy, now.energy) / 1e9,
                                diskReadRate: rate(before.diskRead, now.diskRead),
                                diskWriteRate: rate(before.diskWritten, now.diskWritten),
                                wakeupsPerSecond: rate(before.wakeups, now.wakeups))
        }
    }
}

public enum ProcessSampler {
    /// Đọc mọi tiến trình truy cập được (người dùng thường: của chính mình; root: tất cả).
    public static func sample() -> [ProcessSample] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let numer = UInt64(max(timebase.numer, 1)), denom = UInt64(max(timebase.denom, 1))
        func nanoseconds(_ ticks: UInt64) -> UInt64 { ticks.multipliedReportingOverflow(by: numer).partialValue / denom }

        return pids.prefix(Int(count)).compactMap { pid -> ProcessSample? in
            guard pid > 0 else { return nil }
            var info = proc_taskallinfo()
            guard proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, Int32(MemoryLayout<proc_taskallinfo>.size)) > 0 else {
                return nil
            }
            let bsd = info.pbsd, task = info.ptinfo
            var usage = rusage_info_v6()
            let hasUsage = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
            } == 0
            let name = withUnsafeBytes(of: bsd.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let comm = withUnsafeBytes(of: bsd.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let started = bsd.pbi_start_tvsec > 0
                ? Date(timeIntervalSince1970: Double(bsd.pbi_start_tvsec) + Double(bsd.pbi_start_tvusec) / 1e6) : nil
            return ProcessSample(pid: pid, uid: bsd.pbi_uid, name: name.isEmpty ? comm : name,
                                 cpuTime: nanoseconds(task.pti_total_user &+ task.pti_total_system),
                                 resident: hasUsage ? usage.ri_phys_footprint : task.pti_resident_size,
                                 virtual: task.pti_virtual_size, threads: task.pti_threadnum,
                                 energy: hasUsage ? usage.ri_energy_nj : 0,
                                 diskRead: hasUsage ? usage.ri_diskio_bytesread : 0,
                                 diskWritten: hasUsage ? usage.ri_diskio_byteswritten : 0,
                                 wakeups: hasUsage ? usage.ri_interrupt_wkups &+ usage.ri_pkg_idle_wkups : 0,
                                 started: started)
        }
    }
}

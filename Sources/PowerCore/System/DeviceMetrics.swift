import Darwin
import Foundation
import IOKit
import SystemConfiguration

// GPU, ổ đĩa, mạng: đọc từ IORegistry, sysctl và SystemConfiguration (không cần quyền root).

// MARK: - GPU

public struct GPUSnapshot: Equatable, Sendable {
    public var model: String
    public var cores: Int?
    /// 0…1
    public var device: Double
    public var renderer: Double
    public var tiler: Double
    /// Byte bộ nhớ GPU đang dùng và đã cấp phát (bộ nhớ hợp nhất).
    public var memoryInUse: UInt64
    public var memoryAllocated: UInt64

    public init(model: String, cores: Int?, device: Double, renderer: Double, tiler: Double,
                memoryInUse: UInt64, memoryAllocated: UInt64) {
        self.model = model
        self.cores = cores
        self.device = device
        self.renderer = renderer
        self.tiler = tiler
        self.memoryInUse = memoryInUse
        self.memoryAllocated = memoryAllocated
    }

    /// Từ thuộc tính của service IOAccelerator ("PerformanceStatistics", "model", "gpu-core-count").
    public static func from(properties: [String: Any]) -> GPUSnapshot? {
        guard let stats = properties["PerformanceStatistics"] as? [String: Any] else { return nil }
        func percent(_ key: String) -> Double { min(max(((stats[key] as? NSNumber)?.doubleValue ?? 0) / 100, 0), 1) }
        func bytes(_ key: String) -> UInt64 { (stats[key] as? NSNumber)?.uint64Value ?? 0 }
        let model = (properties["model"] as? String)
            ?? (properties["model"] as? Data).map { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            ?? "GPU"
        return GPUSnapshot(model: model, cores: (properties["gpu-core-count"] as? NSNumber)?.intValue,
                           device: percent("Device Utilization %"), renderer: percent("Renderer Utilization %"),
                           tiler: percent("Tiler Utilization %"), memoryInUse: bytes("In use system memory"),
                           memoryAllocated: bytes("Alloc system memory"))
    }
}

public enum GPUReader {
    /// GPU đầu tiên có số liệu hiệu năng (Apple Silicon chỉ có một).
    public static func snapshot() -> GPUSnapshot? {
        IORegistry.services(matching: "IOAccelerator").lazy.compactMap(GPUSnapshot.from(properties:)).first
    }
}

// MARK: - Ổ đĩa

/// Byte đã đọc/ghi từ lúc khởi động, cộng mọi ổ (IOBlockStorageDriver "Statistics").
public struct DiskCounters: Equatable, Sendable {
    public var bytesRead: UInt64
    public var bytesWritten: UInt64

    public init(bytesRead: UInt64, bytesWritten: UInt64) {
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
    }

    public static func read() -> DiskCounters {
        var total = DiskCounters(bytesRead: 0, bytesWritten: 0)
        for properties in IORegistry.services(matching: "IOBlockStorageDriver") {
            guard let stats = properties["Statistics"] as? [String: Any] else { continue }
            total.bytesRead &+= (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            total.bytesWritten &+= (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return total
    }
}

public struct VolumeInfo: Equatable, Identifiable, Sendable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var format: String?
    public var device: String?
    public var total: UInt64
    public var available: UInt64
    public var isInternal: Bool
    public var used: UInt64 { total > available ? total - available : 0 }

    public init(name: String, path: String, format: String?, device: String?, total: UInt64, available: UInt64, isInternal: Bool) {
        self.name = name
        self.path = path
        self.format = format
        self.device = device
        self.total = total
        self.available = available
        self.isInternal = isInternal
    }

    /// Ổ đĩa cục bộ đang gắn (ổ hệ thống và ổ ngoài), bỏ ổ ẩn và phân vùng hệ thống.
    public static func mounted() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeLocalizedFormatDescriptionKey, .volumeTotalCapacityKey,
                                      .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
                                      .volumeIsLocalKey, .volumeIsBrowsableKey, .volumeIsInternalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsLocal == true, v.volumeIsBrowsable == true,
                  let total = v.volumeTotalCapacity, total > 0 else { return nil }
            let available = v.volumeAvailableCapacityForImportantUsage.map { UInt64(max($0, 0)) }
                ?? UInt64(max(v.volumeAvailableCapacity ?? 0, 0))
            var fs = statfs()
            let device = statfs(url.path, &fs) == 0
                ? withUnsafeBytes(of: fs.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } : nil
            return VolumeInfo(name: v.volumeName ?? url.lastPathComponent, path: url.path,
                              format: v.volumeLocalizedFormatDescription,
                              device: device.map { $0.replacingOccurrences(of: "/dev/", with: "") },
                              total: UInt64(total), available: min(available, UInt64(total)),
                              isInternal: v.volumeIsInternal ?? (url.path == "/"))
        }
        .sorted { ($0.path == "/" ? 0 : 1, $0.name) < ($1.path == "/" ? 0 : 1, $1.name) }
    }
}

// MARK: - Mạng

/// Byte nhận/gửi theo từng giao diện mạng (`NET_RT_IFLIST2`). Kernel trả về bộ đếm đã cắt còn 32 bit (quay vòng mỗi
/// 4 GB), nên chỉ dùng để tính tốc độ qua `delta`; tổng từ lúc khởi động lấy từ `netstat` (xem `bootTotals`).
public struct NetworkCounters: Equatable, Sendable {
    public var received: [String: UInt64]
    public var sent: [String: UInt64]

    public init(received: [String: UInt64], sent: [String: UInt64]) {
        self.received = received
        self.sent = sent
    }


    /// Byte nhận/gửi giữa hai lần đọc, cộng các giao diện (bỏ loopback), tính cả khi bộ đếm quay vòng 32 bit.
    /// Giao diện mới xuất hiện hoặc bộ đếm bị đặt lại thì không tính lần này.
    public static func delta(from previous: NetworkCounters, to current: NetworkCounters) -> (received: UInt64, sent: UInt64) {
        func sum(_ old: [String: UInt64], _ new: [String: UInt64]) -> UInt64 {
            new.reduce(0) { total, item in
                guard !item.key.hasPrefix("lo"), let before = old[item.key] else { return total }
                return total &+ wrapped(before, item.value)
            }
        }
        return (sum(previous.received, current.received), sum(previous.sent, current.sent))
    }

    static func wrapped(_ before: UInt64, _ after: UInt64) -> UInt64 {
        if after >= before { return after - before }
        // Quay vòng 32 bit (giá trị cũ còn trong phạm vi 32 bit); trường hợp khác coi như đặt lại.
        return before <= UInt64(UInt32.max) ? (UInt64(UInt32.max) - before) + after + 1 : 0
    }

    /// Tổng byte nhận/gửi từ lúc khởi động (mọi giao diện trừ loopback), từ dòng `<Link#…>` của `netstat -ibn`.
    public static func parseNetstat(_ output: String) -> (received: UInt64, sent: UInt64)? {
        var received: UInt64 = 0, sent: UInt64 = 0, found = false
        for line in output.split(separator: "\n") where line.contains("<Link#") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 7, !fields[0].hasPrefix("lo"),
                  let rx = UInt64(fields[fields.count - 5]), let tx = UInt64(fields[fields.count - 2]) else { continue }
            received &+= rx
            sent &+= tx
            found = true
        }
        return found ? (received, sent) : nil
    }

    /// Chạy `netstat -ibn` (khoảng 10 ms). Gọi ở luồng nền.
    public static func bootTotals() -> (received: UInt64, sent: UInt64)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        process.arguments = ["-ibn"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseNetstat(String(decoding: data, as: UTF8.self))
    }

    public static func read() -> NetworkCounters {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return NetworkCounters(received: [:], sent: [:]) }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return NetworkCounters(received: [:], sent: [:]) }
        var received: [String: UInt64] = [:], sent: [String: UInt64] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                    if if_indextoname(UInt32(info.ifm_index), &name) != nil {
                        let key = String(cString: name)
                        received[key] = info.ifm_data.ifi_ibytes
                        sent[key] = info.ifm_data.ifi_obytes
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return NetworkCounters(received: received, sent: sent)
    }
}

public struct NetworkInterfaceInfo: Equatable, Sendable {
    public var bsdName: String
    /// "Wi-Fi", "Ethernet"…
    public var displayName: String
    public var ipv4: String?
    public var ipv6: String?
    public var hardwareAddress: String?

    /// Giao diện mạng chính (đang dùng để ra Internet), nil nếu đang mất mạng.
    public static func primary() -> NetworkInterfaceInfo? {
        guard let store = SCDynamicStoreCreate(nil, "MacPowerManager" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let bsd = global["PrimaryInterface"] as? String else { return nil }
        let display = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface])?
            .first { SCNetworkInterfaceGetBSDName($0) as String? == bsd }
            .flatMap { SCNetworkInterfaceGetLocalizedDisplayName($0) as String? } ?? bsd
        var info = NetworkInterfaceInfo(bsdName: bsd, displayName: display)
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return info }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard String(cString: entry.ifa_name) == bsd, let address = entry.ifa_addr else { continue }
            switch Int32(address.pointee.sa_family) {
            case AF_INET where info.ipv4 == nil:
                info.ipv4 = numericHost(address)
            case AF_INET6:
                // Ưu tiên địa chỉ toàn cục, không thì dùng link-local.
                if let host = numericHost(address), info.ipv6 == nil || info.ipv6?.hasPrefix("fe80") == true {
                    info.ipv6 = host.components(separatedBy: "%").first
                }
            case AF_LINK:
                address.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { link in
                    let dl = link.pointee
                    guard dl.sdl_alen == 6 else { return }
                    let bytes = withUnsafeBytes(of: dl.sdl_data) { Array($0.dropFirst(Int(dl.sdl_nlen)).prefix(6)) }
                    info.hardwareAddress = bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
                }
            default:
                break
            }
        }
        return info
    }

    public init(bsdName: String, displayName: String, ipv4: String? = nil, ipv6: String? = nil, hardwareAddress: String? = nil) {
        self.bsdName = bsdName
        self.displayName = displayName
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.hardwareAddress = hardwareAddress
    }

    private static func numericHost(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
            return nil
        }
        return String(cString: host)
    }
}

// MARK: - IORegistry

enum IORegistry {
    /// Thuộc tính của mọi service khớp tên lớp.
    static func services(matching className: String) -> [[String: Any]] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var result: [[String: Any]] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = properties?.takeRetainedValue() as? [String: Any] {
                result.append(dict)
            }
        }
        return result
    }
}

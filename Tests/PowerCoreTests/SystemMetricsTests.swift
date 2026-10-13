import XCTest
@testable import PowerCore

final class SystemMetricsTests: XCTestCase {
    func testCPUUsageFromTicks() {
        let a = [CPUTicks(user: 100, system: 50, idle: 850, nice: 0), CPUTicks(user: 0, system: 0, idle: 1000, nice: 0)]
        let b = [CPUTicks(user: 160, system: 70, idle: 870, nice: 0), CPUTicks(user: 0, system: 0, idle: 1100, nice: 0)]
        let usage = CPUUsage.between(a, b)
        XCTAssertEqual(usage.perCore[0], 0.8, accuracy: 1e-9)   // 80 bận / 100
        XCTAssertEqual(usage.perCore[1], 0)
        XCTAssertEqual(usage.user, 60.0 / 200, accuracy: 1e-9)
        XCTAssertEqual(usage.system, 20.0 / 200, accuracy: 1e-9)
        XCTAssertEqual(usage.total, 0.4, accuracy: 1e-9)
        // Bộ đếm bị đặt lại hoặc số nhân đổi: không ra số âm hay lỗi.
        XCTAssertEqual(CPUUsage.between(b, a).perCore, [0, 0])
        XCTAssertEqual(CPUUsage.between(a, Array(b.prefix(1))), .zero)
    }

    func testMemoryGroupsLikeActivityMonitor() {
        let page: UInt64 = 16_384
        let m = MemorySnapshot.from(pageSize: page, total: 16 << 30, active: 300_000, inactive: 250_000, speculative: 20_000,
                                    wired: 150_000, compressed: 100_000, purgeable: 10_000, external: 200_000)
        XCTAssertEqual(m.wired, 150_000 * page)
        XCTAssertEqual(m.compressed, 100_000 * page)
        XCTAssertEqual(m.app, (820_000 - 210_000 - 250_000) * page)
        XCTAssertEqual(m.cached, 210_000 * page)
        XCTAssertEqual(m.used + m.cached + m.free, 16 << 30)
    }

    func testLiveReadersArePlausible() throws {
        let first = try XCTUnwrap(CPUReader.ticks())
        XCTAssertEqual(first.count, CPUTopology.current.logicalCores)
        Thread.sleep(forTimeInterval: 0.2)
        let usage = CPUUsage.between(first, try XCTUnwrap(CPUReader.ticks()))
        XCTAssert((0...1).contains(usage.total))
        let topo = CPUTopology.current
        XCTAssertEqual(topo.performanceCores + topo.efficiencyCores, topo.logicalCores)
        let mem = try XCTUnwrap(MemoryReader.snapshot())
        XCTAssertEqual(mem.total, ProcessInfo.processInfo.physicalMemory)
        XCTAssertLessThanOrEqual(mem.used, mem.total)
        XCTAssert([1, 2, 4].contains(mem.pressureLevel))
        let activity = SystemActivity.read()
        XCTAssertGreaterThan(activity.processCount, 10)
        XCTAssertNotNil(activity.bootTime)
        print("LIVE: \(topo.brand) \(topo.performanceCores)P+\(topo.efficiencyCores)E cpu=\(Int(usage.total * 100))%"
              + " app=\(mem.app >> 20)MB wired=\(mem.wired >> 20)MB compressed=\(mem.compressed >> 20)MB"
              + " cached=\(mem.cached >> 20)MB free=\(mem.free >> 20)MB swap=\(mem.swapUsed >> 20)/\(mem.swapTotal >> 20)MB"
              + " pressure=\(mem.pressureLevel)/\(mem.pressurePercent ?? -1)% load=\(activity.load1) procs=\(activity.processCount)")
    }
}

final class DeviceMetricsTests: XCTestCase {
    func testGPUFromProperties() throws {
        let gpu = try XCTUnwrap(GPUSnapshot.from(properties: [
            "model": "Apple M2 Pro", "gpu-core-count": 19,
            "PerformanceStatistics": ["Device Utilization %": 8, "Renderer Utilization %": 32, "Tiler Utilization %": 25,
                                      "In use system memory": 1_110_000_000, "Alloc system memory": 5_600_000_000],
        ]))
        XCTAssertEqual(gpu.model, "Apple M2 Pro")
        XCTAssertEqual(gpu.cores, 19)
        XCTAssertEqual(gpu.device, 0.08, accuracy: 1e-9)
        XCTAssertEqual(gpu.renderer, 0.32, accuracy: 1e-9)
        XCTAssertEqual(gpu.memoryAllocated, 5_600_000_000)
        XCTAssertNil(GPUSnapshot.from(properties: ["model": "x"]))
    }

    func testNetworkDeltaHandlesWrapAndNewInterfaces() {
        let a = NetworkCounters(received: ["en0": 4_294_967_000, "lo0": 5], sent: ["en0": 100])
        let b = NetworkCounters(received: ["en0": 200, "lo0": 900, "en5": 10_000], sent: ["en0": 600])
        let d = NetworkCounters.delta(from: a, to: b)
        XCTAssertEqual(d.received, 296 + 200, "Quay vòng 32 bit; bỏ loopback và giao diện mới")
        XCTAssertEqual(d.sent, 500)
        let netstat = """
        Name       Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll
        lo0        16384 <Link#1>                        2416     0     532322     2416     0     532322     0
        en0        1500  <Link#11>   ca:22:94:75:6b:e7 99999     0 30156610127 88888     0 7424599521     0
        en0        1500  192.168.1     192.168.1.35     1     -       1     1     -       1     -
        utun0      1380  <Link#20>                          1     0         64        2     0        128     0
        """
        let totals = NetworkCounters.parseNetstat(netstat)
        XCTAssertEqual(totals?.received, 30_156_610_127 + 64)
        XCTAssertEqual(totals?.sent, 7_424_599_521 + 128)
    }

    func testLiveReaders() {
        let gpu = GPUReader.snapshot()
        let disk = DiskCounters.read()
        let net = NetworkCounters.read()
        let volumes = VolumeInfo.mounted()
        let primary = NetworkInterfaceInfo.primary()
        XCTAssertFalse(volumes.isEmpty)
        XCTAssertEqual(volumes.first?.path, "/")
        XCTAssertGreaterThan(disk.bytesRead, 0)
        XCTAssertFalse(net.received.isEmpty)
        print("LIVE GPU: \(gpu.map { "\($0.model) \($0.cores ?? 0) cores device=\($0.device) mem=\($0.memoryInUse >> 20)MB" } ?? "none")")
        print("LIVE DISK: read=\(disk.bytesRead >> 30)GB written=\(disk.bytesWritten >> 30)GB; volumes="
              + volumes.map { "\($0.name) \($0.format ?? "?") \($0.device ?? "?") \($0.available >> 30)/\($0.total >> 30)GB" }.joined(separator: ", "))
        let totals = NetworkCounters.bootTotals()
        XCTAssertNotNil(totals)
        print("LIVE NET: rx=\((totals?.received ?? 0) >> 20)MB tx=\((totals?.sent ?? 0) >> 20)MB primary=\(primary.map { "\($0.displayName) \($0.bsdName) \($0.ipv4 ?? "-") \($0.ipv6 ?? "-") \($0.hardwareAddress ?? "-")" } ?? "none")")
    }
}

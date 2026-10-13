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

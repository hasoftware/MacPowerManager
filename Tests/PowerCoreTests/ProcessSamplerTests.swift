import XCTest
@testable import PowerCore

final class ProcessSamplerTests: XCTestCase {
    func testUsageBetweenSamples() {
        let start = Date(timeIntervalSince1970: 1_000)
        let a = [ProcessSample(pid: 10, uid: 501, name: "Safari", cpuTime: 1_000_000_000, resident: 100, threads: 4,
                               energy: 5_000_000_000, diskRead: 1_000, diskWritten: 0, wakeups: 10, started: start),
                 ProcessSample(pid: 20, uid: 0, name: "old", cpuTime: 9_000_000_000, resident: 1, threads: 1, started: start)]
        let b = [ProcessSample(pid: 10, uid: 501, name: "Safari", cpuTime: 1_360_000_000, resident: 120, threads: 5,
                               energy: 7_200_000_000, diskRead: 721_000, diskWritten: 2_000, wakeups: 74, started: start),
                 // PID 20 được dùng lại cho tiến trình khác (thời điểm bắt đầu khác).
                 ProcessSample(pid: 20, uid: 0, name: "new", cpuTime: 50, resident: 1, threads: 1, started: start.addingTimeInterval(5)),
                 ProcessSample(pid: 30, uid: 501, name: "fresh", cpuTime: 1, resident: 1, threads: 1, started: start)]
        let usage = Dictionary(uniqueKeysWithValues: ProcessUsage.between(a, b, elapsed: 2).map { ($0.sample.pid, $0) })
        XCTAssertEqual(usage[10]?.cpu ?? 0, 0.18, accuracy: 1e-9)          // 0,36 s CPU trong 2 s
        XCTAssertEqual(usage[10]?.power ?? 0, 1.1, accuracy: 1e-9)         // 2,2 J trong 2 s
        XCTAssertEqual(usage[10]?.diskReadRate ?? 0, 360_000, accuracy: 1e-9)
        XCTAssertEqual(usage[10]?.wakeupsPerSecond ?? 0, 32, accuracy: 1e-9)
        XCTAssertEqual(usage[20]?.cpu, 0, "PID dùng lại không tính")
        XCTAssertEqual(usage[30]?.cpu, 0, "Tiến trình mới")
    }

    func testLiveSampleContainsThisProcess() throws {
        let samples = ProcessSampler.sample()
        let me = try XCTUnwrap(samples.first { $0.pid == getpid() })
        XCTAssertGreaterThan(me.resident, 1_000_000)
        XCTAssertGreaterThan(me.threads, 0)
        XCTAssertNotNil(me.started)
        XCTAssertGreaterThan(samples.count, 50)
        let json = try JSONEncoder().encode(samples)
        print("LIVE PROCS: \(samples.count) readable, JSON \(json.count / 1024) KB, me=\(me.name) cpu=\(me.cpuTime / 1_000_000)ms energy=\(me.energy)")
    }
}

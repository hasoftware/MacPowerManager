import XCTest
@testable import PowerCore

final class HistoryRecorderPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testRecordsFirstSample() {
        XCTAssertTrue(HistoryRecorderPolicy.shouldRecord(now: t0, lastRecorded: nil))
    }

    func testRecordsAtMostOncePerInterval() {
        let interval = HistoryLog.sampleInterval
        XCTAssertFalse(HistoryRecorderPolicy.shouldRecord(now: t0.addingTimeInterval(10), lastRecorded: t0))
        XCTAssertFalse(HistoryRecorderPolicy.shouldRecord(now: t0.addingTimeInterval(interval - 0.5), lastRecorded: t0))
        XCTAssertTrue(HistoryRecorderPolicy.shouldRecord(now: t0.addingTimeInterval(interval), lastRecorded: t0))
    }

    /// Mô phỏng vòng điều khiển mỗi 10 giây trong 10 phút: đúng một mẫu mỗi phút.
    func testTenSecondLoopYieldsOneSamplePerMinute() {
        var last: Date?
        var recorded: [Date] = []
        for i in 0..<60 {
            let now = t0.addingTimeInterval(Double(i) * 10)
            if HistoryRecorderPolicy.shouldRecord(now: now, lastRecorded: last) {
                last = now
                recorded.append(now)
            }
        }
        XCTAssertEqual(recorded.count, 10)
        for (a, b) in zip(recorded, recorded.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b.timeIntervalSince(a), HistoryLog.sampleInterval)
        }
    }

    /// Ngủ 15 phút rồi dark wake: mẫu đầu tiên sau khi thức được ghi ngay.
    func testRecordsImmediatelyAfterSleepOrDarkWake() {
        let wake = t0.addingTimeInterval(15 * 60 + 2)
        XCTAssertTrue(HistoryRecorderPolicy.shouldRecord(now: wake, lastRecorded: t0))
    }

    func testRecordsWhenClockGoesBackwards() {
        XCTAssertTrue(HistoryRecorderPolicy.shouldRecord(now: t0.addingTimeInterval(-3600), lastRecorded: t0))
    }

    func testPruneOnStartDailyAndOnClockChange() {
        XCTAssertTrue(HistoryRecorderPolicy.shouldPrune(now: t0, lastPruned: nil, lineCount: nil))
        XCTAssertFalse(HistoryRecorderPolicy.shouldPrune(now: t0.addingTimeInterval(3600), lastPruned: t0, lineCount: 100))
        XCTAssertTrue(HistoryRecorderPolicy.shouldPrune(now: t0.addingTimeInterval(24 * 3600), lastPruned: t0, lineCount: 100))
        XCTAssertTrue(HistoryRecorderPolicy.shouldPrune(now: t0.addingTimeInterval(-60), lastPruned: t0, lineCount: 100))
    }

    func testPruneEarlyWhenOverCapButNotEveryMinute() {
        let over = HistoryRecorderPolicy.maxSamples + HistoryRecorderPolicy.capSlack + 1
        XCTAssertEqual(HistoryRecorderPolicy.maxSamples, 30 * 1440)
        XCTAssertFalse(HistoryRecorderPolicy.shouldPrune(now: t0.addingTimeInterval(60), lastPruned: t0, lineCount: over))
        XCTAssertTrue(HistoryRecorderPolicy.shouldPrune(now: t0.addingTimeInterval(3600), lastPruned: t0, lineCount: over))
        XCTAssertFalse(HistoryRecorderPolicy.shouldPrune(now: t0.addingTimeInterval(3600), lastPruned: t0,
                                                         lineCount: over - 1))
    }

    func testRecordedLimit() {
        XCTAssertEqual(HistoryRecorderPolicy.recordedLimit(effectiveLimit: 80), 80)
        XCTAssertNil(HistoryRecorderPolicy.recordedLimit(effectiveLimit: 100))
        XCTAssertNil(HistoryRecorderPolicy.recordedLimit(effectiveLimit: nil))
    }

    func testSampleFields() {
        var battery = BatteryInfo()
        battery.percent = 79
        battery.voltage = 12_000
        battery.amperage = -500
        battery.externalConnected = true
        battery.isCharging = false
        battery.systemLoad = 7.5
        battery.systemPowerIn = 30
        let decision = ControlDecision(chargingEnabled: false, adapterEnabled: true, reason: .limitReached,
                                       effectiveLimit: 80)
        let s = HistoryRecorderPolicy.sample(now: t0, battery: battery, temperature: 31.5, decision: decision)
        XCTAssertEqual(s.date, t0)
        XCTAssertEqual(s.percent, 79)
        XCTAssertEqual(s.temperature, 31.5)
        XCTAssertEqual(s.batteryPower, -6, accuracy: 0.001)
        XCTAssertTrue(s.pluggedIn)
        XCTAssertFalse(s.charging)
        XCTAssertEqual(s.systemLoad, 7.5)
        XCTAssertEqual(s.powerIn, 30)
        XCTAssertEqual(s.limit, 80)
        XCTAssertEqual(s.reason, "limitReached")

        battery.externalConnected = false
        let unplugged = HistoryRecorderPolicy.sample(now: t0, battery: battery, temperature: nil, decision: nil)
        XCTAssertNil(unplugged.powerIn)
        XCTAssertNil(unplugged.limit)
        XCTAssertNil(unplugged.reason)
    }

    func testPrunedDropsExpiredAndCapsCount() {
        let now = t0
        let samples = (0..<10).map { i in
            HistorySample(date: now.addingTimeInterval(-Double(9 - i) * 3600), percent: i, temperature: nil,
                          batteryPower: 0, pluggedIn: true, charging: false)
        }
        let byAge = HistoryRecorderPolicy.pruned(samples, now: now, retention: 4.5 * 3600, maxCount: 100)
        XCTAssertEqual(byAge.map(\.percent), [5, 6, 7, 8, 9])
        let byCount = HistoryRecorderPolicy.pruned(samples, now: now, retention: 100 * 3600, maxCount: 3)
        XCTAssertEqual(byCount.map(\.percent), [7, 8, 9])
    }

    func testAppendDataRepairsTornLastLine() {
        let line = Data("{}\n".utf8)
        XCTAssertEqual(HistoryRecorderPolicy.appendData(line: line, previousLastByte: nil), line)
        XCTAssertEqual(HistoryRecorderPolicy.appendData(line: line, previousLastByte: 0x0A), line)
        XCTAssertEqual(HistoryRecorderPolicy.appendData(line: line, previousLastByte: UInt8(ascii: "}")),
                       Data("\n{}\n".utf8))
    }
}

final class HistoryFileTests: XCTestCase {
    private var dir: URL!
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryFileTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var url: URL { dir.appendingPathComponent("sub/history.jsonl") }

    private func sample(_ offset: TimeInterval, percent: Int = 50) -> HistorySample {
        HistorySample(date: t0.addingTimeInterval(offset), percent: percent, temperature: 30, batteryPower: 1,
                      pluggedIn: true, charging: true, limit: 80, reason: "normal")
    }

    private func permissions(_ path: String) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testAppendCreatesDirectoryAndFileWithReadablePermissions() throws {
        let file = HistoryFile(url: url)
        try file.append(sample(0))
        try file.append(sample(60))
        XCTAssertEqual(try permissions(url.deletingLastPathComponent().path), 0o755)
        XCTAssertEqual(try permissions(url.path), 0o644)
        let decoded = HistoryLog.decode(try Data(contentsOf: url))
        XCTAssertEqual(decoded, [sample(0), sample(60)])
    }

    func testAppendAfterTornLineKeepsNewSample() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = HistoryLog.line(for: sample(0))!
        data.append(Data("{\"date\":1".utf8))  // dòng ghi dở
        try data.write(to: url)
        let file = HistoryFile(url: url)
        try file.append(sample(60))
        XCTAssertEqual(HistoryLog.decode(try Data(contentsOf: url)), [sample(0), sample(60)])
    }

    func testPruneRewritesWithoutExpiredOrCorruptLines() throws {
        let file = HistoryFile(url: url)
        let now = t0.addingTimeInterval(HistoryLog.retention + 120)
        try file.append(sample(0))            // quá hạn
        try file.append(sample(HistoryLog.retention + 60))
        try FileHandle(forWritingTo: url).run { try $0.seekToEnd(); try $0.write(contentsOf: Data("rác\n".utf8)) }
        let kept = try file.prune(now: now)
        XCTAssertEqual(kept, [sample(HistoryLog.retention + 60)])
        XCTAssertEqual(file.lineCount, 1)
        XCTAssertEqual(HistoryLog.decode(try Data(contentsOf: url)), kept)
        XCTAssertEqual(try permissions(url.path), 0o644)
        try file.append(sample(HistoryLog.retention + 120))
        XCTAssertEqual(file.lineCount, 2)
    }

    func testPruneCapsLineCount() throws {
        let file = HistoryFile(url: url)
        for i in 0..<5 { try file.append(sample(Double(i) * 60, percent: i)) }
        let kept = try file.prune(now: t0.addingTimeInterval(300), maxCount: 2)
        XCTAssertEqual(kept.map(\.percent), [3, 4])
        XCTAssertEqual(HistoryLog.decode(try Data(contentsOf: url)).map(\.percent), [3, 4])
    }

    func testPruneMissingFileIsEmpty() throws {
        let file = HistoryFile(url: url)
        XCTAssertEqual(try file.prune(now: t0), [])
        XCTAssertEqual(file.lineCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testPruneLeavesCleanFileUntouched() throws {
        let file = HistoryFile(url: url)
        try file.append(sample(0))
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
        try file.prune(now: t0.addingTimeInterval(60))
        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
        XCTAssertEqual(before, after, "không ghi lại khi không có gì thay đổi")
    }

    func testAppendFailureThrowsInsteadOfCrashing() throws {
        // Đường dẫn cha là một file thường: không tạo được thư mục.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let blocker = dir.appendingPathComponent("sub")
        try Data().write(to: blocker)
        let file = HistoryFile(url: url)
        XCTAssertThrowsError(try file.append(sample(0)))
        XCTAssertThrowsError(try file.prune(now: t0))
    }
}

private extension FileHandle {
    func run(_ body: (FileHandle) throws -> Void) throws {
        defer { try? close() }
        try body(self)
    }
}

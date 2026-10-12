import Foundation
import PowerCore
import XCTest
@testable import MacPowerManager

final class ChartSeriesTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func raw(_ minutes: [Double]) -> [(date: Date, value: Double)] {
        minutes.map { (date: t0.addingTimeInterval($0 * 60), value: $0) }
    }

    func testContinuousDataHasNoBridges() {
        let series = ChartSeries(raw(Array(stride(from: 0.0, through: 30, by: 1))))
        XCTAssertEqual(series.count, 31)
        XCTAssertTrue(series.bridges.isEmpty)
        XCTAssertTrue(series.gaps.isEmpty)
        XCTAssertEqual(Set(series.points.map(\.run)), [0])
    }

    func testShortGapIsBridgeWithoutBand() {
        // 7 phút: nét đứt, chưa đủ 10 phút để tô nền.
        let series = ChartSeries(raw([0, 1, 2, 9, 10]))
        XCTAssertEqual(series.bridges.count, 1)
        XCTAssertEqual(series.bridges[0].from.date, t0.addingTimeInterval(2 * 60))
        XCTAssertEqual(series.bridges[0].to.date, t0.addingTimeInterval(9 * 60))
        XCTAssertTrue(series.gaps.isEmpty)
        XCTAssertEqual(series.runs.count, 2)
        // Đường vẫn liên tục: mọi điểm còn nguyên, đoạn nối chạm đúng hai đầu.
        XCTAssertEqual(series.count, 5)
    }

    func testExactlyFiveMinutesIsContinuous() {
        let series = ChartSeries(raw([0, 5, 10]))
        XCTAssertTrue(series.bridges.isEmpty)
    }

    func testLongGapGetsBand() {
        let series = ChartSeries(raw([0, 1, 30, 31]))
        XCTAssertEqual(series.bridges.count, 1)
        XCTAssertEqual(series.gaps, [ChartGap(start: t0.addingTimeInterval(60), end: t0.addingTimeInterval(30 * 60))])
    }

    func testPowerNapWakesMergeIntoOneBand() {
        // Máy ngủ, thức dậy một phút mỗi 15 phút: mỗi lần là một đoạn nối, nhưng nền là một vùng liền.
        let series = ChartSeries(raw([0, 1, 16, 31, 46, 61, 62]))
        XCTAssertEqual(series.bridges.count, 4)
        XCTAssertEqual(series.isolated.map(\.date), [16.0, 31, 46].map { t0.addingTimeInterval($0 * 60) })
        XCTAssertEqual(series.gaps.count, 1)
        XCTAssertEqual(series.gaps[0].start, t0.addingTimeInterval(60))
        XCTAssertEqual(series.gaps[0].end, t0.addingTimeInterval(61 * 60))
    }

    func testBucketingKeepsSeriesContinuousAcrossSmallGaps() {
        // 30 ngày mỗi phút, có khoảng ngủ 15 phút mỗi giờ: ở độ phân giải 300 điểm (~2,4 giờ/ô) vẫn là một đường.
        var minutes: [Double] = []
        for m in 0..<(30 * 24 * 60) where m % 60 < 45 { minutes.append(Double(m)) }
        let series = ChartSeries(raw(minutes), maxPoints: 300)
        XCTAssertLessThanOrEqual(series.count, 300)
        XCTAssertGreaterThan(series.count, 250)
        XCTAssertTrue(series.bridges.isEmpty)
        // Giá trị là trung bình trong ô và thời điểm tăng dần.
        XCTAssertEqual(series.points.map(\.date), series.points.map(\.date).sorted())
    }

    func testBucketingStillShowsLongGaps() {
        // 3 ngày dữ liệu, mất 12 giờ ở giữa.
        var minutes: [Double] = []
        for m in 0..<(3 * 24 * 60) where !(30 * 60..<42 * 60).contains(m) { minutes.append(Double(m)) }
        let series = ChartSeries(raw(minutes), maxPoints: 300)
        XCTAssertEqual(series.bridges.count, 1)
        XCTAssertEqual(series.gaps.count, 1)
        let gap = series.gaps[0]
        XCTAssertLessThan(gap.start, t0.addingTimeInterval(30 * 3600))
        XCTAssertGreaterThan(gap.end, t0.addingTimeInterval(42 * 3600))
        XCTAssertGreaterThan(gap.end.timeIntervalSince(gap.start), 12 * 3600)
    }

    func testSelectionInsideGapAndNearPoints() {
        let series = ChartSeries(raw([0, 1, 60, 61]))
        let snap: TimeInterval = 60
        XCTAssertEqual(series.selection(at: t0.addingTimeInterval(30 * 60), snap: snap),
                       .gap(start: t0.addingTimeInterval(60), end: t0.addingTimeInterval(3600)))
        guard case .point(let p) = series.selection(at: t0.addingTimeInterval(61 * 60 + 10), snap: snap) else {
            return XCTFail("phải chọn điểm")
        }
        XCTAssertEqual(p.date, t0.addingTimeInterval(61 * 60))
        // Sát đầu khoảng trống: vẫn chọn điểm.
        guard case .point = series.selection(at: t0.addingTimeInterval(90), snap: snap) else {
            return XCTFail("phải chọn điểm")
        }
        XCTAssertNil(ChartSeries([]).selection(at: t0, snap: snap))
    }

    func testSamplesSeriesSkipsMissingValues() {
        let samples = (0..<5).map { i in
            HistorySample(date: t0.addingTimeInterval(Double(i) * 60), percent: 50, temperature: i == 2 ? nil : 30,
                          batteryPower: 0, pluggedIn: true, charging: false)
        }
        let series = samples.series { $0.temperature }
        XCTAssertEqual(series.count, 4)
        XCTAssertTrue(series.bridges.isEmpty)
    }
}

final class HistoryFileTailTests: XCTestCase {
    private var dir: URL!
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryFileTailTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func sample(_ minute: Int, percent: Int = 50) -> HistorySample {
        HistorySample(date: t0.addingTimeInterval(Double(minute) * 60), percent: percent, temperature: 30,
                      batteryPower: 0, pluggedIn: true, charging: false)
    }

    private func lines(_ samples: [HistorySample]) -> Data {
        samples.reduce(into: Data()) { $0.append(HistoryLog.line(for: $1)!) }
    }

    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
    }

    func testMissingFileReturnsNil() {
        XCTAssertNil(HistoryFileTail.read(dir.appendingPathComponent("none.jsonl"), from: .init(), cutoff: nil))
    }

    func testReadsIncrementallyAndWaitsForCompleteLines() throws {
        let url = dir.appendingPathComponent("h.jsonl")
        try lines([sample(0), sample(1)]).write(to: url)
        let first = try XCTUnwrap(HistoryFileTail.read(url, from: .init(), cutoff: nil))
        XCTAssertTrue(first.reset)
        XCTAssertEqual(first.samples.map(\.date), [sample(0).date, sample(1).date])

        // Dòng đang ghi dở: chưa nhận.
        var next = lines([sample(2)])
        let partial = next.prefix(10)
        try append(Data(partial), to: url)
        let second = try XCTUnwrap(HistoryFileTail.read(url, from: first.position, cutoff: nil))
        XCTAssertFalse(second.reset)
        XCTAssertTrue(second.samples.isEmpty)
        XCTAssertEqual(second.position, first.position)

        next.removeFirst(10)
        try append(next, to: url)
        let third = try XCTUnwrap(HistoryFileTail.read(url, from: second.position, cutoff: nil))
        XCTAssertFalse(third.reset)
        XCTAssertEqual(third.samples.map(\.date), [sample(2).date])
    }

    func testShrunkOrReplacedFileIsReadFromStart() throws {
        let url = dir.appendingPathComponent("h.jsonl")
        try lines((0..<10).map { sample($0) }).write(to: url)
        let first = try XCTUnwrap(HistoryFileTail.read(url, from: .init(), cutoff: nil))
        // Helper thu gọn: ghi đè bằng file ngắn hơn.
        try lines([sample(8), sample(9)]).write(to: url, options: .atomic)
        let second = try XCTUnwrap(HistoryFileTail.read(url, from: first.position, cutoff: nil))
        XCTAssertTrue(second.reset)
        XCTAssertEqual(second.samples.count, 2)
    }

    func testCutoffDropsOldSamples() throws {
        let url = dir.appendingPathComponent("h.jsonl")
        try lines([sample(0), sample(10)]).write(to: url)
        let chunk = try XCTUnwrap(HistoryFileTail.read(url, from: .init(), cutoff: t0.addingTimeInterval(5 * 60)))
        XCTAssertEqual(chunk.samples.count, 1)
    }
}

@MainActor
final class HistoryStoreTests: XCTestCase {
    private var dir: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suite = "HistoryStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        defaults.removePersistentDomain(forName: suite)
    }

    private var appURL: URL { dir.appendingPathComponent("app.jsonl") }
    private var helperURL: URL { dir.appendingPathComponent("helper.jsonl") }

    private func battery(_ percent: Int) -> BatteryInfo {
        var b = BatteryInfo()
        b.percent = percent
        return b
    }

    private func helperSample(_ date: Date, percent: Int = 70) -> HistorySample {
        HistorySample(date: date, percent: percent, temperature: 30, batteryPower: 0, pluggedIn: true, charging: false,
                      reason: "limitReached")
    }

    private func writeHelper(_ samples: [HistorySample], append: Bool = false) throws {
        let data = samples.reduce(into: Data()) { $0.append(HistoryLog.line(for: $1)!) }
        if append, let handle = try? FileHandle(forWritingTo: helperURL) {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try data.write(to: helperURL)
        }
    }

    func testRecordsOwnSamplesWithoutHelper() async {
        let now = Date()
        let store = HistoryStore(fileURL: appURL, helperURL: helperURL, defaults: defaults, now: now)
        await store.refreshHelper(now: now)
        store.record(battery: battery(50), temperature: 30, limit: 80, now: now)
        store.record(battery: battery(51), temperature: 30, limit: 80, now: now.addingTimeInterval(30))
        store.record(battery: battery(52), temperature: 30, limit: 80, now: now.addingTimeInterval(61))
        XCTAssertEqual(store.samples.map(\.percent), [50, 52])
        // Đọc lại từ file.
        let reloaded = HistoryStore(fileURL: appURL, helperURL: nil, defaults: defaults, now: now.addingTimeInterval(62))
        XCTAssertEqual(reloaded.samples.count, 2)
    }

    func testMergesHelperHistoryAndStopsRecordingWhileHelperIsFresh() async throws {
        let now = Date()
        // App tự ghi lúc trước khi cài helper.
        let old = HistoryStore(fileURL: appURL, helperURL: nil, defaults: defaults, now: now.addingTimeInterval(-7200))
        old.record(battery: battery(40), temperature: 30, limit: 80, now: now.addingTimeInterval(-7200))
        try writeHelper([helperSample(now.addingTimeInterval(-120)), helperSample(now.addingTimeInterval(-60))])

        let store = HistoryStore(fileURL: appURL, helperURL: helperURL, defaults: defaults, now: now)
        await store.refreshHelper(now: now)
        XCTAssertTrue(store.helperIsFresh(now: now))
        XCTAssertEqual(store.samples.count, 3)
        XCTAssertEqual(store.samples.first?.percent, 40)

        store.record(battery: battery(71), temperature: 30, limit: 80, now: now)
        XCTAssertEqual(store.samples.count, 3, "helper đang ghi: app không ghi trùng")

        // Helper ghi thêm: đọc phần mới.
        try writeHelper([helperSample(now.addingTimeInterval(60), percent: 72)], append: true)
        await store.refreshHelper(now: now.addingTimeInterval(61))
        XCTAssertEqual(store.samples.count, 4)
        XCTAssertEqual(store.samples.last?.percent, 72)

        // Helper ngừng ghi quá 3 phút: app ghi lại.
        let later = now.addingTimeInterval(5 * 60)
        await store.refreshHelper(now: later)
        XCTAssertFalse(store.helperIsFresh(now: later))
        store.record(battery: battery(73), temperature: 30, limit: 80, now: later)
        XCTAssertEqual(store.samples.last?.percent, 73)
        XCTAssertEqual(store.samples.count, 5)
    }

    func testReloadsWhenHelperPrunesFile() async throws {
        let now = Date()
        try writeHelper((0..<10).map { helperSample(now.addingTimeInterval(Double($0 - 10) * 60)) })
        let store = HistoryStore(fileURL: appURL, helperURL: helperURL, defaults: defaults, now: now)
        await store.refreshHelper(now: now)
        XCTAssertEqual(store.samples.count, 10)
        try writeHelper([helperSample(now.addingTimeInterval(-60))])
        await store.refreshHelper(now: now)
        XCTAssertEqual(store.samples.count, 1)
    }

    func testKeepsThirtyDays() async throws {
        let now = Date()
        try writeHelper([helperSample(now.addingTimeInterval(-31 * 24 * 3600)),
                         helperSample(now.addingTimeInterval(-29 * 24 * 3600)),
                         helperSample(now.addingTimeInterval(-60))])
        let store = HistoryStore(fileURL: appURL, helperURL: helperURL, defaults: defaults, now: now)
        await store.refreshHelper(now: now)
        XCTAssertEqual(store.samples.count, 2)
        XCTAssertEqual(store.samples(within: 30 * 24 * 3600, now: now).count, 2)
        XCTAssertEqual(store.samples(within: 3600, now: now).count, 1)
    }

    func testClearHidesHelperHistory() async throws {
        let now = Date()
        try writeHelper([helperSample(now.addingTimeInterval(-120))])
        let store = HistoryStore(fileURL: appURL, helperURL: helperURL, defaults: defaults, now: now)
        await store.refreshHelper(now: now)
        XCTAssertEqual(store.samples.count, 1)
        store.clear(now: now)
        XCTAssertTrue(store.samples.isEmpty)
        try writeHelper([helperSample(now.addingTimeInterval(60))], append: true)
        await store.refreshHelper(now: now.addingTimeInterval(61))
        XCTAssertEqual(store.samples.count, 1)
        // Lựa chọn xóa được nhớ khi mở lại app.
        let reopened = HistoryStore(fileURL: appURL, helperURL: helperURL, defaults: defaults, now: now.addingTimeInterval(62))
        await reopened.refreshHelper(now: now.addingTimeInterval(62))
        XCTAssertEqual(reopened.samples.count, 1)
    }
}

final class HistoryReviewFixTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func sample(_ minute: Double, powerIn: Double?, plugged: Bool = true) -> HistorySample {
        HistorySample(date: t0.addingTimeInterval(minute * 60), percent: 50, temperature: 30, batteryPower: 0,
                      pluggedIn: plugged, charging: false, powerIn: powerIn)
    }

    func testMissingValuesBreakLineWithoutNoDataBand() {
        // Rút sạc 20 phút khi máy vẫn thức: có mẫu mỗi phút nhưng không có công suất adapter.
        var samples = (0...5).map { sample(Double($0), powerIn: 60) }
        samples += (6...25).map { sample(Double($0), powerIn: nil, plugged: false) }
        samples += (26...30).map { sample(Double($0), powerIn: 60) }
        let series = samples.series { $0.powerIn }
        XCTAssertTrue(series.gaps.isEmpty, "Không phải máy ngủ")
        XCTAssertTrue(series.bridges.isEmpty, "Không nối đường qua lúc rút sạc")
        XCTAssertEqual(series.runs.count, 2)
    }

    func testRealSleepStillProducesBand() {
        let samples = [sample(0, powerIn: 60), sample(1, powerIn: 60), sample(40, powerIn: 60), sample(41, powerIn: 60)]
        let series = samples.series { $0.powerIn }
        XCTAssertEqual(series.gaps.count, 1)
        XCTAssertEqual(series.bridges.count, 1)
    }

    func testHoverInsideBandReportsGapEvenWithLargeSnap() {
        let samples = [sample(0, powerIn: 60), sample(1, powerIn: 60), sample(300, powerIn: 60), sample(301, powerIn: 60)]
        let series = samples.series { $0.powerIn }
        let middle = t0.addingTimeInterval(150 * 60)
        guard case .gap = series.selection(at: middle, snap: 11 * 3600) else {
            return XCTFail("Di chuột giữa vùng máy ngủ phải hiện khoảng trống")
        }
    }

    @MainActor
    func testHelperFreshnessFromFileModificationDate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let helperURL = dir.appendingPathComponent("helper.jsonl")
        try Data().write(to: helperURL)
        let store = HistoryStore(fileURL: dir.appendingPathComponent("app.jsonl"), helperURL: helperURL, defaults: nil)
        XCTAssertTrue(store.helperIsFresh(), "File helper vừa được ghi: coi là helper đang ghi dù chưa đọc mẫu nào")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: helperURL.path)
        XCTAssertFalse(store.helperIsFresh())
    }
}

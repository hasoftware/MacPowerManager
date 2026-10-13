import XCTest
@testable import PowerCore

final class HealthLogTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return c
    }()
    private let start = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01

    private func point(day: Int, macOS: Int? = nil, estimate: Double? = nil, cycles: Int = 0, hour: Int = 9) -> HealthPoint {
        let date = calendar.date(byAdding: .hour, value: day * 24 + hour, to: calendar.startOfDay(for: start))!
        return HealthPoint(day: date, maximumCapacityPercent: macOS, estimatedPercent: estimate, cycleCount: cycles,
                           nominalCapacity: 7800, designCapacity: 8694)
    }

    func testRecordKeepsOnePointPerDayAndKeepsMacOSValue() {
        var points: [HealthPoint] = []
        points = HealthLog.record(point(day: 0, macOS: 92, estimate: 90, hour: 8), into: points, calendar: calendar)
        // Cùng ngày, lần đọc sau chưa có số của macOS: giữ 92, cập nhật ước tính.
        points = HealthLog.record(point(day: 0, estimate: 89.5, hour: 20), into: points, calendar: calendar)
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].maximumCapacityPercent, 92)
        XCTAssertEqual(points[0].estimatedPercent, 89.5)
        XCTAssertEqual(points[0].day, calendar.startOfDay(for: points[0].day))

        points = HealthLog.record(point(day: 1, macOS: 91), into: points, calendar: calendar)
        points = HealthLog.record(point(day: -3, macOS: 93), into: points, calendar: calendar)
        XCTAssertEqual(points.map(\.maximumCapacityPercent), [93, 92, 91], "Sắp xếp theo ngày")
    }

    func testSeriesPrefersMacOSAndDoesNotMixSources() {
        let points = [point(day: 0, estimate: 90), point(day: 1, macOS: 95, estimate: 90), point(day: 2, estimate: 89)]
        XCTAssertEqual(HealthLog.series(points).map(\.percent), [95])
        XCTAssertEqual(HealthLog.series([point(day: 0, estimate: 90)]).map(\.percent), [90])
    }

    func testNoTrendUntilEnoughDays() {
        let points = (0..<20).map { point(day: $0, macOS: 92) }
        XCTAssertNil(HealthLog.trend(points), "Chưa đủ 30 ngày")
    }

    func testTrendEstimatesDeclineAndTimeToThreshold() throws {
        // Giảm đúng 3 điểm % mỗi năm, bắt đầu từ 92%.
        let points = stride(from: 0, through: 365, by: 5).map { day in
            point(day: day, estimate: 92 - 3 * Double(day) / 365, cycles: 100 + day / 2)
        }
        let trend = try XCTUnwrap(HealthLog.trend(points))
        XCTAssertEqual(trend.changePerYear, -3, accuracy: 0.01)
        XCTAssertEqual(trend.current, 89, accuracy: 0.05)
        // Từ 89% xuống 80% với 3%/năm: 3 năm.
        XCTAssertEqual(try XCTUnwrap(trend.daysUntilThreshold) / 365, 3, accuracy: 0.02)
        XCTAssertEqual(try XCTUnwrap(trend.cyclesPerMonth), 15, accuracy: 0.2)
    }

    func testFlatOrBelowThresholdHasNoCountdown() throws {
        let flat = (0...40).map { point(day: $0, macOS: 95) }
        XCTAssertNil(try XCTUnwrap(HealthLog.trend(flat)).daysUntilThreshold)
        let worn = (0...40).map { point(day: $0, macOS: 79 - $0 / 20) }
        XCTAssertNil(try XCTUnwrap(HealthLog.trend(worn)).daysUntilThreshold)
    }

    func testCapAndDecode() throws {
        var points: [HealthPoint] = []
        for day in 0..<(HealthLog.maxPoints + 5) { points.append(point(day: day, macOS: 90)) }
        let capped = HealthLog.record(point(day: HealthLog.maxPoints + 10, macOS: 89), into: points, calendar: calendar)
        XCTAssertEqual(capped.count, HealthLog.maxPoints)
        XCTAssertEqual(capped.last?.maximumCapacityPercent, 89)
        let data = try JSONEncoder().encode(Array(capped.suffix(3).reversed()))
        XCTAssertEqual(HealthLog.decode(data).map(\.day), capped.suffix(3).map(\.day))
        XCTAssertEqual(HealthLog.decode(Data("rác".utf8)), [])
    }
}

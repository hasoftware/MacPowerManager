import Foundation
import Observation
import PowerCore

/// Nhật ký sức khỏe pin dài hạn: mỗi ngày một điểm (con số của macOS, ước tính từ IOKit, số lần sạc), lưu ở
/// `~/Library/Application Support/MacPowerManager/health-log.json`. Không xóa cùng lịch sử 30 ngày.
@MainActor
@Observable
final class HealthStore {
    private(set) var points: [HealthPoint] = []

    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private let calendar: Calendar

    convenience init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacPowerManager", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.init(fileURL: dir.appendingPathComponent("health-log.json"))
    }

    init(fileURL: URL?, calendar: Calendar = .current) {
        self.fileURL = fileURL
        self.calendar = calendar
        if let fileURL, let data = try? Data(contentsOf: fileURL) { points = HealthLog.decode(data) }
    }

    /// Dữ liệu cố định, không đọc/ghi file (xem trước, snapshot).
    init(points: [HealthPoint]) {
        fileURL = nil
        calendar = .current
        self.points = points
    }

    var trend: HealthTrend? { HealthLog.trend(points) }

    /// Ghi điểm của hôm nay. Chỉ ghi file khi điểm thay đổi.
    func record(battery: BatteryInfo, macOS: MacOSBatteryHealth?, now: Date = Date()) {
        guard battery.designCapacity > 0 else { return }
        let point = HealthPoint(day: now, maximumCapacityPercent: macOS?.maximumCapacityPercent,
                                estimatedPercent: battery.nominalHealth ?? battery.health,
                                cycleCount: macOS?.cycleCount ?? battery.cycleCount,
                                nominalCapacity: battery.nominalCapacity > 0 ? battery.nominalCapacity : battery.maxCapacity,
                                designCapacity: battery.designCapacity)
        let updated = HealthLog.record(point, into: points, calendar: calendar)
        guard updated != points else { return }
        points = updated
        guard let fileURL, let data = try? JSONEncoder().encode(points) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

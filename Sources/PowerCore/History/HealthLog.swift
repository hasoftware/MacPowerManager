import Foundation

/// Một điểm sức khỏe pin mỗi ngày, để theo dõi pin chai dần qua nhiều tháng, nhiều năm.
public struct HealthPoint: Codable, Equatable, Identifiable, Sendable {
    /// Đầu ngày (theo lịch của máy) mà điểm này đại diện.
    public var day: Date
    /// "Maximum Capacity" theo macOS (System Settings → Battery), nil nếu chưa đọc được.
    public var maximumCapacityPercent: Int?
    /// Ước tính từ dung lượng danh định / thiết kế (IOKit), dùng khi không có con số của macOS.
    public var estimatedPercent: Double?
    public var cycleCount: Int
    /// mAh
    public var nominalCapacity: Int
    public var designCapacity: Int

    public var id: Date { day }

    public init(day: Date, maximumCapacityPercent: Int?, estimatedPercent: Double?, cycleCount: Int,
                nominalCapacity: Int, designCapacity: Int) {
        self.day = day
        self.maximumCapacityPercent = maximumCapacityPercent
        self.estimatedPercent = estimatedPercent
        self.cycleCount = cycleCount
        self.nominalCapacity = nominalCapacity
        self.designCapacity = designCapacity
    }
}

/// Xu hướng sức khỏe pin tính từ nhật ký (hồi quy tuyến tính theo thời gian).
public struct HealthTrend: Equatable, Sendable {
    /// Sức khỏe hiện tại theo đường xu hướng (%).
    public var current: Double
    /// Thay đổi mỗi năm (điểm %, âm = đang chai).
    public var changePerYear: Double
    /// Số ngày nữa chạm `HealthLog.serviceThreshold`; nil nếu không giảm hoặc đã dưới ngưỡng.
    public var daysUntilThreshold: Double?
    /// Số lần sạc trung bình mỗi tháng (30 ngày); nil nếu chưa đủ dữ liệu.
    public var cyclesPerMonth: Double?
    /// Số ngày dữ liệu (từ điểm đầu tới điểm cuối).
    public var spanDays: Double
}

/// Nhật ký sức khỏe pin (thuần, để kiểm thử): mỗi ngày một điểm, giữ lâu dài.
public enum HealthLog {
    /// Số ngày dữ liệu tối thiểu trước khi ước tính xu hướng (con số của macOS chỉ đổi vài tuần một lần).
    public static let minimumTrendDays: Double = 30
    public static let minimumTrendPoints = 5
    /// Pin dưới mức này thường được macOS khuyên thay ("Service Recommended").
    public static let serviceThreshold: Double = 80
    /// Giữ tối đa chừng này điểm (khoảng 10 năm).
    public static let maxPoints = 3650

    /// Ghi điểm của ngày chứa `point.day`: thay điểm cũ cùng ngày, giữ thứ tự thời gian.
    public static func record(_ point: HealthPoint, into points: [HealthPoint], calendar: Calendar = .current) -> [HealthPoint] {
        var point = point
        point.day = calendar.startOfDay(for: point.day)
        var result = points.filter { !calendar.isDate($0.day, inSameDayAs: point.day) }
        // Điểm mới thiếu số của macOS thì giữ số đã có trong ngày (system_profiler chạy sau lần đọc IOKit đầu tiên).
        if point.maximumCapacityPercent == nil,
           let sameDay = points.first(where: { calendar.isDate($0.day, inSameDayAs: point.day) }) {
            point.maximumCapacityPercent = sameDay.maximumCapacityPercent
        }
        result.append(point)
        result.sort { $0.day < $1.day }
        if result.count > maxPoints { result.removeFirst(result.count - maxPoints) }
        return result
    }

    /// Chuỗi giá trị dùng để vẽ và tính xu hướng. Dùng con số của macOS nếu có (bỏ các ngày thiếu), nếu không thì
    /// dùng ước tính từ IOKit. Không trộn hai nguồn vì chúng lệch nhau vài phần trăm.
    public static func series(_ points: [HealthPoint]) -> [(day: Date, percent: Double)] {
        let macOS = points.compactMap { p in p.maximumCapacityPercent.map { (day: p.day, percent: Double($0)) } }
        if !macOS.isEmpty { return macOS }
        return points.compactMap { p in p.estimatedPercent.map { (day: p.day, percent: $0) } }
    }

    public static func trend(_ points: [HealthPoint]) -> HealthTrend? {
        let values = series(points)
        guard values.count >= minimumTrendPoints, let first = values.first, let last = values.last else { return nil }
        let spanDays = last.day.timeIntervalSince(first.day) / 86_400
        guard spanDays >= minimumTrendDays else { return nil }

        // Hồi quy tuyến tính: x = ngày kể từ điểm đầu, y = %.
        let xs = values.map { $0.day.timeIntervalSince(first.day) / 86_400 }
        let ys = values.map(\.percent)
        let n = Double(values.count)
        let meanX = xs.reduce(0, +) / n, meanY = ys.reduce(0, +) / n
        let sxx = zip(xs, xs).map { ($0 - meanX) * ($1 - meanX) }.reduce(0, +)
        guard sxx > 0 else { return nil }
        let sxy = zip(xs, ys).map { ($0 - meanX) * ($1 - meanY) }.reduce(0, +)
        let slopePerDay = sxy / sxx
        let current = min(max(meanY + slopePerDay * (spanDays - meanX), 0), 100)

        var daysUntil: Double?
        if slopePerDay < 0, current > serviceThreshold {
            daysUntil = (current - serviceThreshold) / -slopePerDay
        }

        let cycles = points.filter { $0.cycleCount > 0 }
        var cyclesPerMonth: Double?
        if let c0 = cycles.first, let c1 = cycles.last {
            let days = c1.day.timeIntervalSince(c0.day) / 86_400
            if days >= minimumTrendDays { cyclesPerMonth = Double(max(c1.cycleCount - c0.cycleCount, 0)) / days * 30 }
        }
        return HealthTrend(current: current, changePerYear: slopePerDay * 365, daysUntilThreshold: daysUntil,
                           cyclesPerMonth: cyclesPerMonth, spanDays: spanDays)
    }

    public static func decode(_ data: Data) -> [HealthPoint] {
        ((try? JSONDecoder().decode([HealthPoint].self, from: data)) ?? []).sorted { $0.day < $1.day }
    }
}

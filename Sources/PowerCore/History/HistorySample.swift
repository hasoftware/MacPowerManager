import Foundation

/// Một mẫu lịch sử pin. Ghi dạng JSON Lines bởi helper (root, `PowerConstants.helperHistoryURL`, chạy cả khi app
/// đã thoát) và bởi app (thư mục người dùng, khi chưa có helper).
public struct HistorySample: Codable, Identifiable, Equatable, Sendable {
    public var date: Date
    public var percent: Int
    public var temperature: Double?
    public var batteryPower: Double   // W, dương = đang nạp
    public var pluggedIn: Bool
    public var charging: Bool
    // v0.3.0 (optional để đọc được lịch sử cũ)
    public var systemLoad: Double?    // W
    public var powerIn: Double?       // W, từ adapter
    /// Giới hạn đang áp dụng lúc ghi (nil = không giới hạn hoặc chưa có helper).
    public var limit: Int?
    /// Lý do quyết định của helper lúc ghi (`ChargeReason.rawValue`), nil với mẫu do app ghi.
    public var reason: String?

    public var id: Date { date }

    public init(date: Date, percent: Int, temperature: Double?, batteryPower: Double, pluggedIn: Bool,
                charging: Bool, systemLoad: Double? = nil, powerIn: Double? = nil, limit: Int? = nil,
                reason: String? = nil) {
        self.date = date
        self.percent = percent
        self.temperature = temperature
        self.batteryPower = batteryPower
        self.pluggedIn = pluggedIn
        self.charging = charging
        self.systemLoad = systemLoad
        self.powerIn = powerIn
        self.limit = limit
        self.reason = reason
    }
}

/// Đọc/ghi file JSON Lines của lịch sử (thuần, để kiểm thử).
public enum HistoryLog {
    /// Khoảng cách tối thiểu giữa hai mẫu.
    public static let sampleInterval: TimeInterval = 60
    /// Thời gian lưu lịch sử của helper.
    public static let retention: TimeInterval = 30 * 24 * 3600

    public static func line(for sample: HistorySample) -> Data? {
        guard var data = try? JSONEncoder().encode(sample) else { return nil }
        data.append(0x0A)
        return data
    }

    /// Giải mã các dòng, bỏ dòng hỏng, sắp xếp theo thời gian và bỏ mẫu cũ hơn `cutoff`.
    public static func decode(_ data: Data, cutoff: Date? = nil) -> [HistorySample] {
        let decoder = JSONDecoder()
        var samples = data.split(separator: 0x0A).compactMap { try? decoder.decode(HistorySample.self, from: Data($0)) }
        if let cutoff { samples.removeAll { $0.date < cutoff } }
        samples.sort { $0.date < $1.date }
        return samples
    }

    /// Gộp hai nguồn (helper và app), bỏ mẫu trùng trong cùng một phút (ưu tiên mẫu của helper).
    public static func merge(helper: [HistorySample], app: [HistorySample]) -> [HistorySample] {
        var byMinute: [Int: HistorySample] = [:]
        for s in app { byMinute[Int(s.date.timeIntervalSinceReferenceDate / 60)] = s }
        for s in helper { byMinute[Int(s.date.timeIntervalSinceReferenceDate / 60)] = s }
        return byMinute.values.sorted { $0.date < $1.date }
    }
}

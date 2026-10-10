import Foundation
import Observation
import PowerCore

/// Lưu lịch sử pin dạng JSON Lines, giữ tối đa 7 ngày.
@MainActor
@Observable
final class HistoryStore {
    private(set) var samples: [HistorySample] = []

    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private let interval: TimeInterval = 60
    @ObservationIgnored private let retention: TimeInterval = 7 * 24 * 3600

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacPowerManager", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.jsonl")
        load()
    }

    /// Dữ liệu cố định, không đọc/ghi file (xem trước, snapshot).
    init(samples: [HistorySample]) {
        fileURL = nil
        self.samples = samples
    }

    func record(battery: BatteryInfo, temperature: Double?, limit: Int?) {
        let now = Date()
        if let last = samples.last, now.timeIntervalSince(last.date) < interval { return }
        let sample = HistorySample(date: now, percent: battery.percent, temperature: temperature,
                                   batteryPower: battery.batteryPower, pluggedIn: battery.externalConnected,
                                   charging: battery.isCharging, systemLoad: battery.systemLoad,
                                   powerIn: battery.externalConnected ? battery.systemPowerIn : nil, limit: limit)
        samples.append(sample)
        append(sample)
    }

    func samples(within range: TimeInterval, now: Date = Date()) -> [HistorySample] {
        let cutoff = now.addingTimeInterval(-range)
        guard let start = samples.firstIndex(where: { $0.date >= cutoff }) else { return [] }
        return Array(samples[start...])
    }

    func clear() {
        samples = []
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    /// CSV để người dùng tự phân tích (dấu chấm thập phân, tên cột tiếng Anh cho dễ xử lý bằng công cụ).
    func csv(within range: TimeInterval) -> String {
        let iso = ISO8601DateFormatter()
        func num(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "" }
        var lines = ["date,percent,temperature_c,battery_w,system_w,adapter_w,plugged_in,charging,limit"]
        for s in samples(within: range) {
            lines.append([iso.string(from: s.date), "\(s.percent)", num(s.temperature), num(s.batteryPower),
                          num(s.systemLoad), num(s.powerIn), s.pluggedIn ? "1" : "0", s.charging ? "1" : "0",
                          s.limit.map(String.init) ?? ""].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func load() {
        guard let fileURL, let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        let cutoff = Date().addingTimeInterval(-retention)
        samples = text.split(separator: "\n")
            .compactMap { try? decoder.decode(HistorySample.self, from: Data($0.utf8)) }
            .filter { $0.date >= cutoff }
        // Ghi lại file để bỏ các mẫu đã quá hạn.
        let lines = samples.compactMap { try? JSONEncoder().encode($0) }
            .compactMap { String(data: $0, encoding: .utf8) }
        try? (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func append(_ sample: HistorySample) {
        guard let fileURL, let data = try? JSONEncoder().encode(sample) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data + Data("\n".utf8))
        } else {
            try? (data + Data("\n".utf8)).write(to: fileURL)
        }
    }
}

/// Một điểm trên biểu đồ. `segment` tăng mỗi khi có khoảng trống (máy ngủ, app tắt) để không nối đường qua đó.
struct ChartPoint: Identifiable, Equatable {
    var date: Date
    var value: Double
    var segment: Int
    var id: Date { date }
}

extension Array where Element == HistorySample {
    /// Trích một chuỗi giá trị, chia đoạn tại các khoảng trống và gộp còn khoảng `maxPoints` điểm.
    func points(maxPoints: Int = 300, gap: TimeInterval = 5 * 60, _ value: (HistorySample) -> Double?) -> [ChartPoint] {
        var raw: [ChartPoint] = []
        var segment = 0
        var lastDate: Date?
        for s in self {
            guard let v = value(s) else { continue }
            if let lastDate, s.date.timeIntervalSince(lastDate) > gap { segment += 1 }
            lastDate = s.date
            raw.append(ChartPoint(date: s.date, value: v, segment: segment))
        }
        guard raw.count > maxPoints else { return raw }
        // Gộp các điểm liên tiếp trong cùng một đoạn (lấy trung bình).
        let bucket = Int((Double(raw.count) / Double(maxPoints)).rounded(.up))
        var result: [ChartPoint] = []
        var i = 0
        while i < raw.count {
            var j = i
            var sum = 0.0
            while j < raw.count && j < i + bucket && raw[j].segment == raw[i].segment {
                sum += raw[j].value
                j += 1
            }
            result.append(ChartPoint(date: raw[i].date, value: sum / Double(j - i), segment: raw[i].segment))
            i = j
        }
        return result
    }
}

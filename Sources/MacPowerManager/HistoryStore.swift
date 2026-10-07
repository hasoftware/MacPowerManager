import Foundation
import Observation
import PowerCore

struct HistorySample: Codable, Identifiable, Equatable {
    var date: Date
    var percent: Int
    var temperature: Double?
    var batteryPower: Double   // W, dương = đang nạp
    var pluggedIn: Bool
    var charging: Bool

    var id: Date { date }
}

/// Lưu lịch sử pin dạng JSON Lines, giữ tối đa 7 ngày.
@MainActor
@Observable
final class HistoryStore {
    private(set) var samples: [HistorySample] = []

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let interval: TimeInterval = 60
    @ObservationIgnored private let retention: TimeInterval = 7 * 24 * 3600

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacPowerManager", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.jsonl")
        load()
    }

    func record(battery: BatteryInfo, temperature: Double?) {
        let now = Date()
        if let last = samples.last, now.timeIntervalSince(last.date) < interval { return }
        let sample = HistorySample(date: now, percent: battery.percent, temperature: temperature,
                                   batteryPower: battery.batteryPower, pluggedIn: battery.externalConnected,
                                   charging: battery.isCharging)
        samples.append(sample)
        append(sample)
    }

    func samples(within range: TimeInterval) -> [HistorySample] {
        let cutoff = Date().addingTimeInterval(-range)
        return samples.filter { $0.date >= cutoff }
    }

    func clear() {
        samples = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func load() {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
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
        guard let data = try? JSONEncoder().encode(sample) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data + Data("\n".utf8))
        } else {
            try? (data + Data("\n".utf8)).write(to: fileURL)
        }
    }
}

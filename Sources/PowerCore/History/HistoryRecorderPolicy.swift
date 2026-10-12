import Foundation

/// Quyết định ghi lịch sử của helper (thuần, để kiểm thử). Phần đọc/ghi file nằm ở `HistoryFile`.
public enum HistoryRecorderPolicy {
    /// Khoảng cách giữa hai lần dọn file (bỏ mẫu quá hạn, giới hạn số dòng).
    public static let pruneInterval: TimeInterval = 24 * 3600
    /// Số mẫu tối đa giữ lại: 30 ngày × 1440 mẫu mỗi ngày.
    public static let maxSamples = Int(HistoryLog.retention / HistoryLog.sampleInterval)
    /// Cho phép vượt `maxSamples` thêm một ngày trước khi dọn sớm (tránh ghi lại cả file mỗi phút).
    public static let capSlack = Int(24 * 3600 / HistoryLog.sampleInterval)
    /// Khoảng cách tối thiểu giữa hai lần dọn sớm do vượt giới hạn số dòng (tránh đọc lại file mỗi phút khi dọn lỗi).
    public static let minCapPruneInterval: TimeInterval = 3600

    /// Ghi một mẫu khi chưa có mẫu nào, khi đã qua `interval` kể từ mẫu trước, hoặc khi đồng hồ bị lùi
    /// (mẫu trước nằm ở tương lai). Thời gian ngủ được tính, nên mẫu đầu tiên sau khi thức (kể cả dark wake)
    /// luôn được ghi.
    public static func shouldRecord(now: Date, lastRecorded: Date?,
                                    interval: TimeInterval = HistoryLog.sampleInterval) -> Bool {
        guard let lastRecorded else { return true }
        let elapsed = now.timeIntervalSince(lastRecorded)
        return elapsed >= interval || elapsed < 0
    }

    /// Dọn khi chưa dọn lần nào (helper vừa khởi động), mỗi ngày một lần, khi đồng hồ bị lùi,
    /// hoặc khi số dòng đã vượt giới hạn quá `capSlack` (tối đa mỗi `minCapPruneInterval` một lần).
    public static func shouldPrune(now: Date, lastPruned: Date?, lineCount: Int?) -> Bool {
        guard let lastPruned else { return true }
        let elapsed = now.timeIntervalSince(lastPruned)
        if elapsed >= pruneInterval || elapsed < 0 { return true }
        if let lineCount, lineCount > maxSamples + capSlack { return elapsed >= minCapPruneInterval }
        return false
    }

    /// Giới hạn ghi vào mẫu: nil khi không giới hạn (mức hiệu lực 100%, kể cả lúc sạc đầy một lần).
    public static func recordedLimit(effectiveLimit: Int?) -> Int? {
        guard let effectiveLimit, effectiveLimit < 100 else { return nil }
        return effectiveLimit
    }

    /// Tạo mẫu từ thông tin pin và quyết định gần nhất của bộ điều khiển (cùng quy ước với mẫu do app ghi).
    public static func sample(now: Date, battery: BatteryInfo, temperature: Double?,
                              decision: ControlDecision?) -> HistorySample {
        HistorySample(date: now, percent: battery.percent, temperature: temperature,
                      batteryPower: battery.batteryPower, pluggedIn: battery.externalConnected,
                      charging: battery.isCharging, systemLoad: battery.systemLoad,
                      powerIn: battery.externalConnected ? battery.systemPowerIn : nil,
                      limit: recordedLimit(effectiveLimit: decision?.effectiveLimit),
                      reason: decision?.reason.rawValue)
    }

    /// Chỉ xóa mẫu quá hạn khi đã có ít nhất chừng này mẫu mới hơn (6 giờ dữ liệu).
    public static let minNewerSamples = 360

    /// Bỏ mẫu cũ hơn `retention` và chỉ giữ `maxCount` mẫu mới nhất. Đầu vào đã sắp xếp theo thời gian.
    ///
    /// Chống mất dữ liệu khi đồng hồ nhảy: bỏ mẫu nằm ở tương lai (quá `now` 5 phút, ví dụ sau khi đồng hồ bị
    /// lùi lại), và tính hạn giữ lại từ mẫu thứ `minNewerSamples` tính từ cuối thay vì từ `now`. Một lần chỉnh
    /// đồng hồ tới tương lai (vài mẫu ở tương lai) vì vậy không xóa được lịch sử thật; máy để lâu không dùng
    /// thì dữ liệu cũ vẫn được dọn sau khi đã có đủ mẫu mới.
    public static func pruned(_ samples: [HistorySample], now: Date,
                              retention: TimeInterval = HistoryLog.retention,
                              maxCount: Int = maxSamples,
                              minNewer: Int = minNewerSamples) -> [HistorySample] {
        let latestAllowed = now.addingTimeInterval(300)
        var kept = samples.filter { $0.date <= latestAllowed }
        guard let oldest = kept.first?.date else { return [] }
        let anchor = kept.count >= max(minNewer, 1) ? min(now, kept[kept.count - max(minNewer, 1)].date) : oldest
        let cutoff = anchor.addingTimeInterval(-retention)
        kept = kept.filter { $0.date >= cutoff }
        return kept.count > maxCount ? Array(kept.suffix(maxCount)) : kept
    }

    /// Dữ liệu nối vào cuối file: thêm xuống dòng trước nếu dòng cuối bị ghi dở (file không kết thúc bằng `\n`),
    /// để mẫu mới không dính vào dòng hỏng.
    public static func appendData(line: Data, previousLastByte: UInt8?) -> Data {
        guard let previousLastByte, previousLastByte != 0x0A else { return line }
        var data = Data([0x0A])
        data.append(line)
        return data
    }
}

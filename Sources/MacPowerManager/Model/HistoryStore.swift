import Foundation
import Observation
import PowerCore

/// Lịch sử pin hiển thị trong app: gộp lịch sử của helper (root, ghi mỗi phút kể cả khi app tắt hoặc máy chỉ thức
/// dậy chốc lát) với lịch sử app tự ghi (khi chưa có helper), giữ tối đa `HistoryLog.retention` (30 ngày).
@MainActor
@Observable
final class HistoryStore {
    /// Mẫu đã gộp từ hai nguồn, sắp xếp theo thời gian.
    private(set) var samples: [HistorySample] = []

    /// Lịch sử của helper được coi là "đang ghi" nếu mẫu cuối mới hơn mức này; khi đó app không tự ghi nữa.
    static let helperFreshness: TimeInterval = 3 * 60
    /// Chu kỳ đọc phần mới của file lịch sử helper.
    static let helperPollInterval: TimeInterval = 60

    @ObservationIgnored private var appSamples: [HistorySample] = []
    @ObservationIgnored private var helperSamples: [HistorySample] = []
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private let helperURL: URL?
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var helperPosition = HistoryFileTail.Position()
    @ObservationIgnored private var helperReadAt: Date?
    @ObservationIgnored private var helperReading = false
    /// Có giao diện đang hiển thị lịch sử (cửa sổ bảng điều khiển). Không ai xem thì không đọc file của helper:
    /// helper vẫn ghi đầy đủ, lần mở sau đọc bù phần mới.
    @ObservationIgnored var isLive = false {
        didSet {
            if isLive && !oldValue && helperURL != nil { Task { await refreshHelper() } }
        }
    }
    /// Mẫu trước thời điểm này bị ẩn (người dùng đã xóa lịch sử; file của helper thuộc root nên app không xóa được).
    @ObservationIgnored private var clearedAt: Date?

    private static let clearedAtKey = "history.clearedAt"

    convenience init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacPowerManager", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.init(fileURL: dir.appendingPathComponent("history.jsonl"), helperURL: PowerConstants.helperHistoryURL,
                  defaults: .standard)
        Task { await refreshHelper() }
    }

    /// `fileURL`: lịch sử app tự ghi; `helperURL`: lịch sử của helper (chỉ đọc).
    init(fileURL: URL?, helperURL: URL?, defaults: UserDefaults?, now: Date = Date()) {
        self.fileURL = fileURL
        self.helperURL = helperURL
        self.defaults = defaults
        clearedAt = defaults?.object(forKey: Self.clearedAtKey) as? Date
        loadAppFile(now: now)
        rebuild(now: now)
    }

    /// Dữ liệu cố định, không đọc/ghi file (xem trước, snapshot).
    init(samples: [HistorySample]) {
        fileURL = nil
        helperURL = nil
        defaults = nil
        appSamples = samples
        self.samples = samples
    }

    /// Helper đang ghi lịch sử (mẫu cuối chưa quá `helperFreshness`).
    func helperIsFresh(now: Date = Date()) -> Bool {
        if let last = helperSamples.last, now.timeIntervalSince(last.date) < Self.helperFreshness { return true }
        // Dữ liệu trong bộ nhớ có thể cũ (vừa mở app, vừa thức dậy, lần đọc file chưa xong): kiểm tra thêm thời điểm
        // file của helper được ghi lần cuối, việc này rẻ và đồng bộ.
        guard let helperURL,
              let modified = (try? FileManager.default.attributesOfItem(atPath: helperURL.path))?[.modificationDate] as? Date
        else { return false }
        return now.timeIntervalSince(modified) < Self.helperFreshness
    }

    /// Gọi định kỳ (mỗi lần đọc pin). Đọc phần mới của lịch sử helper mỗi `helperPollInterval`; app chỉ tự ghi mẫu
    /// khi helper không ghi (chưa cài, hoặc helper cũ chưa có lịch sử) để không trùng.
    func record(battery: BatteryInfo, temperature: Double?, limit: Int?, now: Date = Date()) {
        if helperURL != nil, isLive, !helperReading,
           helperReadAt.map({ now.timeIntervalSince($0) >= Self.helperPollInterval }) ?? true {
            helperReadAt = now
            Task { await refreshHelper(now: now) }
        }
        if helperIsFresh(now: now) { return }
        if let last = appSamples.last, now.timeIntervalSince(last.date) < HistoryLog.sampleInterval { return }
        let sample = HistorySample(date: now, percent: battery.percent, temperature: temperature,
                                   batteryPower: battery.batteryPower, pluggedIn: battery.externalConnected,
                                   charging: battery.isCharging, systemLoad: battery.systemLoad,
                                   powerIn: battery.externalConnected ? battery.systemPowerIn : nil, limit: limit)
        appSamples.append(sample)
        append(sample)
        if helperSamples.isEmpty, samples.last.map({ $0.date < sample.date }) ?? true {
            samples.append(sample)
        } else {
            rebuild(now: now)
        }
    }

    /// Đọc phần mới của file lịch sử helper (ở luồng nền); đọc lại từ đầu nếu file bị thu gọn hoặc thay thế.
    func refreshHelper(now: Date = Date()) async {
        guard let helperURL, !helperReading else { return }
        helperReading = true
        defer { helperReading = false }
        helperReadAt = now
        let position = helperPosition
        let cutoff = now.addingTimeInterval(-HistoryLog.retention)
        let chunk = await Task.detached(priority: .utility) {
            HistoryFileTail.read(helperURL, from: position, cutoff: cutoff)
        }.value
        guard let chunk else {
            // Không có file (chưa cài helper hoặc helper cũ): không có lịch sử từ helper.
            helperPosition = .init()
            if !helperSamples.isEmpty {
                helperSamples = []
                rebuild(now: now)
            }
            return
        }
        helperPosition = chunk.position
        guard chunk.reset || !chunk.samples.isEmpty else { return }
        if chunk.reset {
            helperSamples = chunk.samples
        } else {
            let needsSort = zip(helperSamples.last.map { [$0] } ?? [], chunk.samples.prefix(1)).contains { $0.date > $1.date }
            helperSamples.append(contentsOf: chunk.samples)
            if needsSort {
                helperSamples.sort { $0.date < $1.date }
            } else if appendIfNewer(chunk.samples) {
                // Trường hợp thường gặp: vài mẫu mới hơn mọi thứ đang có, chỉ cần nối vào cuối thay vì gộp và sắp xếp
                // lại cả 30 ngày.
                return
            }
        }
        rebuild(now: now)
    }

    /// Nối các mẫu mới của helper vào cuối `samples` nếu chúng mới hơn mọi mẫu đang có (kể cả mẫu của app).
    /// Mẫu cuối cùng phút với mẫu mới đầu tiên được thay (giống `HistoryLog.merge`: ưu tiên mẫu của helper).
    private func appendIfNewer(_ new: [HistorySample]) -> Bool {
        guard let first = new.first else { return true }
        let cutoff = clearedAt ?? .distantPast
        if let lastApp = appSamples.last, lastApp.date >= first.date { return false }
        guard samples.last.map({ $0.date < first.date }) ?? true else { return false }
        func minute(_ d: Date) -> Int { Int(d.timeIntervalSinceReferenceDate / 60) }
        if let last = samples.last, minute(last.date) == minute(first.date) { samples.removeLast() }
        samples.append(contentsOf: new.filter { $0.date >= cutoff })
        return true
    }

    func samples(within range: TimeInterval, now: Date = Date()) -> [HistorySample] {
        let cutoff = now.addingTimeInterval(-range)
        var lo = 0, hi = samples.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].date < cutoff { lo = mid + 1 } else { hi = mid }
        }
        return Array(samples[lo...])
    }

    /// Xóa lịch sử app tự ghi và ẩn lịch sử helper tới thời điểm này.
    func clear(now: Date = Date()) {
        appSamples = []
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        clearedAt = now
        defaults?.set(now, forKey: Self.clearedAtKey)
        rebuild(now: now)
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

    private func rebuild(now: Date) {
        let retained = now.addingTimeInterval(-HistoryLog.retention)
        if let first = helperSamples.first, first.date < retained { helperSamples.removeAll { $0.date < retained } }
        if let first = appSamples.first, first.date < retained { appSamples.removeAll { $0.date < retained } }
        let cutoff = max(retained, clearedAt ?? .distantPast)
        let helper = (helperSamples.first?.date ?? .distantFuture) >= cutoff ? helperSamples : helperSamples.filter { $0.date >= cutoff }
        let app = (appSamples.first?.date ?? .distantFuture) >= cutoff ? appSamples : appSamples.filter { $0.date >= cutoff }
        // Trường hợp thường gặp (chỉ có lịch sử helper): không cần gộp và sắp xếp lại ~43 nghìn mẫu mỗi phút.
        if app.isEmpty {
            samples = helper
        } else if helper.isEmpty {
            samples = app
        } else {
            samples = HistoryLog.merge(helper: helper, app: app)
        }
    }

    private func loadAppFile(now: Date) {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        appSamples = HistoryLog.decode(data, cutoff: now.addingTimeInterval(-HistoryLog.retention))
        // Ghi lại file để bỏ các mẫu đã quá hạn hoặc dòng hỏng.
        var output = Data()
        for sample in appSamples { if let line = HistoryLog.line(for: sample) { output.append(line) } }
        if output.count < data.count { try? output.write(to: fileURL, options: .atomic) }
    }

    private func append(_ sample: HistorySample) {
        guard let fileURL, let line = HistoryLog.line(for: sample) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: fileURL)
        }
    }
}

/// Đọc dần một file JSON Lines đang được ghi thêm (thuần, chạy được ở luồng nền).
enum HistoryFileTail {
    /// Vị trí đã đọc tới: số byte và mã file (inode) để nhận ra file bị thay thế khi helper thu gọn lịch sử.
    struct Position: Equatable, Sendable {
        var offset: UInt64 = 0
        var fileID: UInt64?
    }

    struct Chunk: Sendable {
        var samples: [HistorySample]
        /// `true`: đọc lại từ đầu, `samples` thay cho mọi mẫu trước đó.
        var reset: Bool
        var position: Position
    }

    /// Đọc các dòng hoàn chỉnh mới từ `position`; đọc lại từ đầu nếu file nhỏ đi hoặc là file khác. `nil` nếu không đọc được.
    static func read(_ url: URL, from position: Position, cutoff: Date?) -> Chunk? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let fileID = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        let reset = position.offset == 0 || size < position.offset || (position.fileID != nil && position.fileID != fileID)
        let start = reset ? 0 : position.offset
        guard (try? handle.seek(toOffset: start)) != nil else { return nil }
        let data = (try? handle.readToEnd()) ?? Data()
        // Chỉ nhận tới ký tự xuống dòng cuối cùng: dòng cuối có thể đang được ghi dở.
        guard let newline = data.lastIndex(of: 0x0A) else {
            return Chunk(samples: [], reset: reset, position: Position(offset: start, fileID: fileID))
        }
        let complete = data[data.startIndex...newline]
        return Chunk(samples: HistoryLog.decode(Data(complete), cutoff: cutoff), reset: reset,
                     position: Position(offset: start + UInt64(complete.count), fileID: fileID))
    }
}

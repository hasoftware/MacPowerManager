import Foundation

/// File JSON Lines của lịch sử: nối thêm từng dòng và dọn bằng cách ghi lại nguyên tử.
/// Không an toàn đa luồng: chỉ dùng từ một hàng đợi tuần tự.
/// Thư mục 0755 và file 0644 để app (người dùng thường) đọc được file do helper (root) ghi.
public final class HistoryFile {
    public let url: URL
    /// Số dòng trong file, biết được sau lần dọn đầu tiên (nil nếu chưa dọn lần nào).
    public private(set) var lineCount: Int?
    private var permissionsChecked = false

    public init(url: URL) {
        self.url = url
    }

    /// Nối một mẫu vào cuối file (tạo thư mục và file nếu chưa có).
    public func append(_ sample: HistorySample) throws {
        guard let line = HistoryLog.line(for: sample) else { throw CocoaError(.coderInvalidValue) }
        try prepareFile()
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        var lastByte: UInt8?
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            lastByte = try handle.read(upToCount: 1)?.first
            try handle.seekToEnd()
        }
        try handle.write(contentsOf: HistoryRecorderPolicy.appendData(line: line, previousLastByte: lastByte))
        lineCount = lineCount.map { $0 + 1 }
    }

    /// Thời điểm của mẫu cuối trong file (chỉ đọc vài KB cuối, đủ nhanh để gọi đồng bộ lúc khởi động).
    public func lastSampleDate() -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), end > 0 else { return nil }
        let start = end > 4096 ? end - 4096 : 0
        guard (try? handle.seek(toOffset: start)) != nil, let tail = try? handle.readToEnd() else { return nil }
        return HistoryLog.decode(tail).last?.date
    }

    /// Đọc file, bỏ dòng hỏng, mẫu quá hạn và mẫu vượt giới hạn số dòng; ghi lại nguyên tử nếu có thay đổi.
    /// Trả về các mẫu còn lại.
    @discardableResult
    public func prune(now: Date, retention: TimeInterval = HistoryLog.retention,
                      maxCount: Int = HistoryRecorderPolicy.maxSamples,
                      minNewer: Int = HistoryRecorderPolicy.minNewerSamples) throws -> [HistorySample] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            lineCount = 0
            return []
        }
        let rawLines = data.split(separator: 0x0A).count
        let kept = HistoryRecorderPolicy.pruned(HistoryLog.decode(data), now: now, retention: retention,
                                                maxCount: maxCount, minNewer: minNewer)
        let endsCleanly = data.last.map { $0 == 0x0A } ?? true
        if kept.count != rawLines || !endsCleanly {
            var out = Data()
            for sample in kept {
                if let line = HistoryLog.line(for: sample) { out.append(line) }
            }
            try ensureDirectory()
            try out.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            permissionsChecked = true
        }
        lineCount = kept.count
        return kept
    }

    private func ensureDirectory() throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        }
    }

    private func prepareFile() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try ensureDirectory()
            guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o644]) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
            lineCount = 0
        }
        if !permissionsChecked {
            // umask có thể bỏ bớt quyền khi tạo; file cũ có thể mang quyền khác.
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            permissionsChecked = true
        }
    }
}

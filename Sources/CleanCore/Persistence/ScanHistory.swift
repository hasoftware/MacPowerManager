import Foundation

/// So sánh với lần quét trước (`save_history_and_diff`).
public enum HistoryDiff: Sendable, Equatable {
    case firstScan
    /// `newIDs` sắp theo byte (UI hiện tối đa 10).
    case compared(previousDate: String, newCount: Int, goneCount: Int, newIDs: [String])
}

/// Lịch sử quét: `dataDir/ScanHistory/scan_<yyyyMMdd_HHmmss>.txt`, dòng 1 `# yyyy-MM-dd HH:mm`, sau đó mỗi
/// finding ID một dòng (sau khi áp ignore, theo thứ tự đã sắp). Giữ 12 file mới nhất.
public struct ScanHistory: Sendable {
    public static let keep = 12
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public init(env: ScanEnvironment) {
        self.directory = env.dataDir.appendingPathComponent("ScanHistory")
    }

    /// Các file lịch sử, tên tăng dần. Liệt kê thư mục rồi lọc theo mẫu tên: rỗng là rỗng (bản zsh từng `ls -1`
    /// trần khi chưa có lịch sử -> liệt kê thư mục hiện tại và đem so chính nó).
    public func files() -> [String] {
        FileProbe.childNames(directory.path).filter { $0.hasPrefix("scan_") && $0.hasSuffix(".txt") }
    }

    /// Ghi lần quét này rồi so với lần trước. Không tạo được thư mục → nil (bỏ qua lặng lẽ).
    @discardableResult
    public func saveAndDiff(ids: [String], now: Date) -> HistoryDiff? {
        let fm = FileManager.default
        guard (try? fm.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else { return nil }
        let prevName = files().last
        let stamp = BackupSession.timestamp(now)
        // Hai lần quét trong cùng một giây: thêm hậu tố, nếu không file mới ghi đè file cũ và diff thành 0/0.
        var name = "scan_\(stamp).txt"
        var n = 2
        while FileProbe.lexists(directory.appendingPathComponent(name).path) {
            name = "scan_\(stamp)_\(n).txt"
            n += 1
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let text = (["# \(f.string(from: now))"] + ids).joined(separator: "\n") + "\n"
        guard (try? Data(text.utf8).write(to: directory.appendingPathComponent(name), options: .atomic)) != nil else {
            return nil
        }
        // Giữ 12 file mới nhất
        let all = files()
        for old in all.dropLast(ScanHistory.keep) {
            try? fm.removeItem(at: directory.appendingPathComponent(old))
        }

        guard let prevName,
              let prevText = try? String(contentsOf: directory.appendingPathComponent(prevName), encoding: .utf8)
        else { return .firstScan }
        var prevLines = prevText.components(separatedBy: "\n")
        let prevDate = prevLines.isEmpty ? "" : String(prevLines.removeFirst().dropFirst(2))
        let prev = Set(prevLines.filter { !$0.isEmpty })
        let cur = Set(ids)
        let new = cur.subtracting(prev).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        return .compared(previousDate: prevDate, newCount: new.count, goneCount: prev.subtracting(cur).count, newIDs: new)
    }
}

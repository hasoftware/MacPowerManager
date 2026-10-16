import Foundation

/// Danh sách bỏ qua: văn bản thuần, mỗi dòng một finding ID (cùng định dạng `mactrash.ignore.txt`).
/// MacTrash cố tình KHÔNG dùng JSON (phải gọi python3, mà /usr/bin/python3 trên máy chưa cài Command Line Tools
/// sẽ bật hộp thoại cài đặt). Lý do không còn áp dụng nhưng giữ định dạng để tương thích.
public struct IgnoreList: Sendable {
    public static let fileName = "ignore.txt"
    /// Dòng đầu file (nội dung file, không phải chuỗi UI).
    public static let header = "# MacPowerManager - các mục đã ẩn vĩnh viễn (xóa dòng để hiện lại)"

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public init(env: ScanEnvironment) {
        self.url = env.dataDir.appendingPathComponent(IgnoreList.fileName)
    }

    /// Các ID theo thứ tự trong file. Không có file → rỗng. Bỏ dòng rỗng và dòng bắt đầu `#`; bỏ `\r` cuối dòng.
    public func load() -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n").compactMap { line in
            let l = line.hasSuffix("\r") ? String(line.dropLast()) : line
            return (l.isEmpty || l.hasPrefix("#")) ? nil : l
        }
    }

    /// `save_ignore`: hợp cũ + mới, khử trùng giữ lần xuất hiện đầu, ghi đè nguyên tử (header + mỗi ID một dòng).
    /// ID chứa xuống dòng bị bỏ (làm vỡ file).
    public func add(_ ids: [String]) throws {
        var seen = Set<String>()
        var all: [String] = []
        for id in load() + ids where !id.isEmpty && !id.contains("\n") && !id.contains("\r") && !seen.contains(id) {
            seen.insert(id)
            all.append(id)
        }
        try write(all)
    }

    /// Bỏ một số ID khỏi danh sách (hiện lại).
    public func remove(_ ids: Set<String>) throws {
        try write(load().filter { !ids.contains($0) })
    }

    private func write(_ ids: [String]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = ([IgnoreList.header] + ids).joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// `apply_ignore_list`: loại finding có ID thuộc danh sách (so chuỗi chính xác), đếm số bị loại.
    public static func apply(_ findings: [Finding], ignoring ids: Set<String>) -> (kept: [Finding], ignoredCount: Int) {
        let kept = findings.filter { !ids.contains($0.id) }
        return (kept, findings.count - kept.count)
    }
}

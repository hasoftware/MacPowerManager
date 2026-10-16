import Foundation

/// `scan_nativemsg`: native messaging host của trình duyệt trỏ tới file không tồn tại (spec B §11).
/// Gỡ chỉ đưa file manifest vào Thùng rác, không đụng gì khác.
public struct NativeMessagingScanner: Scanner {
    public init() {}

    public var id: String { "NativeMsg" }

    public func scan(_ context: ScanContext) throws -> [Finding] {
        let env = context.env
        let support = "\(env.homePath)/Library/Application Support"
        let dirs = [
            "\(support)/Google/Chrome/NativeMessagingHosts",
            "\(support)/Google/Chrome Canary/NativeMessagingHosts",
            "\(support)/Chromium/NativeMessagingHosts",
            "\(support)/BraveSoftware/Brave-Browser/NativeMessagingHosts",
            "\(support)/Microsoft Edge/NativeMessagingHosts",
            "\(support)/Vivaldi/NativeMessagingHosts",
            "\(support)/Arc/User Data/NativeMessagingHosts",
            "\(support)/Mozilla/NativeMessagingHosts",
            "/Library/Google/Chrome/NativeMessagingHosts",
            "/Library/Application Support/Mozilla/NativeMessagingHosts",
            "/Library/Application Support/Microsoft/Edge/NativeMessagingHosts",
        ]
        var out: [Finding] = []
        for d in dirs {
            try context.checkCancelled()
            guard env.isDirectory(d) else { continue }
            for j in env.list(d, .regularFiles, suffix: ".json") {
                try context.checkCancelled()
                guard let data = FileManager.default.contents(atPath: env.physicalPath(j)),
                      var target = NativeMessagingScanner.hostPath(data), !target.isEmpty else { continue }
                // Đường dẫn tương đối tính từ chính thư mục chứa manifest
                if !target.hasPrefix("/") { target = "\(d)/\(target)" }
                if env.exists(target) { continue }
                out.append(Finding(category: .nativeMsg, severity: .high,
                                   name: Names.removingSuffix(PathResolver.tail(j), ".json"), target: j,
                                   reason: .nativeHostDead(executable: target), action: .trashPath(path: j)))
            }
        }
        return out
    }

    /// Khóa `path` ở cấp gốc nếu JSON hợp lệ (giải đúng escape `\/` - lệch có chủ đích, khỏi báo sai).
    /// JSON hỏng → như zsh: lần khớp đầu tiên của `"path"[[:space:]]*:[[:space:]]*"[^"]*"` (grep -o, theo dòng).
    static func hostPath(_ data: Data) -> String? {
        if let obj = try? JSONSerialization.jsonObject(with: data, options: []) {
            return (obj as? [String: Any])?["path"] as? String
        }
        let text = String(decoding: data, as: UTF8.self)
        for line in text.components(separatedBy: "\n") {
            if let v = firstPathMatch(line) { return v }
        }
        return nil
    }

    /// Một dòng: `"path"` + khoảng trắng + `:` + khoảng trắng + `"` + giá trị không chứa `"` + `"`.
    static func firstPathMatch(_ line: String) -> String? {
        var search = line.startIndex
        while let key = line.range(of: "\"path\"", range: search..<line.endIndex) {
            search = line.index(after: key.lowerBound)
            var i = line[key.upperBound...].drop(while: EnvironmentScanner.isZshSpace).startIndex
            guard i < line.endIndex, line[i] == ":" else { continue }
            i = line[line.index(after: i)...].drop(while: EnvironmentScanner.isZshSpace).startIndex
            guard i < line.endIndex, line[i] == "\"" else { continue }
            let valueStart = line.index(after: i)
            guard let close = line[valueStart...].firstIndex(of: "\"") else { continue }
            return String(line[valueStart..<close])
        }
        return nil
    }
}

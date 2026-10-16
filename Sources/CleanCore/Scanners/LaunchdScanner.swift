import Foundation

/// `scan_launchd`: job launchd trỏ tới chương trình không còn (spec A §3.8-3.9).
/// `/System/Library/Launch*` do SIP bảo vệ - không đụng tới. Plist trong `/Library` → LaunchdJob cần quyền quản trị.
public struct LaunchdScanner: Scanner {
    public init() {}

    public var id: String { "LaunchAgent" }

    public func scan(_ context: ScanContext) throws -> [Finding] {
        let env = context.env
        var out: [Finding] = []
        for d in ["\(env.homePath)/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons"] {
            guard env.isDirectory(d) else { continue }
            let domain = env.launchdDomain(forPlistIn: d)
            for f in env.list(d, .regularFiles, suffix: ".plist") {
                try context.checkCancelled()
                let label = env.launchdLabel(plist: f)
                // plist hỏng/không đọc được, hoặc chỉ có BundleProgram → bỏ qua
                guard let prog = env.launchdProgram(plist: f) else { continue }
                let missing: Bool
                if !prog.hasPrefix("/"), prog.contains("/") {
                    // Đường dẫn tương đối: launchd chạy job từ WorkingDirectory (mặc định `/`), không phải cwd của
                    // tiến trình quét (bản gốc lệ thuộc cwd của shell - lệch có chủ đích)
                    let wd = env.plistString(f, "WorkingDirectory").flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/"
                    missing = env.existence(PathResolver.lexical(prog, cwd: wd)) == .missing
                } else if !prog.hasPrefix("/") {
                    // Lệnh trần (không phải đường dẫn tuyệt đối): tra trong PATH của người dùng
                    missing = !env.commandExists(prog)
                } else {
                    // Chỉ "chắc chắn không có" mới tính. Không xem được (thiếu quyền/TCC) hoặc nằm trên ổ ngoài
                    // đang rút: job vẫn có thể đang chạy tốt -> không báo.
                    missing = env.existence(prog) == .missing
                }
                // CỐ Ý không suy đoán thêm từ nhãn job. Nhãn hay lệch với bundle id thật (Riot Client có bid
                // com.riotgames.RiotGames.RiotClient nhưng nhãn là com.riot.riotclient.*) -> đoán theo nhãn chỉ đẻ ra
                // báo nhầm. File nào còn chương trình thật thì để yên; "binary không tồn tại" mới là bằng chứng.
                guard missing else { continue }
                out.append(Finding(category: .launchAgent, severity: .high, name: label, target: f,
                                   reason: .missingProgram(prog), sizeBytes: 0,
                                   action: .launchdJob(plist: f, label: label, domain: domain)))
            }
        }
        return out
    }
}

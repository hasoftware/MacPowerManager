import Foundation

/// `scan_symlinks`: symlink gãy trong các thư mục bin/lib/Frameworks (spec B §9).
/// Chỉ cấp 1, không đệ quy. Gỡ = đưa chính symlink vào Thùng rác, đích ghi vào manifest để tạo lại được.
public struct SymlinkScanner: Scanner {
    public init() {}

    public var id: String { "Symlink" }

    public func scan(_ context: ScanContext) throws -> [Finding] {
        let env = context.env
        let h = env.homePath
        let bindirs = ["/usr/local/bin", "/usr/local/sbin", "/opt/homebrew/bin", "/opt/homebrew/sbin",
                       "\(h)/bin", "\(h)/.local/bin", "/usr/local/lib", "/opt/homebrew/lib",
                       "/Library/Frameworks", "\(h)/Library/Frameworks"]
        var out: [Finding] = []
        for d in bindirs {
            try context.checkCancelled()
            guard env.isDirectory(d) else { continue }
            for l in env.list(d, .symlinks) {
                try context.checkCancelled()
                // -e đi xuyên symlink -> false = gãy (chuỗi gãy ở giữa, vòng lặp ELOOP đều tính). Đích không xem
                // được (thiếu quyền/TCC) hoặc trên ổ ngoài chưa mount: link vẫn có thể đúng -> không báo.
                if env.symlinkTargetExistence(l) != .missing { continue }
                let t = env.readlink(l) ?? ""
                out.append(Finding(category: .symlink, severity: .high, name: PathResolver.tail(l), target: l,
                                   reason: .brokenSymlink(destination: t.isEmpty ? "?" : t), action: .symlink(path: l)))
            }
        }
        return out
    }
}

import Foundation

/// Lý do `is_deletable_path` từ chối (theo thứ tự kiểm tra).
public enum DeleteRefusal: String, Sendable, Codable, Equatable {
    /// đường dẫn không hợp lệ (rỗng / tương đối)
    case invalidPath
    /// thư mục hệ thống trọng yếu (NEVER_DELETE)
    case criticalSystemDir
    /// vùng do SIP bảo vệ
    case sipProtected
    /// chính thư mục nhà
    case homeDir
    /// thư mục nhà của người dùng khác (kể cả /Users/Shared)
    case otherUserHome
    /// thư mục ở gốc ổ đĩa
    case rootLevel
    /// dữ liệu của chính app (backup/manifest/ignore) hoặc thư mục chứa nó
    case ownAppData
}

/// Các chốt an toàn. Mọi phép so sánh làm trên đường dẫn LOGIC đã phân giải (`env.resolved`), cả hai vế,
/// để test với root giả vẫn dùng danh sách nguyên bản.
public enum SafetyGuards {
    /// NEVER_DELETE (nguyên văn MacTrash).
    public static let neverDelete: [String] = [
        "/", "/System", "/Library", "/Users", "/Applications", "/private", "/var", "/etc", "/tmp", "/opt", "/usr",
        "/bin", "/sbin", "/cores", "/Volumes", "/home", "/net", "/dev", "/private/var", "/private/etc",
        "/private/tmp", "/private/var/db", "/private/var/folders", "/usr/local", "/usr/bin", "/usr/sbin", "/usr/lib",
        "/usr/libexec", "/usr/share", "/Library/Apple", "/Library/Developer", "/Library/Frameworks",
        "/Library/Keychains", "/Library/Preferences", "/Library/Application Support", "/Library/LaunchDaemons",
        "/Library/LaunchAgents", "/Library/Extensions", "/Library/Security",
    ]

    /// `is_sip_path`: bắt đầu bằng `/System/`, `/usr/lib/`, `/usr/libexec/`, `/bin/`, `/sbin/`, `/usr/bin/`,
    /// `/usr/sbin/`. Bản thân `/System` không khớp (đã có trong NEVER_DELETE). `/usr/local` không phải SIP.
    public static func isSIPPath(_ p: String) -> Bool {
        ["/System/", "/usr/lib/", "/usr/libexec/", "/bin/", "/sbin/", "/usr/bin/", "/usr/sbin/"]
            .contains { p.hasPrefix($0) }
    }

    /// Thư mục dữ liệu cá nhân (dưới thư mục nhà thật) cần hỏi kỹ trước khi xóa.
    public static let preciousHomeDirs = ["Documents", "Desktop", "Pictures", "Movies", "Music", "Downloads"]
}

extension ScanEnvironment {
    /// `is_deletable_path`: lý do từ chối đầu tiên gặp, nil = được phép.
    /// Trình duyệt dung lượng cho phép xóa BẤT KỲ thứ gì nó thấy, khác hẳn các module quét (chỉ đụng vào mục do
    /// chính chúng tìm ra). Nên phải có danh sách cấm rõ ràng: xóa nhầm /Library hay ~ là hỏng máy. Áp dụng cho cả
    /// TrashPath - chuyển /Library vào Thùng rác cũng hỏng máy y như xóa thẳng.
    public func deletionRefusal(for p: String) -> DeleteRefusal? {
        guard !p.isEmpty, p.hasPrefix("/") else { return .invalidPath }
        let rp = resolved(p)
        for n in SafetyGuards.neverDelete where p == n || rp == resolved(n) {
            return .criticalSystemDir
        }
        if SafetyGuards.isSIPPath(rp) { return .sipProtected }
        if rp == resolved(realUserHomePath) || rp == resolved(homePath) { return .homeDir }
        for u in list("/Users", .directories) where rp == resolved(u) {
            return .otherUserHome
        }
        // chỉ một cấp dưới gốc
        if !rp.dropFirst().contains("/") { return .rootLevel }
        if isOwnDataPath(p) { return .ownAppData }
        return nil
    }

    public func isDeletablePath(_ p: String) -> Bool { deletionRefusal(for: p) == nil }

    /// `is_trash_path` - chốt DUY NHẤT cho xóa vĩnh viễn.
    /// Phân giải THƯ MỤC CHA (không phải chính mục đó) để vừa chặn được ".." vừa không đi xuyên qua symlink nằm
    /// trong Thùng rác - phân giải thẳng trên mục sẽ trả về đích của symlink, tức một chỗ nằm ngoài Thùng rác, và mục
    /// đó vĩnh viễn không xóa được. Bản thân thư mục gốc Thùng rác cũng bị từ chối: chỉ xóa được thứ BÊN TRONG.
    public func isTrashPath(_ p: String) -> Bool {
        guard !p.isEmpty, p.hasPrefix("/") else { return false }
        let t = PathResolver.tail(p)
        if t.isEmpty || t == "." || t == ".." { return false }
        let dir = resolved(PathResolver.parent(p))
        var roots = [userTrashPath, homePath + "/.Trash"]
        // Thùng rác của root: chỉ tính khi đang chạy bằng root
        if isRoot { roots.append("/var/root/.Trash") }
        for r in roots where !r.isEmpty {
            // PHẢI phân giải cả hai vế: /var là symlink tới /private/var, so đường dẫn đã phân giải với chuỗi thô
            // thì KHÔNG BAO GIỜ khớp - chốt sẽ từ chối nhầm chính những mục hợp lệ (đã xảy ra: 67/67 mục).
            let rr = resolved(r)
            if dir == rr || dir.hasPrefix(rr + "/") { return true }
        }
        // /Volumes/*/.Trashes/*  (`*` khớp cả `/`)
        if dir.hasPrefix("/Volumes/"), let r = dir.range(of: "/.Trashes/"),
           r.lowerBound > dir.index(dir.startIndex, offsetBy: "/Volumes".count) {
            return true
        }
        return false
    }

    /// `is_precious_path`: dưới `~/Documents|Desktop|Pictures|Movies|Music|Downloads` (của người dùng thật) hoặc
    /// bắt đầu bằng chuỗi `~/Library/Mobile Documents` (iCloud Drive).
    public func isPreciousPath(_ p: String) -> Bool {
        let rp = resolved(p)
        let h = resolved(realUserHomePath)
        for d in SafetyGuards.preciousHomeDirs {
            let base = h + "/" + d
            if rp == base || rp.hasPrefix(base + "/") { return true }
        }
        return rp.hasPrefix(h + "/Library/Mobile Documents")
    }
}

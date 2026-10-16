import Foundation

/// Kiểu gỡ (`F_KIND` của MacTrash). Raw value đúng chuỗi zsh, dùng trong manifest.
public enum CleanKind: String, Sendable, Codable, CaseIterable, Hashable {
    case reportOnly = "ReportOnly"
    case trashPath = "TrashPath"
    case symlink = "Symlink"
    case pathEntry = "PathEntry"
    case envLine = "EnvLine"
    case launchdJob = "LaunchdJob"
    case pkgReceipt = "PkgReceipt"
    case firewallApp = "FirewallApp"
    case tccReset = "TccReset"
    case lsRebuild = "LsRebuild"
    case simulator = "Simulator"
    case snapshot = "Snapshot"
    case purgeAny = "PurgeAny"
    case purgeTrash = "PurgeTrash"
}

/// Cách gỡ kèm payload (`F_DATA`). Mọi đường dẫn là đường dẫn logic.
public enum CleanAction: Sendable, Codable, Hashable {
    /// Chỉ báo, không bao giờ tự gỡ.
    case reportOnly
    /// Chuyển vào Thùng rác.
    case trashPath(path: String)
    /// Gỡ symlink gãy (ghi đích vào manifest để tạo lại được).
    case symlink(path: String)
    /// Bỏ một thư mục khỏi PATH trong `file` (/etc/paths*: xóa dòng; file shell: comment dòng).
    case pathEntry(file: String, dir: String)
    /// Comment dòng khai báo biến môi trường `line` (nguyên văn) trong `file`.
    case envLine(file: String, line: String)
    /// Gỡ job launchd: bootout `domain/label` rồi đưa `plist` vào Thùng rác. `domain` = `gui/<uid>` hoặc `system`.
    case launchdJob(plist: String, label: String, domain: String)
    /// Quên biên nhận gói (luôn cần admin).
    case pkgReceipt(id: String)
    /// Xóa luật tường lửa (luôn cần admin).
    case firewallApp(path: String)
    /// `tccutil reset <service> <client>`; `service` đã bỏ tiền tố `kTCCService`.
    case tccReset(service: String, client: String)
    /// Dựng lại CSDL LaunchServices.
    case lsRebuild
    /// `xcrun simctl delete unavailable` (P3).
    case simulator
    /// Xóa snapshot Time Machine cục bộ (P3, luôn cần admin).
    case snapshot(name: String)
    /// Xóa vĩnh viễn bất kỳ (trình duyệt dung lượng, P2) - không hoàn tác được.
    case purgeAny(path: String)
    /// Xóa vĩnh viễn mục trong Thùng rác (P2) - không hoàn tác được.
    case purgeTrash(path: String)

    public var kind: CleanKind {
        switch self {
        case .reportOnly: return .reportOnly
        case .trashPath: return .trashPath
        case .symlink: return .symlink
        case .pathEntry: return .pathEntry
        case .envLine: return .envLine
        case .launchdJob: return .launchdJob
        case .pkgReceipt: return .pkgReceipt
        case .firewallApp: return .firewallApp
        case .tccReset: return .tccReset
        case .lsRebuild: return .lsRebuild
        case .simulator: return .simulator
        case .snapshot: return .snapshot
        case .purgeAny: return .purgeAny
        case .purgeTrash: return .purgeTrash
        }
    }

    /// Payload dạng zsh (các trường nối bằng `\u{1f}`), để đối chiếu/xuất.
    public var zshData: String {
        let sep = "\u{1f}"
        switch self {
        case .reportOnly, .lsRebuild, .simulator: return ""
        case .trashPath(let p), .symlink(let p), .firewallApp(let p), .purgeAny(let p), .purgeTrash(let p): return p
        case .pathEntry(let f, let d): return f + sep + d
        case .envLine(let f, let l): return f + sep + l
        case .launchdJob(let p, let l, let d): return p + sep + l + sep + d
        case .pkgReceipt(let id): return id
        case .tccReset(let s, let c): return s + sep + c
        case .snapshot(let n): return n
        }
    }
}

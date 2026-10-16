import Foundation

/// Mức độ của một mục tìm thấy. Raw value đúng chuỗi MacTrash (`High`/`Medium`/`Info`).
public enum Severity: String, Sendable, Codable, CaseIterable, Hashable {
    case high = "High"
    case medium = "Medium"
    case info = "Info"

    /// Thứ hạng khi sắp xếp (`sort_findings`): High 1, Medium 2, còn lại 3.
    public var rank: Int {
        switch self {
        case .high: return 1
        case .medium: return 2
        case .info: return 3
        }
    }
}

/// Nhóm của mục tìm thấy. Raw value PHẢI đúng chuỗi zsh vì nằm trong finding ID
/// (ignore.txt cũ của MacTrash còn khớp). Chú ý hoa/thường: `TCC`, `HTTPStorage`, `SysExt`, `NativeMsg`.
public enum CleanCategory: String, Sendable, Codable, CaseIterable, Hashable {
    case path = "Path"
    case envVar = "EnvVar"
    case appSupport = "AppSupport"
    case caches = "Caches"
    case prefs = "Prefs"
    case containers = "Containers"
    case groupContainer = "GroupContainer"
    case savedState = "SavedState"
    case httpStorage = "HTTPStorage"
    case webKit = "WebKit"
    case appScripts = "AppScripts"
    case cookies = "Cookies"
    case logs = "Logs"
    case launchAgent = "LaunchAgent"   // dùng cho cả LaunchDaemons
    case loginItem = "LoginItem"
    case helper = "Helper"
    case receipt = "Receipt"
    case security = "Security"
    case firewall = "Firewall"
    case tcc = "TCC"
    case sysExt = "SysExt"
    case symlink = "Symlink"
    case launchServices = "LaunchServices"
    case nativeMsg = "NativeMsg"
    case plugin = "Plugin"
    case app = "App"
    case docker = "Docker"
    case xcode = "Xcode"
    case devCache = "DevCache"
    case homebrew = "Homebrew"
    case backup = "Backup"
    case snapshot = "Snapshot"
    case trash = "Trash"
    case appFiles = "AppFiles"         // luồng gỡ app (P1)
    case disk = "Disk"                 // trình duyệt dung lượng (P2)
}

/// Một mục tìm thấy. Quét chỉ sinh ra giá trị này, không đụng gì tới đĩa.
///
/// `name` và `target` là DỮ LIỆU (nằm trong ID), không phải chuỗi giao diện; UI hiển thị theo `reason`.
/// `target` là đường dẫn LOGIC (như trên máy thật, không mang tiền tố root giả của test) hoặc một định danh.
public struct Finding: Sendable, Codable, Hashable, Identifiable {
    public var category: CleanCategory
    public var severity: Severity
    public var name: String
    public var target: String
    public var reason: CleanReason
    /// Dung lượng cấp phát (byte), như `du -sxk` × 1024. 0 khi không tính.
    public var sizeBytes: Int64
    /// Cách gỡ kèm dữ liệu (payload).
    public var action: CleanAction
    /// Cần quyền quản trị để gỡ. ScanEngine điền sau khi quét; Remover tính lại lúc gỡ.
    public var needsAdmin: Bool

    public init(category: CleanCategory, severity: Severity, name: String, target: String,
                reason: CleanReason, sizeBytes: Int64 = 0, action: CleanAction, needsAdmin: Bool = false) {
        self.category = category
        self.severity = severity
        self.name = name
        self.target = target
        self.reason = reason
        self.sizeBytes = max(0, sizeBytes)
        self.action = action
        self.needsAdmin = needsAdmin
    }

    /// ID ổn định `category|name|target` y hệt `finding_id` của MacTrash. Không escape, không trim.
    public var id: String { Finding.makeID(category: category, name: name, target: target) }

    public static func makeID(category: CleanCategory, name: String, target: String) -> String {
        "\(category.rawValue)|\(name)|\(target)"
    }

    /// MB nguyên (KiB / 1024, làm tròn xuống) như `size_mb`. Dùng để sắp xếp và hạ mức.
    public var sizeMB: Int { Int(sizeBytes / 1_048_576) }

    public var kind: CleanKind { action.kind }
}

/// Các literal nằm trong finding ID. Chỉ dùng cho ID (giữ nguyên byte để ignore.txt cũ còn khớp),
/// UI không hiển thị chúng mà dịch theo `reason`.
public enum FindingLiteral {
    /// target của mục PATH rỗng.
    public static let emptyPathTarget = "<rỗng>"
    /// name của mục PATH thứ `i` (đếm từ 1, tính cả mục rỗng).
    public static func pathEntryName(_ i: Int) -> String { "PATH #\(i)" }
    /// name/target của mục đăng nhập nền khi không có quyền root.
    public static let backgroundTaskName = "Background Task Management"
    public static let backgroundTaskTarget = "(sfltool dumpbtm)"
    /// name của mục LaunchServices: "<n> bản ghi ma".
    public static func ghostRecordsName(_ n: Int) -> String { "\(n) bản ghi ma" }
    public static let dyldName = "DYLD_INSERT_LIBRARIES"
    public static func sudoersName(_ file: String) -> String { "sudoers.d/\(file)" }
    public static let trashName = "Thùng rác"
    public static let simulatorTarget = "simctl delete unavailable"
    public static func simulatorName(_ n: Int) -> String { "\(n) simulator" }
    public static let homebrewCacheName = "Homebrew cache"
    public static let libraryDeveloperName = "Library/Developer"
    public static func archiveName(_ x: String) -> String { "Archives/\(x)" }
}

extension Array where Element == Finding {
    /// Sắp xếp như `sort_findings`: severity tăng dần, MB giảm dần, rồi thứ tự chèn ban đầu (ổn định).
    public func sortedForReport() -> [Finding] {
        enumerated().sorted { a, b in
            if a.element.severity.rank != b.element.severity.rank {
                return a.element.severity.rank < b.element.severity.rank
            }
            if a.element.sizeMB != b.element.sizeMB { return a.element.sizeMB > b.element.sizeMB }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Tổng dung lượng (byte) như `total_size_mb`.
    public var totalSizeBytes: Int64 { reduce(0) { $0 + $1.sizeBytes } }
}

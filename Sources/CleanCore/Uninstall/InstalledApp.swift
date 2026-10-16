import CoreServices
import Foundation

/// Một app đã cài (luồng gỡ ứng dụng, P1). Mọi đường dẫn là đường dẫn LOGIC.
public struct InstalledApp: Sendable, Hashable, Codable, Identifiable {
    /// Đường dẫn như liệt kê được (có thể là symlink `.app`).
    public var path: String
    /// Bundle thật: = `path`, hoặc đích đã phân giải khi `path` là symlink.
    public var bundlePath: String
    /// Tên file bỏ `.app` - tên MacTrash dùng để khớp.
    public var name: String
    /// `CFBundleDisplayName` / `CFBundleName` khác `name` (VS Code: file "Visual Studio Code", CFBundleName "Code").
    public var bundleNames: [String]
    public var bundleID: String?
    /// `CFBundleShortVersionString`, thiếu thì `CFBundleVersion`.
    public var version: String?
    public var teamID: String?
    /// `com.apple.security.application-groups` của app chính (nguyên văn).
    public var appGroups: [String]
    /// Khóa của `SMPrivilegedExecutables` = label helper root cài vào `/Library/PrivilegedHelperTools`.
    public var privilegedHelpers: [String]
    /// `kMDItemLastUsedDate` (nil khi Spotlight không biết).
    public var lastUsed: Date?

    public var id: String { path }

    public init(path: String, bundlePath: String? = nil, name: String, bundleNames: [String] = [],
                bundleID: String? = nil, version: String? = nil, teamID: String? = nil, appGroups: [String] = [],
                privilegedHelpers: [String] = [], lastUsed: Date? = nil) {
        self.path = path
        self.bundlePath = bundlePath ?? path
        self.name = name
        self.bundleNames = bundleNames
        self.bundleID = bundleID
        self.version = version
        self.teamID = teamID
        self.appGroups = appGroups
        self.privilegedHelpers = privilegedHelpers
        self.lastUsed = lastUsed
    }

    /// App của Apple (bundle id `com.apple.*`).
    public var isApple: Bool { bundleID?.lowercased().hasPrefix("com.apple.") ?? false }

    /// Tham chiếu gọn gắn vào lý do của từng file.
    public var ref: AppRef { AppRef(name: name, path: path) }
}

/// Chủ của một file được gom: tên hiển thị (tên file) + đường dẫn app (khóa duy nhất).
public struct AppRef: Sendable, Hashable, Codable {
    public var name: String
    public var path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

/// Vì sao một file được gom cho app (thứ tự = độ mạnh của bằng chứng, mạnh trước).
public enum AppFileMatch: String, Sendable, Codable, Hashable, CaseIterable {
    /// Tên (đã bỏ đuôi .plist/.savedState/.binarycookies/.json) = bundle id hoặc `bid.*`.
    case bundleID
    /// Như trên nhưng tên mang tiền tố Team ID / `group.` (`UBF8T346G9.com.foo.App`).
    case teamPrefixedBundleID
    /// = bundle id của appex / login item nằm trong bundle (cùng vendor).
    case embeddedBundleID
    /// `~/Library/Containers/<x>` có `MCMMetadataIdentifier` = bundle id hoặc `bid.*`.
    case containerMetadata
    /// Group Container đúng một App Group khai trong chữ ký của app (hoặc appex của nó).
    case appGroup
    /// Job launchd có `Label` = bundle id hoặc `bid.*`.
    case launchdLabel
    /// Job launchd có `AssociatedBundleIdentifiers` chứa bundle id.
    case launchdAssociatedBundle
    /// `Program`/`ProgramArguments[0]` của job launchd nằm trong bundle.
    case launchdProgramInBundle
    /// Helper root (hoặc plist LaunchDaemon của nó) khai trong `SMPrivilegedExecutables` của app.
    case privilegedHelper
    /// Tên chuẩn hóa = tên file `.app` chuẩn hóa.
    case name
    /// Tên chuẩn hóa = `CFBundleName`/`CFBundleDisplayName` chuẩn hóa.
    case bundleName
    /// Thư mục con của thư mục vendor: `Application Support/Google/Chrome` cho "Google Chrome" (vendor = từ đầu của
    /// tên app VÀ thành phần thứ hai của bundle id; tên con = phần còn lại của tên app hoặc tên trong Info.plist).
    case vendorSubfolder
    /// Biên nhận gói có id = bundle id hoặc `bid.*`.
    case packageReceipt
    /// Symlink `.app` trỏ tới bundle (bundle thật được gom riêng).
    case appSymlink
    /// Cache bộ cập nhật electron-builder: `~/Library/Application Support/Caches/<tên app>-updater`.
    case updaterCache
    /// Dữ liệu dựng lại được của Xcode trong `~/Library/Developer/Xcode` (DerivedData, DeviceSupport).
    case developerData
    /// `~/Library/Developer/Xcode/Archives`: dữ liệu người dùng (bản build đã nộp) - chỉ báo.
    case developerArchives

    // Bậc khớp GẦN ĐÚNG: không bao giờ nằm trong "Chọn tất cả", luôn kèm cảnh báo.
    /// Tên bắt đầu bằng tên app (`ZaloPC`, `ZaloData` cho "Zalo"), khi không app nào khác có tên là tiền tố của nó.
    case namePrefix
    /// Tên = các thành phần của bundle id sau TLD ghép lại (`com.ledger.live` → "Ledger Live").
    case bundleIDWords
    /// Chính thư mục hãng (`/Library/Application Support/Cloudflare`) khi chỉ app này mang tên hãng đó.
    case vendorFolder

    /// Khớp gần đúng: người dùng phải tự xem kỹ, không gộp vào "Chọn tất cả".
    public var isLowConfidence: Bool {
        switch self {
        case .namePrefix, .bundleIDWords, .vendorFolder: true
        default: false
        }
    }
}

/// Vì sao một app KHÔNG được đưa vào danh sách gỡ.
public enum AppExclusion: String, Sendable, Codable, Hashable {
    /// Nằm (hoặc trỏ tới) `/System` - SIP, không gỡ được (Safari là symlink vào Cryptex).
    case system
    /// Chính MacPowerManager.
    case ownApp
    /// Nằm trong một bundle khác (gỡ app chủ thì nó đi theo).
    case nestedInBundle
    /// Đã nằm trong Thùng rác.
    case inTrash
}

/// Một tiến trình đang chạy (để chặn gỡ app đang mở).
public struct RunningProcess: Sendable, Hashable {
    public var pid: Int32
    /// Đường dẫn file thực thi (vật lý, đã phân giải như `proc_pidpath`).
    public var executablePath: String
    /// Tiến trình cha (0 = không rõ) - để nói ai đã chạy helper.
    public var ppid: Int32

    public init(pid: Int32, executablePath: String, ppid: Int32 = 0) {
        self.pid = pid
        self.executablePath = executablePath
        self.ppid = ppid
    }

    /// Tên file thực thi.
    public var name: String { PathResolver.tail(executablePath) }
}

/// Seam liệt kê tiến trình đang chạy. Test dùng bản giả.
public protocol RunningProcessLister: Sendable {
    func runningProcesses() -> [RunningProcess]
}

/// Đọc bảng tiến trình bằng libproc (`proc_listallpids` + `proc_pidpath`): không cần AppKit, bắt được cả helper
/// chạy từ bên trong bundle (login item, agent). Vài ms, chỉ gọi khi người dùng mở danh sách/bấm gỡ.
public struct ProcessTableLister: RunningProcessLister {
    public init() {}

    public func runningProcesses() -> [RunningProcess] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = pids.withUnsafeMutableBufferPointer { buf in
            proc_listallpids(buf.baseAddress, Int32(buf.count * MemoryLayout<pid_t>.size))
        }
        guard got > 0 else { return [] }
        var out: [RunningProcess] = []
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(got)) where pid > 0 {
            let len = proc_pidpath(pid, &buf, UInt32(buf.count))
            guard len > 0 else { continue }
            var info = proc_bsdinfo()
            let got = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
            let ppid = got == Int32(MemoryLayout<proc_bsdinfo>.size) ? Int32(info.pbi_ppid) : 0
            out.append(RunningProcess(pid: pid, executablePath: String(cString: buf), ppid: ppid))
        }
        return out
    }
}

/// Không có tiến trình nào (test mặc định).
public struct NoRunningProcesses: RunningProcessLister {
    public init() {}
    public func runningProcesses() -> [RunningProcess] { [] }
}

/// Seam đọc ngày dùng gần nhất (`kMDItemLastUsedDate`). `path` là đường dẫn VẬT LÝ.
public protocol AppUsageReader: Sendable {
    func lastUsedDate(atPath path: String) -> Date?
}

/// Đọc bằng Spotlight (MDItem), không chạy lệnh ngoài. Spotlight tắt → nil.
public struct SpotlightUsageReader: AppUsageReader {
    public init() {}

    public func lastUsedDate(atPath path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}

/// Không đọc (test).
public struct NoUsageReader: AppUsageReader {
    public init() {}
    public func lastUsedDate(atPath path: String) -> Date? { nil }
}

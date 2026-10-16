import Foundation

/// Cách lọc khi liệt kê thư mục - tương ứng glob zsh (script bật `NULL_GLOB`, KHÔNG `GLOB_DOTS`).
public enum ListFilter: Sendable {
    /// `*(N)`: mọi mục (file, thư mục, symlink, symlink gãy).
    case any
    /// `*(N/)`: thư mục THẬT (lstat: symlink tới thư mục KHÔNG tính).
    case realDirectories
    /// `*(N.)`: file thường thật (lstat: symlink KHÔNG tính).
    case regularFiles
    /// `*(N@)`: chỉ symlink.
    case symlinks
    /// `*/` hoặc `[[ -d ]]`: thư mục, có đi xuyên symlink.
    case directories
}

/// Tiện ích đĩa trên đường dẫn LOGIC (tự đổi sang vật lý). Bộ quét chỉ nên dùng các hàm này.
extension ScanEnvironment {
    // MARK: Kiểm tra

    /// `[[ -e p ]]` (symlink gãy = không tồn tại).
    public func exists(_ p: String) -> Bool { FileProbe.exists(physicalPath(p)) }
    /// `-e` ba trạng thái. Thêm: đường dẫn dưới `/Volumes/<tên>` mà ổ đó đang không mount → `.unknown`
    /// (ổ ngoài rút ra lúc quét không làm job/PATH trỏ vào nó thành "rác").
    public func existence(_ p: String) -> FileProbe.Existence {
        let e = FileProbe.existence(physicalPath(p))
        guard e == .missing else { return e }
        return isOnUnmountedVolume(p) ? .unknown : .missing
    }

    /// Symlink: trạng thái của ĐÍCH (đi xuyên link), kể cả đích nằm trên ổ chưa mount.
    public func symlinkTargetExistence(_ link: String) -> FileProbe.Existence {
        let e = existence(link)
        guard e == .missing, let dest = readlink(link), !dest.isEmpty else { return e }
        let abs = dest.hasPrefix("/") ? dest : PathResolver.parent(link) + "/" + dest
        return isOnUnmountedVolume(abs) ? .unknown : .missing
    }

    /// `/Volumes/<tên>[/...]` mà `/Volumes/<tên>` không tồn tại.
    public func isOnUnmountedVolume(_ p: String) -> Bool {
        let lex = PathResolver.lexical(p)
        guard lex.hasPrefix("/Volumes/") else { return false }
        let comps = lex.split(separator: "/")
        guard comps.count >= 2 else { return false }
        return !lexists("/Volumes/" + comps[1])
    }

    /// `[[ -e p || -L p ]]`.
    public func lexists(_ p: String) -> Bool { FileProbe.lexists(physicalPath(p)) }
    /// `[[ -d p ]]` (đi xuyên symlink).
    public func isDirectory(_ p: String) -> Bool { FileProbe.isDirectory(physicalPath(p)) }
    /// `[[ -f p ]]` (đi xuyên symlink).
    public func isRegularFile(_ p: String) -> Bool { FileProbe.isRegularFile(physicalPath(p)) }
    /// `[[ -L p ]]`.
    public func isSymlink(_ p: String) -> Bool { FileProbe.isSymlink(physicalPath(p)) }
    /// Thư mục thật (lstat).
    public func isRealDirectory(_ p: String) -> Bool { FileProbe.isRealDirectory(physicalPath(p)) }
    /// `[[ -x p ]]` và không phải thư mục.
    public func isExecutableFile(_ p: String) -> Bool { FileProbe.isExecutableFile(physicalPath(p)) }
    /// `[[ -r p && -f p ]]`, kiểm tra bằng cách mở thật.
    public func isReadableFile(_ p: String) -> Bool { FileProbe.isReadableFile(physicalPath(p)) }
    /// `[[ -w p ]]`.
    public func isWritable(_ p: String) -> Bool { FileProbe.isWritable(physicalPath(p)) }
    /// `readlink` một cấp, chuỗi thô. Không phải symlink → nil.
    public func readlink(_ p: String) -> String? { FileProbe.readlink(physicalPath(p)) }

    // MARK: Liệt kê

    /// Mục con (đường dẫn LOGIC `dir + "/" + tên`), sắp theo byte của tên, BỎ tên bắt đầu `.`
    /// (trừ khi `includeHidden`). `suffix`: chỉ lấy tên kết thúc bằng chuỗi này (phân biệt hoa thường).
    /// Thư mục không có/không đọc được → rỗng.
    public func list(_ dir: String, _ filter: ListFilter = .any, suffix: String? = nil,
                     includeHidden: Bool = false) -> [String] {
        let phys = physicalPath(dir)
        let base = dir.hasSuffix("/") ? String(dir.dropLast()) : dir
        var out: [String] = []
        for name in FileProbe.childNames(phys) {
            if !includeHidden, name.hasPrefix(".") { continue }
            if let suffix, !name.hasSuffix(suffix) { continue }
            let child = phys + "/" + name
            let keep: Bool
            switch filter {
            case .any: keep = true
            case .realDirectories: keep = FileProbe.isRealDirectory(child)
            case .regularFiles: keep = FileProbe.isRealRegularFile(child)
            case .symlinks: keep = FileProbe.isSymlink(child)
            case .directories: keep = FileProbe.isDirectory(child)
            }
            if keep { out.append(base + "/" + name) }
        }
        return out
    }

    /// `_dir_is_empty` (tính cả file ẩn).
    public func dirIsEmpty(_ p: String) -> Bool { FileProbe.dirIsEmpty(physicalPath(p)) }

    // MARK: Dung lượng, thời gian, nội dung

    /// Dung lượng cấp phát (byte) như `du -sxk` × 1024. Không tồn tại → 0; bị hủy → 0.
    public func sizeBytes(_ p: String, isCancelled: () -> Bool = { false }) -> Int64 {
        FileProbe.allocatedSize(physicalPath(p), isCancelled: isCancelled) ?? 0
    }

    /// `days_since_modified` theo `now` của môi trường.
    public func daysSinceModified(_ p: String) -> Int { FileProbe.daysSinceModified(physicalPath(p), now: now) }
    /// `days_since_trashed` (ctime).
    public func daysSinceTrashed(_ p: String) -> Int { FileProbe.daysSinceChanged(physicalPath(p), now: now) }

    /// Nội dung UTF-8 của file thường. Không đọc được → nil.
    public func readText(_ p: String) -> String? { FileProbe.readText(physicalPath(p)) }

    /// Các dòng của file (tách theo `\n`, giữ `\r` nếu có). Khác `while read` của zsh: dòng cuối không có `\n`
    /// vẫn được đọc (sửa có chủ đích). Không đọc được → nil.
    public func readLines(_ p: String) -> [String]? {
        guard let text = readText(p) else { return nil }
        return TextLines(text).lines
    }

    // MARK: Plist

    /// `plist_get(file, keyPath)` trên đường dẫn logic. Phân biệt nil (không có) với `""` (có khóa, rỗng).
    public func plistString(_ p: String, _ keyPath: String) -> String? { Plist.get(physicalPath(p), keyPath) }
    /// Toàn bộ plist (Dictionary/Array...), nil nếu không đọc được.
    public func plistObject(_ p: String) -> Any? { Plist.load(physicalPath(p)) }

    /// `MCMMetadataIdentifier` của một container (`~/Library/Containers/<x>`): bundle id thật của container có tên tự
    /// sinh (UUID của app iOS/Catalyst). macOS hiện ghi `.com.apple.containermanagerd.metadata.plist` (có "d"), bản cũ
    /// không có "d". Đọc được cần Full Disk Access (TCC App Data): thiếu quyền thì nil, như không có metadata.
    public func containerMetadataIdentifier(_ container: String) -> String? {
        for name in [".com.apple.containermanagerd.metadata.plist", ".com.apple.containermanager.metadata.plist"] {
            if let id = plistString("\(container)/\(name)", "MCMMetadataIdentifier"), !id.isEmpty { return id }
        }
        return nil
    }

    // MARK: launchd

    /// `_launchd_program`: `Program` nếu có và không rỗng, ngược lại `ProgramArguments.0` nếu không rỗng.
    /// `BundleProgram` không được xét.
    public func launchdProgram(plist: String) -> String? {
        if let p = plistString(plist, "Program"), !p.isEmpty { return p }
        if let p = plistString(plist, "ProgramArguments.0"), !p.isEmpty { return p }
        return nil
    }

    /// `Label` của plist; thiếu/rỗng → tên file bỏ `.plist`.
    public func launchdLabel(plist: String) -> String {
        if let l = plistString(plist, "Label"), !l.isEmpty { return l }
        return Names.removingSuffix(PathResolver.tail(plist), ".plist")
    }

    /// Domain launchd theo thư mục chứa plist: `/Library/LaunchDaemons` → `system`, còn lại `gui/<uid>`.
    public func launchdDomain(forPlistIn dir: String) -> String {
        dir == "/Library/LaunchDaemons" ? "system" : "gui/\(uid)"
    }

    // MARK: Bundle

    /// `app_info_plist`: file đầu tiên tồn tại trong `Contents/Info.plist`, `Info.plist`,
    /// `WrappedBundle/Info.plist`, rồi `Wrapper/*.app/Info.plist` (tên tăng dần, lấy cái đầu).
    /// App iOS chạy trên Apple Silicon được bọc thành Wrapper/<Tên>.app/Info.plist (layout iOS, không có thư mục
    /// Contents). Đọc thiếu layout này thì bundle id không bao giờ vào chỉ mục.
    public func appInfoPlist(_ app: String) -> String? {
        for c in ["\(app)/Contents/Info.plist", "\(app)/Info.plist", "\(app)/WrappedBundle/Info.plist"]
            where isRegularFile(c) {
            return c
        }
        for inner in list("\(app)/Wrapper", .any, suffix: ".app") {
            let c = inner + "/Info.plist"
            if isRegularFile(c) { return c }
        }
        return nil
    }

    /// `bundle_id_of_app`.
    public func bundleIDOfApp(_ app: String) -> String? {
        appInfoPlist(app).flatMap { plistString($0, "CFBundleIdentifier") }
    }

    /// `app_bundle_valid`: có Info.plist (§appInfoPlist) và, nếu khai `CFBundleExecutable` không rỗng, file đó
    /// tồn tại ở `<thư mục plist>/MacOS/<exe>` hoặc `<thư mục plist>/<exe>`.
    /// Chỉ vì thư mục .app còn nằm đó KHÔNG có nghĩa ứng dụng còn được cài: trình gỡ cài đặt tồi, iCloud Drive gỡ
    /// tải, hay xóa dở dang đều để lại cái vỏ rỗng. Nếu coi cái vỏ đó là "app còn sống", toàn bộ tàn dư của nó sẽ
    /// bị xem là hợp lệ và im lặng - đúng lúc đáng lẽ phải lên tiếng nhất.
    public func appBundleValid(_ app: String) -> Bool {
        appBundleProblem(app) == nil
    }

    /// Lý do bundle không hợp lệ: `.hollowApp` (không có Info.plist) hoặc `.brokenApp(exe)`. Hợp lệ → nil.
    public func appBundleProblem(_ app: String) -> CleanReason? {
        guard let plist = appInfoPlist(app) else { return .hollowApp }
        guard let exe = plistString(plist, "CFBundleExecutable"), !exe.isEmpty else { return nil }   // không khai báo thì tha
        let d = PathResolver.parent(plist)
        if exists("\(d)/MacOS/\(exe)") || exists("\(d)/\(exe)") { return nil }
        return .brokenApp(executable: exe)
    }

    /// `_bundle_broken` (plugin): bundle khai báo file thực thi mà file đó không tồn tại → trả tên exe.
    /// Chỉ xét `Contents/`; thiếu Info.plist/khóa/rỗng → KHÔNG hỏng. Có app (League of Legends) khai
    /// `CFBundleExecutable` là đường dẫn tương đối từ `Contents/`; chỉ kết luận hỏng khi cả hai cách hiểu đều không
    /// ra file, nếu không sẽ báo nhầm cả app 37 GB. Khác `appBundleValid` - không gộp.
    public func bundleBrokenExecutable(_ bundle: String) -> String? {
        guard let exe = plistString("\(bundle)/Contents/Info.plist", "CFBundleExecutable"), !exe.isEmpty else { return nil }
        if exists("\(bundle)/Contents/MacOS/\(exe)") || exists("\(bundle)/Contents/\(exe)") { return nil }
        return exe
    }

    // MARK: Lệnh

    /// `command -v name`: tên chứa `/` → file thực thi tại đó (logic); ngược lại builtin/từ khóa zsh, hoặc file
    /// thực thi `<dir>/<name>` trong `searchPath`.
    public func commandExists(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        if name.contains("/") { return isExecutableFile(name) }
        if ScanEnvironment.zshBuiltins.contains(name) { return true }
        for dir in searchPath where isExecutableFile(dir + "/" + name) { return true }
        return false
    }

    /// Builtin + reserved word của zsh (`command -v` coi là "có"). Giữ để không báo nhầm nhiều hơn bản gốc.
    static let zshBuiltins: Set<String> = Set("""
    - : . [ alias autoload bg bindkey break builtin bye cd chdir command compadd comparguments compcall \
    compctl compdescribe compfiles compgroups compquote compset comptags comptry compvalues continue declare dirs \
    disable disown echo echotc echoti emulate enable eval exec exit export false fc fg float functions getln \
    getopts hash history integer jobs kill let limit local log logout noglob popd print printf private pushd \
    pushln pwd r read readonly rehash return sched set setopt shift source suspend test times trap true ttyctl \
    type typeset ulimit umask unalias unfunction unhash unlimit unset unsetopt vared wait whence where which \
    zcompile zformat zle zmodload zparseopts zregexparse zstyle ! [[ { } case coproc do done elif else end esac \
    fi for foreach function if nocorrect repeat select then time until while
    """.split(separator: " ").map(String.init))

    // MARK: Full Disk Access

    /// `check_fda`: có FDA ⇔ MỞ được và đọc được 1 byte của `~/Library/Application Support/com.apple.TCC/TCC.db`.
    /// `access(R_OK)` có thể nói "được" dù TCC chặn lúc `open()`. Kiểm tra cho chính tiến trình đang chạy.
    public func hasFullDiskAccess() -> Bool {
        let path = physicalPath("\(homePath)/Library/Application Support/com.apple.TCC/TCC.db")
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var b: UInt8 = 0
        return Darwin.read(fd, &b, 1) == 1
    }
}

/// Tách văn bản thành dòng, giữ nguyên trạng thái có/không `\n` cuối file (để ghi lại không mất dòng).
public struct TextLines: Equatable, Sendable {
    public var lines: [String]
    public var endsWithNewline: Bool

    public init(_ text: String) {
        var parts = text.components(separatedBy: "\n")
        endsWithNewline = text.hasSuffix("\n")
        if endsWithNewline { parts.removeLast() }
        if text.isEmpty { parts = [] }
        lines = parts
    }

    public init(lines: [String], endsWithNewline: Bool) {
        self.lines = lines
        self.endsWithNewline = endsWithNewline
    }

    public var text: String {
        lines.joined(separator: "\n") + (endsWithNewline && !lines.isEmpty ? "\n" : "")
    }
}

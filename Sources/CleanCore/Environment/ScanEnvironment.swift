import Foundation

/// Môi trường quét/gỡ, tiêm được để test chạy trên cây thư mục giả (Sendable, bất biến).
///
/// QUY ƯỚC ĐƯỜNG DẪN - đọc kỹ trước khi viết bộ quét:
/// - Mọi đường dẫn trong `Finding` (target, payload) là đường dẫn LOGIC, như trên máy thật:
///   `"\(env.homePath)/Library/Caches/com.foo"`, `"/Library/LaunchDaemons/x.plist"`. Ghép chuỗi trần như zsh:
///   không phân giải symlink, không thêm `/private`, không `/` cuối, không `~`.
/// - Chỉ khi chạm đĩa mới đổi sang đường dẫn VẬT LÝ bằng `physicalPath(_:)` (= `root` + logic). Các hàm tiện ích
///   trong `ScanEnvironment+Files.swift` nhận đường dẫn logic và tự đổi, bộ quét nên dùng chúng.
/// - Test dựng `root` = thư mục tạm và `homePath = "/Users/<tên>"` (vật lý: `root/Users/<tên>`), nhờ vậy vòng
///   `/Users/*` của chốt an toàn thấy nó và finding ID trong test giống hệt máy thật.
public struct ScanEnvironment: Sendable {
    /// Tiền tố vật lý cho mọi đường dẫn hệ thống. Máy thật: `/`.
    public var root: URL
    /// Thư mục nhà (logic) - `$HOME` chưa phân giải.
    public var homePath: String
    /// Thư mục nhà của người dùng thật (zsh `MT_USER_HOME`, khác `homePath` chỉ khi chạy root - P5).
    public var realUserHomePath: String
    /// Thùng rác của người dùng (logic), zsh `MT_TRASH`. Mặc định `realUserHomePath/.Trash`.
    public var userTrashPath: String
    public var uid: uid_t
    public var userName: String
    /// Luôn `false` ở P0; giữ cho P5 (helper root).
    public var isRoot: Bool
    /// Biến môi trường của shell đăng nhập của người dùng (không phải của app GUI). nil = không lấy được.
    public var shellEnvironment: [String: String]?
    /// Thư mục (logic) dùng để tra lệnh thay cho `$PATH` (`command -v`).
    public var searchPath: [String]
    /// Đồng hồ cho `days_since_*`, tên thư mục backup, lịch sử.
    public var now: Date
    /// Thư mục dữ liệu (vật lý): backup, ignore.txt, ScanHistory.
    public var dataDir: URL
    /// Bundle id của chính app (luôn coi là đang cài, dù app chạy từ ~/Downloads, DMG hay `.build`).
    public var ownBundleIDs: [String]
    /// Tên của chính app (khớp chính xác): thư mục `Application Support/<tên>` chứa backup không bao giờ bị báo.
    public var ownNames: [String]

    /// Bundle id mặc định của app. CleanCore không phụ thuộc PowerCore nên ghi lại ở đây.
    public static let appBundleID = "com.hasoftware.MacPowerManager"
    public static let appName = "MacPowerManager"

    public init(root: URL = URL(fileURLWithPath: "/"),
                homePath: String,
                realUserHomePath: String? = nil,
                userTrashPath: String? = nil,
                uid: uid_t = getuid(),
                userName: String = NSUserName(),
                isRoot: Bool = false,
                shellEnvironment: [String: String]? = nil,
                searchPath: [String] = [],
                now: Date = Date(),
                dataDir: URL? = nil,
                ownBundleIDs: [String]? = nil,
                ownNames: [String]? = nil) {
        self.root = root
        self.homePath = ScanEnvironment.trimTrailingSlash(homePath)
        let real = ScanEnvironment.trimTrailingSlash(realUserHomePath ?? homePath)
        self.realUserHomePath = real
        self.userTrashPath = userTrashPath ?? real + "/.Trash"
        self.uid = uid
        self.userName = userName
        self.isRoot = isRoot
        self.shellEnvironment = shellEnvironment
        self.searchPath = searchPath
        self.now = now
        let rootPath = ScanEnvironment.trimTrailingSlash(root.path)
        self.dataDir = dataDir ?? URL(fileURLWithPath: (rootPath == "/" ? "" : rootPath) + self.homePath
            + "/Library/Application Support/MacPowerManager/Cleanup")
        var ids = [ScanEnvironment.appBundleID]
        if let b = Bundle.main.bundleIdentifier, !b.lowercased().hasPrefix("com.apple."), !ids.contains(b) { ids.append(b) }
        self.ownBundleIDs = ownBundleIDs ?? ids
        // tên thư mục chứa dataDir (`.../Application Support/MacPowerManager/Cleanup` -> MacPowerManager)
        var names = [ScanEnvironment.appName]
        let parent = self.dataDir.deletingLastPathComponent().lastPathComponent
        if !parent.isEmpty, !names.contains(parent) { names.append(parent) }
        self.ownNames = ownNames ?? names
    }

    /// Môi trường thật của tiến trình hiện tại. Gọi ngoài main thread vì chạy shell đăng nhập (tối đa ~10 giây).
    public static func live(runner: CommandRunner = ProcessCommandRunner(), loadShellEnvironment: Bool = true) -> ScanEnvironment {
        var env = ScanEnvironment(homePath: FileManager.default.homeDirectoryForCurrentUser.path)
        if loadShellEnvironment {
            // Shell đăng nhập chạy với môi trường SẠCH như cửa sổ Terminal mới. Kế thừa PATH của tiến trình (chạy từ
            // Terminal/Xcode) thì `.zshrc` cộng dồn lần nữa -> PATH trùng lặp giả.
            let shellRunner: CommandRunner
            if let p = runner as? ProcessCommandRunner, p.environment == nil {
                shellRunner = ProcessCommandRunner(environment: ShellEnvironmentLoader.freshEnvironment(
                    home: env.homePath, userName: env.userName, base: ProcessInfo.processInfo.environment))
            } else {
                shellRunner = runner
            }
            env.shellEnvironment = ShellEnvironmentLoader.load(runner: shellRunner, userName: env.userName)
        }
        env.searchPath = env.defaultSearchPath(processPATH: ProcessInfo.processInfo.environment["PATH"])
        return env
    }

    // MARK: Logic ↔ vật lý

    /// `root.path` không có `/` cuối (`/` giữ nguyên).
    public var rootPath: String { ScanEnvironment.trimTrailingSlash(root.path) }
    public var isRealRoot: Bool { rootPath == "/" }
    /// `root` đã phân giải (`/var/folders/...` → `/private/var/folders/...`).
    public var resolvedRootPath: String { isRealRoot ? "/" : PathResolver.resolve(rootPath) }

    /// Đường dẫn vật lý của một đường dẫn logic tuyệt đối. Chuỗi đã mang sẵn tiền tố root được giữ nguyên
    /// (dung thứ cho đường dẫn lấy từ đĩa); đường dẫn tương đối giữ nguyên.
    public func physicalPath(_ logical: String) -> String {
        let r = rootPath
        if r == "/" || !logical.hasPrefix("/") { return logical }
        if logical == r || logical.hasPrefix(r + "/") { return logical }
        let rr = resolvedRootPath
        if logical == rr || logical.hasPrefix(rr + "/") { return logical }
        return r + logical
    }

    public func physicalURL(_ logical: String) -> URL { URL(fileURLWithPath: physicalPath(logical)) }

    /// Đường dẫn logic từ đường dẫn vật lý (bỏ tiền tố root, kể cả dạng đã phân giải). Ngoài root → giữ nguyên.
    public func logicalPath(_ physical: String) -> String {
        if isRealRoot { return physical }
        for prefix in [rootPath, resolvedRootPath] {
            if physical == prefix { return "/" }
            if physical.hasPrefix(prefix + "/") { return String(physical.dropFirst(prefix.count)) }
        }
        return physical
    }

    /// `${p:A}` trên đường dẫn logic: phân giải trong cây vật lý rồi bỏ tiền tố root đã phân giải.
    /// Mọi chốt an toàn so sánh trên kết quả của hàm này (cả hai vế).
    public func resolved(_ logical: String) -> String {
        let lex = PathResolver.lexical(logical)
        if isRealRoot { return PathResolver.resolve(lex) }
        return logicalPath(PathResolver.resolve(physicalPath(lex)))
    }

    /// `dataDir` dạng logic.
    public var dataDirPath: String { logicalPath(dataDir.path) }

    /// `p` là `dataDir`, tổ tiên của nó, hoặc nằm trong nó: backup, manifest, restore.sh, ignore.txt. Gỡ nó là mất
    /// luôn khả năng hoàn tác của mọi lần dọn trước (và của chính lần dọn đang chạy).
    public func isOwnDataPath(_ p: String) -> Bool {
        guard !p.isEmpty, p.hasPrefix("/") else { return false }
        let rp = resolved(p)
        let d = resolved(dataDirPath)
        if rp == "/" { return true }
        return rp == d || d.hasPrefix(rp + "/") || rp.hasPrefix(d + "/")
    }

    /// Thư mục nhà (vật lý).
    public var home: URL { physicalURL(homePath) }
    /// Thùng rác người dùng (vật lý).
    public var userTrash: URL { physicalURL(userTrashPath) }

    static func trimTrailingSlash(_ s: String) -> String {
        var s = s
        while s.count > 1, s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

// MARK: - PATH và môi trường shell

extension ScanEnvironment {
    /// PATH của người dùng để `scan_path` duyệt (giữ nguyên chuỗi, kể cả phần tử rỗng).
    /// Không bao giờ dùng PATH của chính tiến trình app (launchd chỉ cho `/usr/bin:/bin:/usr/sbin:/sbin`).
    /// Thiếu `shellEnvironment` → PATH dựng từ `/etc/paths` + `/etc/paths.d/*` (như `path_helper`).
    public var userPATH: String {
        if let p = shellEnvironment?["PATH"] { return p }
        return pathHelperEntries().joined(separator: ":")
    }

    /// `true` khi PATH là bản dự phòng: UI nên báo quét PATH không đầy đủ.
    public var isUsingFallbackPATH: Bool { shellEnvironment?["PATH"] == nil }

    /// Tách PATH theo `:` GIỮ phần tử rỗng (`"a::b:"` → `a`, ``, `b`, ``).
    public static func splitPATH(_ s: String) -> [String] {
        s.components(separatedBy: ":")
    }

    /// Các dòng của `/etc/paths` rồi `/etc/paths.d/*` (sắp theo tên), bỏ dòng rỗng.
    public func pathHelperEntries() -> [String] {
        var files = ["/etc/paths"]
        files += list("/etc/paths.d", .any)
        var out: [String] = []
        for f in files {
            guard let text = readText(f) else { continue }
            for line in text.components(separatedBy: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { out.append(t) }
            }
        }
        return out
    }

    /// searchPath mặc định cho máy thật = hợp (giữ thứ tự, khử trùng) của PATH shell, PATH tiến trình,
    /// `/etc/paths*` và danh sách dự phòng. PATH hẹp làm `name_alive` báo NHẦM tàn dư của công cụ CLI còn dùng.
    public func defaultSearchPath(processPATH: String?) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func add(_ p: String) {
            let p = p.hasPrefix("~/") ? homePath + String(p.dropFirst()) : p
            guard p.hasPrefix("/"), !seen.contains(p) else { return }
            seen.insert(p); out.append(p)
        }
        (shellEnvironment?["PATH"]).map { ScanEnvironment.splitPATH($0).forEach(add) }
        processPATH.map { ScanEnvironment.splitPATH($0).forEach(add) }
        pathHelperEntries().forEach(add)
        ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin", "/usr/bin", "/bin",
         "/usr/sbin", "/sbin", "~/.local/bin", "~/bin", "~/.cargo/bin", "~/go/bin", "~/.bun/bin", "~/.deno/bin"]
            .forEach(add)
        return out
    }

    /// `RC_FILES`, thứ tự cố định - dùng chung cho scan_path, scan_envvars, scan_dyld.
    public var rcFiles: [String] {
        let h = homePath
        return ["\(h)/.zshrc", "\(h)/.zprofile", "\(h)/.zshenv", "\(h)/.zlogin",
                "\(h)/.bash_profile", "\(h)/.bashrc", "\(h)/.profile",
                "/etc/zshrc", "/etc/zprofile", "/etc/zshenv", "/etc/profile", "/etc/bashrc"]
    }

    /// `_path_source_file(dir)`: file đầu tiên (thứ tự `/etc/paths`, `/etc/paths.d/*` theo tên, rồi `rcFiles`)
    /// đọc được, là file thường (đi xuyên symlink: `~/.zshrc` trỏ vào repo dotfiles vẫn đọc) và CHỨA chuỗi con
    /// `dir` ở bất cứ đâu (như `grep -qF`, kể cả dòng comment). Trả đường dẫn logic; không có → nil.
    public func pathSourceFile(for dir: String) -> String? {
        guard !dir.isEmpty else { return nil }
        let files = ["/etc/paths"] + list("/etc/paths.d", .any) + rcFiles
        for f in files where isReadableFile(f) {
            guard let data = FileManager.default.contents(atPath: physicalPath(f)) else { continue }
            if data.range(of: Data(dir.utf8)) != nil { return f }
        }
        return nil
    }
}

/// Lấy biến môi trường của shell đăng nhập + tương tác của người dùng (đa số khai PATH trong `~/.zshrc`).
public enum ShellEnvironmentLoader {
    static let marker = "__MPM_ENV__"

    /// nil khi thất bại/timeout. Không bao giờ trả môi trường của chính app.
    public static func load(runner: CommandRunner, userName: String, timeout: TimeInterval = 10) -> [String: String]? {
        var shell = "/bin/zsh"
        let r = runner.run(Tool.dscl, [".", "-read", "/Users/\(userName)", "UserShell"], timeout: 5)
        if r.succeeded, let v = r.stdout.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespacesAndNewlines),
           v.hasPrefix("/") {
            shell = v
        } else if let s = ProcessInfo.processInfo.environment["SHELL"], s.hasPrefix("/") {
            shell = s
        }
        let res = runner.run(shell, ["-i", "-l", "-c", "printf '\\n\(marker)\\n'; /usr/bin/env -0"], timeout: timeout)
        guard res.succeeded else { return nil }
        return parse(res.stdout)
    }

    /// Biến tối thiểu cho shell đăng nhập (như `login` của Terminal): giữ vài biến định danh/locale từ `base`, PATH
    /// mặc định của launchd. Mọi biến khác (PATH đã dựng, biến của Xcode/IDE) bị bỏ.
    public static func freshEnvironment(home: String, userName: String, base: [String: String]) -> [String: String] {
        var env: [String: String] = [:]
        for k in ["SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "TERM", "__CF_USER_TEXT_ENCODING", "SSH_AUTH_SOCK"] {
            if let v = base[k] { env[k] = v }
        }
        env["HOME"] = home
        env["USER"] = userName
        env["LOGNAME"] = userName
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        return env
    }

    /// Bỏ mọi thứ trước marker (banner do `.zshrc` in ra), tách theo `\0`, mỗi phần `KEY=VALUE` tại `=` đầu tiên.
    public static func parse(_ output: String) -> [String: String]? {
        guard let r = output.range(of: "\n\(marker)\n") else { return nil }
        var env: [String: String] = [:]
        for part in output[r.upperBound...].split(separator: "\0") {
            guard let eq = part.firstIndex(of: "="), eq != part.startIndex else { continue }
            env[String(part[..<eq])] = String(part[part.index(after: eq)...])
        }
        return env.isEmpty ? nil : env
    }
}

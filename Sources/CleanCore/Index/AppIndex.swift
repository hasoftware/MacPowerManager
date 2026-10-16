import Foundation

/// Chỉ mục app đã cài + thành phần hệ thống (`build_app_index` + `build_sys_index`).
/// Dựng MỘT lần mỗi lượt quét rồi chia sẻ (bất biến) cho mọi bộ quét.
public struct AppIndex: Sendable {
    /// bundle id (lowercase) → đường dẫn logic app, hoặc `"pkg:<id>"`. Gồm cả nguồn app lẫn nguồn pkgutil.
    public private(set) var bundleIDs: [String: String] = [:]
    /// Tiền tố vendor ≥ 2 thành phần của mọi bundle id đã đăng ký.
    public private(set) var prefixes: Set<String> = []
    /// Như hai trường trên nhưng KHÔNG gồm nguồn `pkgutil --pkgs` (xem `bundleIDAlive(_:includePackageReceipts:)`).
    public private(set) var appBundleIDs: Set<String> = []
    public private(set) var appPrefixes: Set<String> = []
    /// `norm_name` của tên app (≥ 3 ký tự).
    public private(set) var tokens: Set<String> = []
    /// Từ riêng (≥ 4 ký tự, không thuộc STOP_WORD) trong tên app.
    public private(set) var words: Set<String> = []
    /// Token của thành phần macOS (launchd job, /usr/libexec, CoreServices, framework, XPC...).
    public private(set) var sysTokens: Set<String> = []
    /// App hợp lệ (đường dẫn logic, có thể là symlink `.app`).
    public private(set) var validApps: [String] = []
    /// Vỏ `.app` không hợp lệ, theo thứ tự phát hiện. Vỏ rỗng vào đây để scan_brokenapps báo, đồng thời KHÔNG
    /// che giấu tàn dư của nó.
    public private(set) var deadApps: [String] = []
    /// Danh sách `pkgutil --pkgs` (giữ thứ tự) - bộ quét Receipt dùng lại, khỏi chạy lệnh lần nữa.
    public private(set) var packageReceiptIDs: [String] = []
    /// Biên nhận "chết" (không app/plugin/toolchain nào khớp, không còn file nào của gói). KHÔNG được đăng ký vào
    /// `bundleIDs`/`prefixes`: nếu không, chính biên nhận mồ côi lại làm dữ liệu của app đã gỡ trông như còn sống.
    public private(set) var staleReceiptIDs: Set<String> = []
    /// App Group (lowercase) khai trong entitlement của app đang cài (`UBF8T346G9.office`, `group.com.foo`).
    public private(set) var appGroups: Set<String> = []
    /// Team ID (HOA) của app đang cài (từ chữ ký).
    public private(set) var teamIDs: Set<String> = []
    /// Tên của chính app này (`norm`), so khớp CHÍNH XÁC: thư mục dữ liệu/backup của app không bao giờ bị báo.
    public private(set) var ownNames: Set<String> = []

    /// Môi trường dùng cho `command -v` (searchPath).
    public let env: ScanEnvironment

    public init(env: ScanEnvironment) {
        self.env = env
    }

    // MARK: Đăng ký

    /// `_reg_bundle`: ghi bid (lowercase) và mọi tiền tố có ≥ 2 thành phần. Nhờ vậy container/cache mang id anh
    /// em (com.surfshark.vpn) vẫn được coi là còn sống. Tiền tố 1 thành phần (com, org...) bị loại vì nó khớp mọi thứ.
    public mutating func registerBundle(_ bid: String, path: String, fromPackageReceipt: Bool = false) {
        let b = bid.lowercased()
        guard !b.isEmpty else { return }
        bundleIDs[b] = path
        if !fromPackageReceipt { appBundleIDs.insert(b) }
        var t = b
        while let dot = t.lastIndex(of: ".") {
            t = String(t[..<dot])
            guard t.contains(".") else { break }
            prefixes.insert(t)
            if !fromPackageReceipt { appPrefixes.insert(t) }
        }
    }

    /// Team ID + App Group từ chữ ký của một app hợp lệ.
    public mutating func registerSigning(_ info: SigningInfo) {
        if let t = info.teamID, !t.isEmpty { teamIDs.insert(t.uppercased()) }
        for g in info.appGroups where !g.isEmpty { appGroups.insert(g.lowercased()) }
    }

    /// Tên của chính app (khớp chính xác theo `norm`, không vào `tokens` để khỏi làm "power"/"manager" sống theo).
    public mutating func registerOwnName(_ name: String) {
        let n = Names.norm(name)
        if !n.isEmpty { ownNames.insert(n) }
    }

    /// Thêm tiền tố vendor trực tiếp (TOOLCHAIN_PREFIX).
    public mutating func registerPrefix(_ prefix: String) {
        prefixes.insert(prefix)
        appPrefixes.insert(prefix)
    }

    /// `_reg_token`: tên app → token (≥ 3) + từ riêng. "Client Riot.app" -> riot: thư mục "Riot Client" hay
    /// "riot-client-ux" vẫn nhận ra là của phần mềm đang cài.
    public mutating func registerToken(_ name: String) {
        let t = Names.norm(name)
        if t.count >= 3 { tokens.insert(t) }
        for w in Names.significantWords(name) { words.insert(w) }
    }

    /// `_reg_sys`. Rất nhiều thư mục trong ~/Library/Application Support và ~/Library/Caches là do các tiến trình
    /// hệ thống đẻ ra chứ không phải app nào cả - không có chỉ mục này thì chúng bị báo nhầm hàng loạt.
    public mutating func registerSystem(_ name: String) {
        let t = Names.norm(name)
        if t.count >= 3 { sysTokens.insert(t) }
    }

    /// Xóa tập từ (chỉ dùng cho test "Từ chung không được coi là bằng chứng").
    public mutating func resetWords() { words = [] }

    // MARK: Tra cứu

    /// `bid_alive`. `includePackageReceipts = false`: bỏ qua bid/tiền tố đến từ `pkgutil --pkgs` - dùng cho bộ
    /// quét Receipt, vì chỉ mục gốc đăng ký mọi id biên nhận nên biên nhận dạng bundle id luôn "còn sống" (rủi ro R2).
    public func bundleIDAlive(_ bid: String, includePackageReceipts: Bool = true) -> Bool {
        let b = bid.lowercased()
        guard !b.isEmpty else { return false }
        // Apple: không bao giờ đụng
        if b.hasPrefix("com.apple.") || b.hasPrefix("apple.") || b.hasPrefix("group.com.apple.") { return true }
        let isBundle: (String) -> Bool = includePackageReceipts ? { bundleIDs[$0] != nil } : { appBundleIDs.contains($0) }
        let isPrefix: (String) -> Bool = includePackageReceipts ? { prefixes.contains($0) } : { appPrefixes.contains($0) }
        if isBundle(b) { return true }
        // Là helper/thành phần con của một app đang cài? com.foo.bar.helper -> com.foo.bar
        var t = b
        while let dot = t.lastIndex(of: ".") {
            t = String(t[..<dot])
            guard t.contains(".") else { break }
            if isBundle(t) || isPrefix(t) { return true }
        }
        if isPrefix(b) { return true }
        // vd: com.foo.Slack
        let last = Names.norm(Names.lastComponent(b))
        if last.count >= 4, tokens.contains(last) { return true }
        return false
    }

    /// `name_alive`.
    public func nameAlive(_ name: String) -> Bool {
        let n = Names.norm(name)
        // tên quá ngắn -> không đủ tin cậy, coi như còn sống
        if n.count < 3 { return true }
        if sysTokens.contains(n) || tokens.contains(n) { return true }
        // 'GoogleChrome' chứa 'chrome', hoặc app 'Docker' nằm trong 'DockerDesktop'
        for t in tokens where t.count >= 4 {
            if n.contains(t) || t.contains(n) { return true }
        }
        for w in Names.significantWords(name) where words.contains(w) { return true }
        // Còn binary cùng tên trong PATH -> phần mềm CLI vẫn còn
        if env.commandExists(name.lowercased()) { return true }
        return false
    }

    /// `command -v` theo `env.searchPath`.
    public func commandExists(_ name: String) -> Bool { env.commandExists(name) }
}

// MARK: - Dựng chỉ mục

extension AppIndex {
    /// Thư mục tìm app theo thứ tự (`build_app_index`).
    public static func appSearchDirs(homePath: String) -> [String] {
        ["/Applications", "\(homePath)/Applications", "/System/Applications", "/Applications/Utilities",
         "/System/Applications/Utilities", "/Applications/Setapp", "/Users/Shared",
         "/Library/Application Support/JetBrains/Toolbox/apps", "/opt/homebrew/Caskroom", "/usr/local/Caskroom"]
    }

    /// Dựng chỉ mục đầy đủ. Ném `CancellationError` khi bị hủy.
    /// `signing`: đọc Team ID/App Group của app hợp lệ (không phải Apple) để nhận ra Group Container của chúng.
    public static func build(env: ScanEnvironment, runner: CommandRunner,
                             signing: SigningInfoReader = SecuritySigningInfoReader(),
                             isCancelled: () -> Bool = { false }) throws -> AppIndex {
        var idx = AppIndex(env: env)
        func check() throws { if isCancelled() { throw CancellationError() } }

        // 1-3. App bundle
        var seenApps = Set<String>()
        for dir in appSearchDirs(homePath: env.homePath) where env.isDirectory(dir) {
            try check()
            for app in findApps(in: dir, env: env) where !seenApps.contains(app) {
                seenApps.insert(app)
                if env.appBundleValid(app) {
                    idx.validApps.append(app)
                    let bid = env.bundleIDOfApp(app)
                    if let bid { idx.registerBundle(bid, path: app) }
                    // App Group/Team ID: Group Container dạng `UBF8T346G9.Office` không mang bundle id nào
                    if !(bid?.lowercased().hasPrefix("com.apple.") ?? false),
                       let info = signing.signingInfo(atPath: env.physicalPath(app)) {
                        idx.registerSigning(info)
                    }
                    // tên BÊN NGOÀI, kể cả với app Wrapper
                    idx.registerToken(Names.removingSuffix(PathResolver.tail(app), ".app"))
                } else {
                    idx.deadApps.append(app)
                }
            }
        }

        // Chính app này: chạy từ ~/Downloads, DMG, bản build `swift run`... vẫn không bao giờ tự báo mình là rác.
        for bid in env.ownBundleIDs { idx.registerBundle(bid, path: "self:\(bid)") }
        for n in env.ownNames { idx.registerOwnName(n) }

        // 5. Homebrew Cellar
        for cellar in ["/opt/homebrew/Cellar", "/usr/local/Cellar"] {
            for f in env.list(cellar, .directories) { idx.registerToken(PathResolver.tail(f)) }
        }

        // 6. PreferencePanes, Internet Plug-Ins
        for dir in ["/Library/PreferencePanes", "\(env.homePath)/Library/PreferencePanes",
                    "/Library/Internet Plug-Ins", "\(env.homePath)/Library/Internet Plug-Ins"] {
            try check()
            for ext in env.list(dir, .any) {
                if let bid = env.plistString("\(ext)/Contents/Info.plist", "CFBundleIdentifier"), !bid.isEmpty {
                    idx.registerBundle(bid, path: ext)
                }
                idx.registerToken(Names.removingLastExtension(PathResolver.tail(ext)))
            }
        }

        // 7. TOOLCHAIN_PREFIX
        for (prefix, cmd) in Names.toolchainPrefixes where env.commandExists(cmd) {
            idx.registerPrefix(prefix)
        }

        // 8.
        try idx.buildSystemIndex(runner: runner, isCancelled: isCancelled)

        // 4. Nhiều phần mềm không có .app nhưng vẫn "đang cài". Làm SAU CÙNG: phân loại biên nhận cần chỉ mục đã đủ.
        // Chỉ biên nhận còn sống mới được đăng ký làm bằng chứng (MacTrash đăng ký tất cả -> mọi tàn dư cùng vendor
        // của gói đã gỡ đều im lặng, đúng lúc bộ quét Receipt báo chính gói đó là mồ côi).
        try check()
        let pkgs = runner.run(Tool.pkgutil, ["--pkgs"])
        if pkgs.succeeded {
            for line in pkgs.lines where !line.isEmpty {
                try check()
                idx.packageReceiptIDs.append(line)
                if try idx.receiptIsStale(line, runner: runner, isCancelled: isCancelled) {
                    idx.staleReceiptIDs.insert(line)
                    continue
                }
                idx.registerBundle(line, path: "pkg:\(line)", fromPackageReceipt: true)
            }
        }
        return idx
    }

    /// Biên nhận mồ côi: không phải Apple, không khớp app/plugin/toolchain/hệ thống nào (bỏ nguồn pkgutil), và
    /// không còn file nào trong 40 dòng đầu của `pkgutil --files`.
    func receiptIsStale(_ pkg: String, runner: CommandRunner, isCancelled: () -> Bool) throws -> Bool {
        if pkg.lowercased().hasPrefix("com.apple.") { return false }
        // mtime dùng cho id dạng tên là của /var/db/receipts (chung cho mọi gói, như bản gốc)
        guard orphanCheck(name: pkg, path: "/var/db/receipts", includePackageReceipts: false).isOrphan else {
            return false
        }
        return try !AppIndex.packageHasFiles(pkg, env: env, runner: runner, isCancelled: isCancelled)
    }

    /// Số dòng đầu của `pkgutil --files` được xét (`head -40`).
    static let receiptFileProbeLimit = 40

    /// `pkgutil --pkg-info` cho `location`/`volume`, rồi 40 dòng đầu của `pkgutil --files` (dừng lệnh sau 40 dòng
    /// như `| head -40`, gói texlive có >150k file): còn một đường dẫn tồn tại là gói còn file. Không xem được
    /// (thiếu quyền, ổ chưa mount) cũng tính là còn. Lệnh lỗi → output rỗng → coi như không còn file.
    /// Parity: danh sách gồm cả thư mục (`Applications`, `usr/local`) vốn luôn tồn tại, nên đa số gói "còn file".
    static func packageHasFiles(_ pkg: String, env: ScanEnvironment, runner: CommandRunner,
                                isCancelled: () -> Bool) throws -> Bool {
        var loc = "", vol = "/"
        let info = runner.run(Tool.pkgutil, ["--pkg-info", pkg])
        if info.succeeded {
            for line in info.lines {
                if line.hasPrefix("location:") {
                    loc = dropOneLeadingSpace(String(line.dropFirst("location:".count)))
                } else if line.hasPrefix("volume:") {
                    vol = dropOneLeadingSpace(String(line.dropFirst("volume:".count)))
                }
            }
        }
        let files = runner.runHead(Tool.pkgutil, ["--files", pkg], maxLines: receiptFileProbeLimit)
        guard files.succeeded else { return false }
        let volPrefix = vol.hasSuffix("/") ? String(vol.dropLast()) : vol
        for f in files.lines.prefix(receiptFileProbeLimit) where !f.isEmpty {
            if isCancelled() { throw CancellationError() }
            // "${vol%/}/${loc:+$loc/}$f" - có thể ra `//`, vô hại với kiểm tra tồn tại
            let full = volPrefix + "/" + (loc.isEmpty ? "" : loc + "/") + f
            if env.existence(full) != .missing { return true }
        }
        return false
    }

    /// `${x## }`: bỏ MỘT dấu cách đầu nếu có.
    private static func dropOneLeadingSpace(_ s: String) -> String {
        s.hasPrefix(" ") ? String(s.dropFirst()) : s
    }

    /// Tương đương `find <dir> -maxdepth 4 -name '*.app' -prune`: mọi mục (kể cả SYMLINK) tên kết thúc `.app` ở
    /// độ sâu 1…4, không đi vào trong `.app`, không theo symlink khi duyệt; giữ mục nếu `-d` (đi xuyên symlink).
    /// KHÔNG lọc -type d: nhiều game/launcher đặt trong /Applications một symlink trỏ tới bundle thật ở
    /// /Users/Shared. Lọc -type d là mất hẳn app đó khỏi chỉ mục -> mọi dữ liệu của nó bị báo nhầm là mồ côi.
    /// Symlink gãy bị loại hẳn. `find` không bỏ file ẩn nên ở đây cũng không bỏ.
    static func findApps(in dir: String, env: ScanEnvironment) -> [String] {
        var out: [String] = []
        func walk(_ d: String, depth: Int) {
            for child in env.list(d, .any, includeHidden: true) {
                if PathResolver.tail(child).hasSuffix(".app") {
                    if env.isDirectory(child) { out.append(child) }
                } else if depth < 4, env.isRealDirectory(child) {
                    walk(child, depth: depth + 1)
                }
            }
        }
        walk(dir, depth: 1)
        return out
    }

    /// `build_sys_index`. Glob zsh không khớp file ẩn nên mọi nguồn ở đây bỏ dotfile.
    mutating func buildSystemIndex(runner: CommandRunner, isCancelled: () -> Bool) throws {
        func check() throws { if isCancelled() { throw CancellationError() } }
        // 1. launchd plist của hệ thống: com.apple.stickersd -> stickersd (và cả tên đầy đủ)
        for dir in ["/System/Library/LaunchAgents", "/System/Library/LaunchDaemons"] {
            for f in env.list(dir, .any, suffix: ".plist") {
                let n = Names.removingSuffix(PathResolver.tail(f), ".plist")
                registerSystem(Names.lastComponent(n))
                registerSystem(n)
            }
        }
        // 2. launchctl list (`read -r _ _ lbl`). Parity: dòng tiêu đề `PID Status Label` cũng bị đọc -> token
        //    "label" vào sysTokens. Vô hại (chỉ làm thư mục tên "Label" không bao giờ bị báo), giữ như bản gốc.
        try check()
        let lc = runner.run(Tool.launchctl, ["list"])
        if lc.succeeded {
            for line in lc.lines {
                let parts = line.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
                guard parts.count == 3 else { continue }
                let lbl = parts[2].trimmingCharacters(in: .whitespaces)
                guard !lbl.isEmpty else { continue }
                registerSystem(Names.lastComponent(lbl))
                registerSystem(lbl)
            }
        }
        // 3. /usr/libexec/* và /usr/libexec/*/*
        try check()
        for e in env.list("/usr/libexec", .any) {
            registerSystem(PathResolver.tail(e))
            if env.isDirectory(e) {
                for e2 in env.list(e, .any) { registerSystem(PathResolver.tail(e2)) }
            }
        }
        // 4. CoreServices
        for e in env.list("/System/Library/CoreServices", .any) {
            registerSystem(Names.removingSuffix(PathResolver.tail(e), ".app"))
        }
        // 5-6. Framework, Support, XPCServices
        try check()
        for dir in ["/System/Library/PrivateFrameworks", "/System/Library/Frameworks"] {
            for fw in env.list(dir, .any, suffix: ".framework") {
                registerSystem(Names.removingSuffix(PathResolver.tail(fw), ".framework"))
            }
        }
        for fw in env.list("/System/Library/PrivateFrameworks", .directories) {
            if isCancelled() { throw CancellationError() }
            for s in env.list("\(fw)/Support", .regularFiles) {
                registerSystem(Names.removingSuffix(PathResolver.tail(s), ".xpc"))
            }
            for x in env.list("\(fw)/XPCServices", .any) {
                registerSystem(Names.removingSuffix(PathResolver.tail(x), ".xpc"))
            }
        }
    }
}

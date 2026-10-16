import Foundation

/// App bị loại khỏi danh sách gỡ, kèm lý do (cho log/preview).
public struct ExcludedApp: Sendable, Hashable {
    public var app: InstalledApp
    public var reason: AppExclusion

    public init(app: InstalledApp, reason: AppExclusion) {
        self.app = app
        self.reason = reason
    }
}

/// Danh mục app gỡ được (`flow_apps`: APP_LIST bỏ `/System`). Chỉ đọc; dựng khi người dùng mở trang, ngoài main
/// thread. Dung lượng app KHÔNG tính ở đây (đắt): gọi `size(of:)` riêng, lười, hủy được.
public struct AppCatalog: Sendable {
    /// Kết quả một lần liệt kê.
    public struct Listing: Sendable {
        /// App gỡ được, sắp theo tên.
        public var apps: [InstalledApp]
        /// Mọi app hợp lệ khác tìm thấy (`/System/Applications`, Setapp, `/Users/Shared`, Caskroom...) - chỉ để nhận
        /// ra thư mục DÙNG CHUNG với app đang gỡ, không bao giờ được đưa ra gỡ.
        public var references: [InstalledApp]
        /// App thấy được nhưng không cho gỡ (hệ thống, chính app này, nằm trong bundle khác, trong Thùng rác).
        public var excluded: [ExcludedApp]

        public init(apps: [InstalledApp], references: [InstalledApp] = [], excluded: [ExcludedApp] = []) {
            self.apps = apps
            self.references = references
            self.excluded = excluded
        }

        /// Tất cả app đang cài (gỡ được + tham chiếu + bị loại), khử trùng theo bundle thật.
        public var allInstalled: [InstalledApp] {
            var seen = Set<String>()
            var out: [InstalledApp] = []
            for a in apps + references + excluded.map(\.app) where !seen.contains(a.bundlePath) {
                seen.insert(a.bundlePath)
                out.append(a)
            }
            return out
        }

        /// Tra app gỡ được theo đường dẫn (logic, của danh sách hoặc bundle thật), tên file (có/không `.app`,
        /// không phân biệt hoa thường) hoặc bundle id.
        public func find(_ query: String) -> [InstalledApp] {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { return [] }
            if q.hasPrefix("/") {
                let p = PathResolver.lexical(q)
                return apps.filter { $0.path == p || $0.bundlePath == p }
            }
            let name = Names.removingSuffix(q, ".app").lowercased()
            let byName = apps.filter { $0.name.lowercased() == name }
            if !byName.isEmpty { return byName }
            return apps.filter { $0.bundleID?.lowercased() == q.lowercased() }
        }

        /// App bị loại khớp `query` (để preview nói rõ vì sao không gỡ được).
        public func findExcluded(_ query: String) -> [ExcludedApp] {
            let q = query.trimmingCharacters(in: .whitespaces)
            let name = Names.removingSuffix(q, ".app").lowercased()
            return excluded.filter {
                $0.app.path == q || $0.app.bundlePath == q || $0.app.name.lowercased() == name
                    || $0.app.bundleID?.lowercased() == q.lowercased()
            }
        }
    }

    public let env: ScanEnvironment
    public let signing: SigningInfoReader
    public let usage: AppUsageReader
    public let processes: RunningProcessLister

    public init(env: ScanEnvironment, signing: SigningInfoReader = SecuritySigningInfoReader(),
                usage: AppUsageReader = SpotlightUsageReader(), processes: RunningProcessLister = ProcessTableLister()) {
        self.env = env
        self.signing = signing
        self.usage = usage
        self.processes = processes
    }

    /// Thư mục đưa app ra gỡ: chính nó và MỘT cấp thư mục con (`/Applications/Utilities`, `Setapp`,
    /// `Adobe Photoshop 2024/`, `Python 3.13/`, `~/Applications/Chrome Apps.localized/`).
    public static func offeredDirs(homePath: String) -> [String] {
        ["/Applications", "\(homePath)/Applications"]
    }

    // MARK: Liệt kê

    /// Liệt kê app. Ném `CancellationError` khi bị hủy. Đọc Info.plist, chữ ký (Team ID/App Group, vài ms mỗi app)
    /// và ngày dùng gần nhất; KHÔNG tính dung lượng.
    public func load(isCancelled: () -> Bool = { false }) throws -> Listing {
        func check() throws { if isCancelled() { throw CancellationError() } }
        var apps: [InstalledApp] = []
        var excluded: [ExcludedApp] = []
        var seenBundles = Set<String>()
        for dir in AppCatalog.offeredDirs(homePath: env.homePath) {
            for path in candidates(in: dir) {
                try check()
                guard env.appBundleValid(path) else { continue }   // vỏ rỗng: việc của bộ quét P0
                let app = describe(path)
                if let why = exclusion(of: app) {
                    excluded.append(ExcludedApp(app: app, reason: why))
                    continue
                }
                guard !seenBundles.contains(app.bundlePath) else { continue }
                seenBundles.insert(app.bundlePath)
                apps.append(app)
            }
        }
        apps.sort { a, b in
            let c = a.name.localizedStandardCompare(b.name)
            return c == .orderedSame ? a.path < b.path : c == .orderedAscending
        }

        // App khác (APP_LIST đầy đủ của MacTrash, gồm /System): chỉ để phát hiện thư mục dùng chung.
        var references: [InstalledApp] = []
        let excludedBundles = Set(excluded.map(\.app.bundlePath))
        for dir in AppIndex.appSearchDirs(homePath: env.homePath) where env.isDirectory(dir) {
            try check()
            for path in AppIndex.findApps(in: dir, env: env) {
                try check()
                let bundle = env.isSymlink(path) ? env.resolved(path) : path
                guard !seenBundles.contains(bundle), !excludedBundles.contains(bundle),
                      env.appBundleValid(path) else { continue }
                seenBundles.insert(bundle)
                // App của Apple trong /System: không đọc chữ ký (App Group group.com.apple.* không bao giờ được gom
                // cho app bên thứ ba), không đọc ngày dùng.
                references.append(describe(path, readSigning: !bundle.hasPrefix("/System/"), readUsage: false))
            }
        }
        return Listing(apps: apps, references: references, excluded: excluded)
    }

    /// `.app` ở cấp 1 và cấp 2 của `dir`: không đi vào trong `.app`, không theo symlink THƯ MỤC khi duyệt, nhưng
    /// nhận symlink `.app` (game đặt symlink trong /Applications trỏ tới /Users/Shared). Bỏ tên ẩn.
    func candidates(in dir: String) -> [String] {
        var out: [String] = []
        for child in env.list(dir, .any) {
            if PathResolver.tail(child).hasSuffix(".app") {
                if env.isDirectory(child) { out.append(child) }
            } else if env.isRealDirectory(child) {
                for inner in env.list(child, .any) where PathResolver.tail(inner).hasSuffix(".app") && env.isDirectory(inner) {
                    out.append(inner)
                }
            }
        }
        return out
    }

    /// Dựng `InstalledApp` cho một bundle (đường dẫn logic). Không kiểm tra hợp lệ.
    public func describe(_ path: String, readSigning: Bool = true, readUsage: Bool = true) -> InstalledApp {
        let bundle = env.isSymlink(path) ? env.resolved(path) : path
        let name = Names.removingSuffix(PathResolver.tail(path), ".app")
        let plist = env.appInfoPlist(bundle)
        let info = plist.flatMap { env.plistObject($0) as? [String: Any] } ?? [:]
        func str(_ k: String) -> String? {
            guard let s = info[k] as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return s
        }
        var names: [String] = []
        var seenNorms: Set<String> = [Names.norm(name)]
        for k in ["CFBundleDisplayName", "CFBundleName"] {
            guard let n = str(k) else { continue }
            let nn = Names.norm(n)
            if nn.isEmpty || seenNorms.contains(nn) { continue }
            seenNorms.insert(nn)
            names.append(n)
        }
        let helpers = (info["SMPrivilegedExecutables"] as? [String: Any]).map { $0.keys.sorted() } ?? []
        let sig = readSigning ? signing.signingInfo(atPath: env.physicalPath(bundle)) : nil
        return InstalledApp(path: path, bundlePath: bundle, name: name, bundleNames: names,
                            bundleID: str("CFBundleIdentifier"),
                            version: str("CFBundleShortVersionString") ?? str("CFBundleVersion"),
                            teamID: sig?.teamID, appGroups: sig?.appGroups ?? [], privilegedHelpers: helpers,
                            lastUsed: readUsage ? usage.lastUsedDate(atPath: env.physicalPath(bundle)) : nil)
    }

    /// Vì sao app không được gỡ qua đây; nil = gỡ được.
    public func exclusion(of app: InstalledApp) -> AppExclusion? {
        let real = env.resolved(app.path)
        if real == "/System" || real.hasPrefix("/System/") || app.bundlePath.hasPrefix("/System/") { return .system }
        if let bid = app.bundleID?.lowercased(), env.ownBundleIDs.contains(where: { $0.lowercased() == bid }) {
            return .ownApp
        }
        if env.isTrashPath(real) || real.contains("/.Trash/") || real.contains("/.Trashes/") { return .inTrash }
        // thành phần cha nào là bundle -> app con của bundle khác
        let comps = real.split(separator: "/").dropLast()
        let bundleExts = [".app", ".appex", ".framework", ".bundle", ".xpc", ".plugin"]
        if comps.contains(where: { c in bundleExts.contains { c.hasSuffix($0) } }) { return .nestedInBundle }
        return nil
    }

    // MARK: Dung lượng, tiến trình

    /// Dung lượng cấp phát của bundle thật (như `du -sxk`). nil khi bị hủy giữa chừng. Gọi ngoài main thread,
    /// lười (chỉ cho dòng đang hiển thị / app được chọn).
    public func size(of app: InstalledApp, isCancelled: () -> Bool = { false }) -> Int64? {
        let s = env.sizeBytes(app.bundlePath, isCancelled: isCancelled)
        return isCancelled() ? nil : s
    }

    /// Tiến trình đang chạy từ BÊN TRONG bundle (app chính, helper, login item). Đọc bảng tiến trình mới mỗi lần.
    public func runningProcesses(of app: InstalledApp) -> [RunningProcess] {
        AppCatalog.runningProcesses(of: app, in: processes.runningProcesses(), env: env)
    }

    /// Như trên với bảng tiến trình có sẵn (một lần đọc cho nhiều app).
    public static func runningProcesses(of app: InstalledApp, in table: [RunningProcess],
                                        env: ScanEnvironment) -> [RunningProcess] {
        // proc_pidpath trả đường dẫn VẬT LÝ đã phân giải
        var prefixes = Set<String>()
        for p in [app.bundlePath, app.path] {
            prefixes.insert(env.physicalPath(p) + "/")
            prefixes.insert(PathResolver.resolve(env.physicalPath(p)) + "/")
        }
        return table.filter { proc in prefixes.contains { proc.executablePath.hasPrefix($0) } }
    }
}

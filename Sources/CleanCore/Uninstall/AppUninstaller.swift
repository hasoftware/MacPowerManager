import Foundation

/// Gỡ sạch theo ứng dụng (`flow_apps` + `collect_app_files` của MacTrash). Ngược chiều với các bộ quét: người dùng
/// CHỈ ĐÍCH DANH app, nên được khớp thẳng theo bundle id và đúng tên (không dùng heuristic mồ côi). Chỉ đọc: chỉ
/// sinh `Finding`, không mục nào được chọn sẵn; gỡ đi qua `Remover` (vào Thùng rác, có sao lưu, khôi phục được).
///
/// Khớp tên = tên CHUẨN HÓA BẰNG NHAU (`norm`), không bao giờ chứa nhau: gỡ "Notion" không đụng "Notion Calendar",
/// gỡ "Code" không đụng "Visual Studio Code" (và ngược lại). Ngoại lệ là bậc khớp gần đúng (`isLowConfidence`: tên
/// bắt đầu bằng tên app, tên ghép từ bundle id, thư mục hãng): luôn kèm cảnh báo, không nằm trong "Chọn tất cả".
public struct AppUninstaller: Sendable {
    public let env: ScanEnvironment
    public let runner: CommandRunner
    public let signing: SigningInfoReader

    public init(env: ScanEnvironment, runner: CommandRunner, signing: SigningInfoReader = SecuritySigningInfoReader()) {
        self.env = env
        self.runner = runner
        self.signing = signing
    }

    /// Các thư mục gốc, đúng thứ tự `collect_app_files`.
    public static func roots(homePath h: String) -> [String] {
        ["\(h)/Library/Application Support", "\(h)/Library/Caches",
         "\(h)/Library/Preferences", "\(h)/Library/Preferences/ByHost",
         "\(h)/Library/Containers", "\(h)/Library/Group Containers",
         "\(h)/Library/Saved Application State", "\(h)/Library/HTTPStorages",
         "\(h)/Library/WebKit", "\(h)/Library/Logs",
         "\(h)/Library/Cookies", "\(h)/Library/Application Scripts",
         "\(h)/Library/LaunchAgents",
         "/Library/Application Support", "/Library/Caches",
         "/Library/Preferences", "/Library/Logs",
         "/Library/LaunchAgents", "/Library/LaunchDaemons",
         "/Library/PrivilegedHelperTools"]
    }

    /// Cache bộ cập nhật electron-builder (`<tên app>-updater`): chỉ luật `updaterCache` xét ở đây.
    static func updaterCacheRoot(homePath h: String) -> String { "\(h)/Library/Application Support/Caches" }

    /// bundle id của Xcode (lowercase): có thêm dữ liệu trong `~/Library/Developer/Xcode`.
    static let xcodeBundleID = "com.apple.dt.xcode"

    /// Dữ liệu của Xcode ngoài các gốc: dựng lại được (DerivedData, DeviceSupport) hoặc chỉ báo (Archives).
    static func xcodeDataDirs(homePath h: String) -> [(path: String, kind: AppFileMatch)] {
        let x = "\(h)/Library/Developer/Xcode"
        return [("\(x)/DerivedData", .developerData),
                ("\(x)/iOS DeviceSupport", .developerData), ("\(x)/macOS DeviceSupport", .developerData),
                ("\(x)/watchOS DeviceSupport", .developerData), ("\(x)/tvOS DeviceSupport", .developerData),
                ("\(x)/visionOS DeviceSupport", .developerData),
                ("\(x)/Archives", .developerArchives)]
    }

    /// Đuôi bỏ lần lượt (mỗi đuôi một lần, đúng thứ tự zsh).
    static let strippedSuffixes = [".plist", ".savedState", ".binarycookies", ".json"]

    // MARK: Gom

    /// Gom app + mọi file liên quan của `apps` (đã chọn trong `listing.apps`). Thứ tự: theo app, trong mỗi app là
    /// bundle → file theo thứ tự thư mục gốc → biên nhận gói. Một đường dẫn chỉ xuất hiện một lần (app đầu tiên).
    /// `listing` dùng để phát hiện thư mục dùng chung với app KHÁC (không nằm trong `apps`) - phía gọi nên liệt kê lại
    /// ngay trước khi gom (app mới cài sau lần liệt kê trước cũng phải được tính).
    /// Ném `CancellationError` khi bị hủy.
    public func collect(_ apps: [InstalledApp], listing: AppCatalog.Listing, computeSizes: Bool = true,
                        isCancelled: () -> Bool = { false }) throws -> [Finding] {
        func check() throws { if isCancelled() { throw CancellationError() } }
        // Phòng thủ: app hệ thống / chính app này / app lồng trong bundle / trong Thùng rác không bao giờ được gom,
        // kể cả khi phía gọi truyền nhầm.
        let guardCatalog = AppCatalog(env: env, signing: NoSigningInfoReader(), usage: NoUsageReader(),
                                      processes: NoRunningProcesses())
        let apps = apps.filter { guardCatalog.exclusion(of: $0) == nil }
        let selected = Set(apps.map(\.bundlePath))
        let profiles = apps.map { profile($0, deep: true, strict: true) }
        // App khác cùng hãng (tiền tố bundle id) hoặc cùng Team ID được đọc SÂU như app đang gỡ: appex/login item/XPC
        // hay App Group chỉ khai trong phần mở rộng của app kia cũng phải được thấy, nếu không thư mục chung bị coi
        // là của riêng app đang gỡ. App lồng trong bundle đang gỡ không phải app "khác".
        let vendors = Set(apps.compactMap { $0.bundleID.map { AppUninstaller.vendorPrefix($0.lowercased()) } })
        let teams = Set(apps.compactMap(\.teamID))
        let others = listing.allInstalled.filter { o in
            !selected.contains(o.bundlePath) && !selected.contains { o.bundlePath.hasPrefix($0 + "/") }
        }.map { o -> Profile in
            let related = o.bundleID.map { vendors.contains(AppUninstaller.vendorPrefix($0.lowercased())) } == true
                || o.teamID.map(teams.contains) == true
            return profile(o, deep: related, strict: false)
        }
        try check()
        let includeXcode = profiles.contains { $0.bundleID == AppUninstaller.xcodeBundleID }
        let topEntries = try collectEntries(includeXcode: includeXcode, isCancelled: isCancelled)
        let entries = topEntries + vendorEntries(topEntries, vendors: Set(profiles.compactMap(\.vendor)))
        // chương trình của mọi job launchd: thư mục gần đúng chứa chương trình của một job (GoogleUpdater trong
        // Application Support/Google) không được đưa ra, kẻo job còn nạp trỏ vào chỗ trống
        let launchdPrograms = entries.compactMap { e in e.program.flatMap { $0.hasPrefix("/") ? PathResolver.lexical($0) : nil } }
        var receipts: [String]?
        var seen = Set<String>()
        var out: [Finding] = []

        func size(_ p: String) -> Int64 {
            computeSizes ? env.sizeBytes(p, isCancelled: isCancelled) : 0
        }
        func add(_ f: Finding) {
            guard !seen.contains(f.target) else { return }
            seen.insert(f.target)
            var f = f
            f.needsAdmin = Remover.needsAdmin(f, env: env)
            out.append(f)
        }

        for (index, (app, me)) in zip(apps, profiles).enumerated() {
            try check()
            let ref = app.ref
            let coApps = profiles.enumerated().filter { $0.offset != index }.map(\.element)
            // tên của MỌI app khác (luật tiền tố tên chỉ dùng khi không app nào khác có tên là tiền tố của mục)
            let otherNames = (others + coApps).flatMap(\.allNames)
            // 1. Chính bundle (bundle thật khi app là symlink; symlink gom riêng). Đã bị kéo vào Thùng rác bằng
            //    Finder thì không còn gì để gỡ: chỉ gom phần còn sót.
            if env.lexists(app.bundlePath), env.deletionRefusal(for: app.bundlePath) == nil {
                add(Finding(category: .app, severity: .high, name: app.name, target: app.bundlePath,
                            reason: .appBundle(ref), sizeBytes: size(app.bundlePath),
                            action: .trashPath(path: app.bundlePath)))
            }
            if app.path != app.bundlePath, env.isSymlink(app.path), env.deletionRefusal(for: app.path) == nil {
                add(Finding(category: .appFiles, severity: .high, name: PathResolver.tail(app.path), target: app.path,
                            reason: .appRelated(ref, match: .appSymlink), sizeBytes: 0,
                            action: .trashPath(path: app.path)))
            }
            // 2. File liên quan
            for e in entries {
                try check()
                guard let m = AppUninstaller.match(e, me) else { continue }
                if m.kind == .namePrefix, otherNames.contains(where: { e.normBase.hasPrefix($0) }) { continue }
                if m.kind.isLowConfidence, launchdPrograms.contains(where: { $0.hasPrefix(e.path + "/") }) { continue }
                guard !seen.contains(e.path), env.deletionRefusal(for: e.path) == nil, !env.isPreciousPath(e.path) else {
                    continue
                }
                func alsoMatches(_ o: Profile) -> Bool {
                    guard let om = AppUninstaller.match(e, o, broad: true) else { return false }
                    // Cùng khớp theo bundle id: app có bundle id DÀI hơn là chủ cụ thể hơn (com.foo.app.pro thuộc
                    // app com.foo.App.Pro, không thuộc com.foo.App). Chỉ tha khi app đang gỡ cụ thể hơn hẳn.
                    if m.specificity > 0, om.specificity > 0, m.specificity > om.specificity { return false }
                    return true
                }
                let sharers = others.filter(alsoMatches)
                let coOwners = coApps.filter(alsoMatches)
                let action: CleanAction
                if m.kind == .developerArchives {
                    action = .reportOnly
                } else if e.isLaunchdPlist {
                    action = .launchdJob(plist: e.path, label: e.label ?? Names.removingSuffix(e.tail, ".plist"),
                                         domain: env.launchdDomain(forPlistIn: e.root))
                } else {
                    action = .trashPath(path: e.path)
                }
                let severity: Severity = m.kind.isLowConfidence ? .medium : .high
                if !sharers.isEmpty {
                    // Dùng chung với app khác còn cài: CHỈ BÁO (không chọn được). An toàn hơn cảnh báo-mà-vẫn-cho-chọn:
                    // gỡ nhầm là mất dữ liệu của app còn dùng, còn bỏ sót chỉ tốn chỗ.
                    let names = Array(Set((sharers + coOwners).map(\.app.name)))
                        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                    add(Finding(category: .appFiles, severity: .info, name: e.tail, target: e.path,
                                reason: .appRelatedShared(ref, match: m.kind, sharedWith: names),
                                sizeBytes: size(e.path), action: .reportOnly))
                } else if !coOwners.isEmpty {
                    // Chung giữa các app CÙNG đang xem lại: gỡ được chỉ khi gói của mọi app chủ cùng được gỡ (bên gọi
                    // kiểm tra bằng `preflight`).
                    add(Finding(category: .appFiles, severity: severity, name: e.tail, target: e.path,
                                reason: .appRelatedJoint(ref, match: m.kind, coOwners: coOwners.map(\.app.ref)),
                                sizeBytes: size(e.path), action: action))
                } else {
                    add(Finding(category: .appFiles, severity: severity, name: e.tail, target: e.path,
                                reason: .appRelated(ref, match: m.kind), sizeBytes: size(e.path), action: action))
                }
            }
            // 3. Biên nhận gói mang đúng bundle id (`pkgutil --pkgs` một lần)
            if let bid = me.bundleID {
                if receipts == nil {
                    let r = runner.run(Tool.pkgutil, ["--pkgs"])
                    receipts = r.succeeded ? r.lines.filter { !$0.isEmpty } : []
                }
                for pkg in receipts ?? [] {
                    let lp = pkg.lowercased()
                    guard lp == bid || lp.hasPrefix(bid + ".") else { continue }
                    // biên nhận khớp app khác cụ thể hơn (bundle id dài hơn) → của app đó
                    if (others + coApps).contains(where: { o in
                        o.bundleIDs.contains { $0.count > bid.count && (lp == $0 || lp.hasPrefix($0 + ".")) }
                    }) { continue }
                    add(Finding(category: .receipt, severity: .medium, name: pkg, target: "/var/db/receipts/\(pkg)",
                                reason: .appRelated(ref, match: .packageReceipt), sizeBytes: 0,
                                action: .pkgReceipt(id: pkg)))
                }
            }
        }
        return out
    }

    // MARK: Thứ tự gỡ

    /// Thứ tự chạy khi gỡ: theo app (thứ tự xuất hiện), trong mỗi app là gói → job launchd (dừng dịch vụ đang chạy
    /// từ gói, trước khi xóa dữ liệu nó còn ghi) → phần còn lại. Mục chung nhiều app để cuối cùng, sau khi gói của
    /// mọi app chủ đã được xử lý. `Remover` bỏ qua mục còn lại của app có gói không gỡ được (`SkipReason.appKept`).
    public static func removalOrder(_ findings: [Finding]) -> [Finding] {
        func rank(_ f: Finding) -> Int {
            if case .appRelatedJoint = f.reason { return 3 }
            if case .appBundle = f.reason { return 0 }
            if case .launchdJob = f.action { return 1 }
            return 2
        }
        var ownerOrder: [String: Int] = [:]
        for f in findings {
            if let o = f.uninstallOwner?.path, ownerOrder[o] == nil { ownerOrder[o] = ownerOrder.count }
        }
        return findings.enumerated().sorted { a, b in
            let ra = rank(a.element), rb = rank(b.element)
            if (ra == 3) != (rb == 3) { return rb == 3 }
            let oa = a.element.uninstallOwner.flatMap { ownerOrder[$0.path] } ?? Int.max
            let ob = b.element.uninstallOwner.flatMap { ownerOrder[$0.path] } ?? Int.max
            if oa != ob { return oa < ob }
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    // MARK: Xcode đang chọn

    /// App chứa thư mục developer đang chọn (`xcode-select -p` = đích của `/var/db/xcode_select_link`; không có link
    /// thì xcode-select dùng `/Applications/Xcode.app` nếu có). Gỡ app đó làm git/clang/swift lỗi "invalid active
    /// developer path" tới khi chạy `sudo xcode-select --reset`. Trả `path` của các app như vậy.
    public static func activeDeveloperApps(_ apps: [InstalledApp], env: ScanEnvironment) -> Set<String> {
        let dir: String
        if let link = env.readlink("/var/db/xcode_select_link"), link.hasPrefix("/") {
            dir = PathResolver.lexical(link)
        } else if env.isDirectory("/Applications/Xcode.app/Contents/Developer") {
            dir = "/Applications/Xcode.app/Contents/Developer"
        } else {
            return []
        }
        let real = env.resolved(dir)
        return Set(apps.filter { a in
            [a.path, a.bundlePath].contains { dir.hasPrefix($0 + "/") || real.hasPrefix($0 + "/") }
        }.map(\.path))
    }
}

// MARK: - App đang chạy

/// Một job launchd đã gom cho app đang chạy chương trình nằm trong bundle.
public struct RunningService: Sendable, Hashable {
    public var label: String
    /// `system` (LaunchDaemon, root) hoặc `gui/<uid>`.
    public var domain: String
    /// `Finding.id` của mục plist job.
    public var findingID: String
    /// Mục job chọn được (không cần quản trị, không dùng chung): chọn nó thì lúc gỡ job được dừng (bootout) trước.
    public var isSelectable: Bool

    public init(label: String, domain: String, findingID: String, isSelectable: Bool) {
        self.label = label
        self.domain = domain
        self.findingID = findingID
        self.isSelectable = isSelectable
    }

    public var isSystem: Bool { domain == "system" }
}

/// Các tiến trình chạy từ trong bundle của một app, đã phân loại.
public struct AppRunState: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// App có giao diện/agent dạng `.app` (`*.app/Contents/MacOS/*`): thoát được như Cmd-Q.
        case app
        /// Tiến trình khác chạy từ trong bundle (toolchain, XPC, CLI) - thường do app/công cụ khác chạy.
        case helper
        /// Do một job launchd đã gom cho app chạy: dừng bằng bootout, không phải Thoát.
        case service(RunningService)
    }

    public struct Process: Sendable, Hashable {
        public var process: RunningProcess
        public var kind: Kind
        /// Tên tiến trình cha ("launchd", "claude"...), nil khi không rõ.
        public var parentName: String?

        public init(process: RunningProcess, kind: Kind, parentName: String? = nil) {
            self.process = process
            self.kind = kind
            self.parentName = parentName
        }
    }

    public var processes: [Process]

    public init(processes: [Process]) { self.processes = processes }

    public var isEmpty: Bool { processes.isEmpty }

    /// Tiến trình dạng app (nút Thoát).
    public var appProcesses: [RunningProcess] {
        processes.filter { $0.kind == .app }.map(\.process)
    }

    public var helpers: [Process] { processes.filter { $0.kind == .helper } }

    /// Dịch vụ đang chạy (mỗi job một lần).
    public var services: [RunningService] {
        var seen = Set<String>()
        return processes.compactMap { p in
            guard case .service(let s) = p.kind, seen.insert(s.findingID).inserted else { return nil }
            return s
        }
    }

    /// Có app hoặc helper chạy: mọi mục của app bị khóa (xóa dữ liệu của app đang mở dễ làm hỏng dữ liệu).
    public var blocksEverything: Bool {
        processes.contains { if case .service = $0.kind { false } else { true } }
    }
}

/// Vì sao một mục chưa gỡ được lúc này.
public enum UninstallBlock: Sendable, Hashable {
    /// App (hoặc helper chạy từ trong app) đang chạy.
    case running
    /// Dịch vụ launchd chạy từ trong gói mà người dùng không dừng được ở đây (LaunchDaemon root, agent cần quản trị
    /// hay dùng chung): gói bị khóa tới khi dịch vụ được dừng bằng lệnh quản trị.
    case serviceNeedsAdmin(label: String, domain: String)
    /// Agent của người dùng đang chạy từ gói nhưng mục job của nó không được chọn: không dừng được → giữ lại.
    case serviceNotSelected(label: String)
    /// Mục chung nhiều app mà gói của app `app` không được gỡ cùng.
    case sharedWithKeptApp(app: String)
}

/// Kết quả kiểm tra trước khi gỡ.
public struct UninstallPreflight: Sendable {
    public struct Blocked: Sendable, Hashable {
        public var finding: Finding
        public var reason: UninstallBlock
    }

    /// Gỡ được ngay.
    public var allowed: [Finding]
    /// Giữ lại, kèm lý do.
    public var blocked: [Blocked]
}

extension AppUninstaller {
    /// Phân loại tiến trình đang chạy từ trong bundle của từng app (khóa = `app.path`, app không chạy thì không có
    /// khóa). `findings`: kết quả gom, để nhận ra tiến trình do job launchd của chính app chạy.
    public static func runStates(apps: [InstalledApp], findings: [Finding], table: [RunningProcess],
                                 env: ScanEnvironment) -> [String: AppRunState] {
        let byPID = Dictionary(table.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let launchdDirs: Set<String> = ["\(env.homePath)/Library/LaunchAgents", "/Library/LaunchAgents",
                                        "/Library/LaunchDaemons"]
        var out: [String: AppRunState] = [:]
        for app in apps {
            let procs = AppCatalog.runningProcesses(of: app, in: table, env: env)
            guard !procs.isEmpty else { continue }
            // chương trình (vật lý, đã phân giải) của job launchd gom cho app → dịch vụ
            var programs: [String: RunningService] = [:]
            for f in findings where f.uninstallOwners.contains(app.ref) {
                let dir = PathResolver.parent(f.target)
                guard launchdDirs.contains(dir), f.target.hasSuffix(".plist"),
                      let prog = env.launchdProgram(plist: f.target), prog.hasPrefix("/") else { continue }
                let isJob: Bool = if case .launchdJob = f.action { true } else { false }
                let svc = RunningService(label: env.launchdLabel(plist: f.target), domain: env.launchdDomain(forPlistIn: dir),
                                         findingID: f.id, isSelectable: isJob && !f.needsAdmin)
                let phys = env.physicalPath(PathResolver.lexical(prog))
                programs[phys] = svc
                programs[PathResolver.resolve(phys)] = svc
            }
            var servicePIDs: [Int32: RunningService] = [:]
            for p in procs { if let s = programs[p.executablePath] { servicePIDs[p.pid] = s } }
            let entries = procs.map { p -> AppRunState.Process in
                let kind: AppRunState.Kind
                // con của tiến trình dịch vụ cũng thuộc dịch vụ đó
                if let s = servicePIDs[p.pid] ?? servicePIDs[p.ppid] {
                    kind = .service(s)
                } else if PathResolver.parent(p.executablePath).hasSuffix(".app/Contents/MacOS") {
                    kind = .app
                } else {
                    kind = .helper
                }
                let parent = p.ppid == 1 ? "launchd" : byPID[p.ppid]?.name
                return AppRunState.Process(process: p, kind: kind, parentName: parent)
            }
            out[app.path] = AppRunState(processes: entries)
        }
        return out
    }

    /// Vì sao `f` chưa gỡ được với các app đang chạy `states`; nil = được. `selected`: id các mục sẽ gỡ cùng lượt;
    /// nil = đang chọn (job launchd người dùng còn chọn thêm được nên chưa khóa).
    public static func block(_ f: Finding, states: [String: AppRunState], selected: Set<String>?) -> UninstallBlock? {
        for owner in f.uninstallOwners {
            guard let st = states[owner.path], !st.isEmpty else { continue }
            if st.blocksEverything { return .running }
            for s in st.services where s.findingID != f.id {
                if !s.isSelectable {
                    // dịch vụ không dừng được ở đây: chỉ gói bị khóa (dữ liệu người dùng thì không phải của nó)
                    if case .appBundle = f.reason { return .serviceNeedsAdmin(label: s.label, domain: s.domain) }
                } else if let selected, !selected.contains(s.findingID) {
                    return .serviceNotSelected(label: s.label)
                }
            }
        }
        return nil
    }

    /// Kiểm tra NGAY TRƯỚC khi gỡ (bảng tiến trình đọc mới): mục của app đang chạy, mục mà dịch vụ chạy từ gói chưa
    /// dừng được, và mục chung nhiều app mà gói của một app chủ không được gỡ cùng bị giữ lại. `missingApps`: đường
    /// dẫn app có gói đã không còn (coi như đã gỡ).
    public static func preflight(_ selected: [Finding], states: [String: AppRunState],
                                 missingApps: Set<String> = []) -> UninstallPreflight {
        let ids = Set(selected.map(\.id))
        let bundles = Set(selected.compactMap { f -> String? in
            if case .appBundle(let r) = f.reason { return r.path }
            return nil
        })
        var allowed: [Finding] = []
        var blocked: [UninstallPreflight.Blocked] = []
        for f in selected {
            if let why = block(f, states: states, selected: ids) {
                blocked.append(.init(finding: f, reason: why))
            } else if f.isJointAppFile,
                      let kept = f.uninstallOwners.first(where: { !bundles.contains($0.path) && !missingApps.contains($0.path) }) {
                blocked.append(.init(finding: f, reason: .sharedWithKeptApp(app: kept.name)))
            } else {
                allowed.append(f)
            }
        }
        return UninstallPreflight(allowed: allowed, blocked: blocked)
    }
}

extension Finding {
    /// App sở hữu mục này trong luồng gỡ ứng dụng (nil với finding của bộ quét).
    public var uninstallOwner: AppRef? {
        switch reason {
        case .appBundle(let a), .appRelated(let a, _), .appRelatedShared(let a, _, _), .appRelatedJoint(let a, _, _):
            return a
        default: return nil
        }
    }

    /// Chủ + các app cùng đang gỡ dùng chung mục (mục chung nhiều app).
    public var uninstallOwners: [AppRef] {
        if case .appRelatedJoint(let a, _, let co) = reason { return [a] + co }
        return uninstallOwner.map { [$0] } ?? []
    }

    /// Mục gom theo app nhưng dùng chung với app khác còn cài (chỉ báo, không chọn được).
    public var isSharedAppFile: Bool {
        if case .appRelatedShared = reason { return true }
        return false
    }

    /// Mục chung giữa các app cùng đang xem lại.
    public var isJointAppFile: Bool {
        if case .appRelatedJoint = reason { return true }
        return false
    }

    /// Vì sao mục được gom cho app (nil với bundle và finding của bộ quét).
    public var appFileMatch: AppFileMatch? {
        switch reason {
        case .appRelated(_, let m), .appRelatedShared(_, let m, _), .appRelatedJoint(_, let m, _): return m
        default: return nil
        }
    }
}

// MARK: - Khớp

extension AppUninstaller {
    /// Mục đặc biệt ngoài luật chung.
    enum Special {
        /// `~/Library/Application Support/Caches/<x>-updater`.
        case updaterCache
        /// Thư mục dữ liệu của Xcode.
        case xcode(AppFileMatch)
    }

    /// Một mục con của một thư mục gốc, đã tính sẵn các khóa so khớp (đọc plist launchd/metadata một lần).
    struct Entry {
        let path: String
        let root: String
        let tail: String
        /// Sau `strip_team_prefix` + bỏ đuôi (+ hậu tố hex của ByHost), lowercase.
        let lowerBase: String
        let normBase: String
        var teamPrefixed = false
        var isLaunchdPlist = false
        var label: String? = nil
        var associated: [String] = []
        var program: String? = nil
        /// `MCMMetadataIdentifier` (lowercase) của container có tên không giống bundle id.
        var containerID: String? = nil
        /// Group Containers hoặc Application Scripts: tên có thể là một App Group.
        var mayBeAppGroup = false
        var isHelperTool = false
        /// Gốc dữ liệu (Application Support, Caches, Logs): luật gần đúng chỉ xét ở đây.
        var isDataRoot = false
        /// Mục con của thư mục vendor (`norm` tên thư mục vendor); nil với mục ở cấp gốc.
        var vendor: String? = nil
        var special: Special? = nil
    }

    /// Hồ sơ so khớp của một app.
    struct Profile {
        let app: InstalledApp
        /// bundle id chính (lowercase).
        let bundleID: String?
        /// id chính + id thành phần nhúng (lowercase).
        var bundleIDs: [String] { (bundleID.map { [$0] } ?? []) + embeddedIDs }
        let embeddedIDs: [String]
        let groups: Set<String>
        /// (tên chuẩn hóa, kiểu khớp) - chỉ tên chuẩn hóa không mất chữ.
        let names: [(String, AppFileMatch)]
        /// Mọi tên chuẩn hóa (≥ 2 ký tự, kể cả tên bị loại khỏi `names`): chặn luật tiền tố tên của app KHÁC.
        let allNames: [String]
        /// Tên đủ dài cho luật tiền tố tên (gần đúng).
        let prefixNames: [String]
        /// Thành phần bundle id sau TLD ghép lại (`com.ledger.live` → `ledgerlive`), gần đúng.
        let idWords: String?
        let helpers: Set<String>
        /// Tiền tố đường dẫn bundle (logic, có `/` cuối), cả dạng đã phân giải.
        let bundlePrefixes: [String]
        /// Vendor (`google`) và tên con chấp nhận (`chrome`) cho luật thư mục vendor.
        let vendor: String?
        let vendorChildNames: Set<String>
        /// Mọi tên hãng có thể của app (thành phần thứ hai của bundle id, từ đầu của tên): phía "app khác" của luật
        /// thư mục hãng xét rộng để không bỏ sót app cùng hãng.
        let vendorKeys: Set<String>
    }

    struct Match {
        let kind: AppFileMatch
        /// Độ dài bundle id đã khớp (0 = không khớp theo bundle id).
        let specificity: Int
    }

    func collectEntries(includeXcode: Bool = false, isCancelled: () -> Bool) throws -> [Entry] {
        var out: [Entry] = []
        let h = env.homePath
        let launchdDirs: Set<String> = ["\(h)/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons"]
        let dataRoots = Set(AppUninstaller.vendorRoots(homePath: h))
        for root in AppUninstaller.roots(homePath: h) where env.isDirectory(root) {
            if isCancelled() { throw CancellationError() }
            let isByHost = PathResolver.tail(root) == "ByHost"
            let isContainers = root == "\(h)/Library/Containers"
            let groupRoots: Set<String> = ["\(h)/Library/Group Containers", "\(h)/Library/Application Scripts"]
            for e in env.list(root, .any) {
                let tail = PathResolver.tail(e)
                var base = Names.stripTeamPrefix(tail)
                for s in AppUninstaller.strippedSuffixes { base = Names.removingSuffix(base, s) }
                if isByHost { base = AppUninstaller.strippingByHostSuffix(base) }
                var entry = Entry(path: e, root: root, tail: tail, lowerBase: base.lowercased(), normBase: Names.norm(base))
                // chỉ khi thực sự cắt Team ID (`group.` thôi thì vẫn là bundle id thường)
                entry.teamPrefixed = Names.teamIdentifier(tail) != nil
                entry.isLaunchdPlist = launchdDirs.contains(root) && tail.hasSuffix(".plist")
                if entry.isLaunchdPlist, let dict = env.plistObject(e) as? [String: Any] {
                    if let l = dict["Label"] as? String, !l.isEmpty { entry.label = l }
                    if let a = dict["AssociatedBundleIdentifiers"] as? [String] {
                        entry.associated = a.map { $0.lowercased() }
                    } else if let a = dict["AssociatedBundleIdentifiers"] as? String {
                        entry.associated = [a.lowercased()]
                    }
                    entry.program = env.launchdProgram(plist: e)
                }
                if isContainers, !Names.looksLikeBundleID(tail), let id = env.containerMetadataIdentifier(e) {
                    entry.containerID = id.lowercased()
                }
                entry.mayBeAppGroup = groupRoots.contains(root)
                entry.isHelperTool = root == "/Library/PrivilegedHelperTools"
                entry.isDataRoot = dataRoots.contains(root)
                out.append(entry)
            }
        }
        // electron-builder: `<tên app>-updater` (cache bản cập nhật tải về)
        let updater = AppUninstaller.updaterCacheRoot(homePath: h)
        for e in env.list(updater, .any) {
            let tail = PathResolver.tail(e)
            guard tail.lowercased().hasSuffix("-updater") else { continue }
            let base = String(tail.dropLast("-updater".count))
            out.append(Entry(path: e, root: updater, tail: tail, lowerBase: base.lowercased(), normBase: Names.norm(base),
                             special: .updaterCache))
        }
        if includeXcode {
            for (p, kind) in AppUninstaller.xcodeDataDirs(homePath: h) where env.isRealDirectory(p) {
                let tail = PathResolver.tail(p)
                out.append(Entry(path: p, root: PathResolver.parent(p), tail: tail, lowerBase: tail.lowercased(),
                                 normBase: Names.norm(tail), special: .xcode(kind)))
            }
        }
        return out
    }

    /// `${base%.[0-9A-Fa-f-]##}`: bỏ hậu tố ngắn nhất dạng `.` + ≥1 ký tự hex/`-` (UUID máy của ByHost).
    static func strippingByHostSuffix(_ s: String) -> String {
        guard let dot = s.lastIndex(of: ".") else { return s }
        let rest = s[s.index(after: dot)...]
        guard !rest.isEmpty, rest.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return s }
        return String(s[..<dot])
    }

    /// Chuẩn hóa làm mất chữ (`QQ音乐` → `qq`, `Ảnh` → `nh`): phần còn lại không còn là tên app, không dùng để khớp.
    static func normalizationDropsLetters(_ s: String) -> Bool {
        let letters = CharacterSet.letters
        let all = s.precomposedStringWithCanonicalMapping.unicodeScalars.filter { letters.contains($0) }.count
        let kept = Names.norm(s).unicodeScalars.filter { letters.contains($0) }.count
        return kept < all
    }

    /// id thành phần nhúng KHÁC hãng nhưng thường dùng chung giữa nhiều app (Sparkle, bộ cập nhật của Google/
    /// Microsoft, Electron): không phải bằng chứng thuộc về app.
    static func isSharedComponentID(_ id: String, appIsApple: Bool) -> Bool {
        if id.hasPrefix("com.apple.") { return !appIsApple }
        let shared = ["org.sparkle-project.", "com.google.keystone", "com.google.googleupdater", "com.microsoft.autoupdate",
                      "com.github.electron", "com.electron.", "com.squirrel."]
        return shared.contains { id.hasPrefix($0) }
    }

    /// `deep`: đọc thêm thành phần nhúng (appex, login item, XPC, app con, helper). `strict` (app đang gỡ): chỉ nhận
    /// thành phần cùng hãng (appex, login item) hoặc không phải thành phần dùng chung (XPC, app con); app khác
    /// (`strict == false`) nhận mọi thành phần - thấy thừa ở phía "app khác" chỉ làm mục bị coi là dùng chung.
    func profile(_ app: InstalledApp, deep: Bool, strict: Bool) -> Profile {
        let bid = app.bundleID?.lowercased()
        var embedded: [String] = []
        var groups = Set(app.appGroups.map { $0.lowercased() })
        var helpers = Set(app.privilegedHelpers)
        if deep {
            let vendor = bid.map(AppUninstaller.vendorPrefix)
            let b = app.bundlePath
            // (đường dẫn thành phần, bắt buộc cùng hãng)
            var parts: [(String, Bool)] = []
            parts += env.list("\(b)/Contents/PlugIns", .any, suffix: ".appex").map { ($0, true) }
            parts += env.list("\(b)/Contents/Library/LoginItems", .any, suffix: ".app").map { ($0, true) }
            // app iOS bọc trong Wrapper/: phần mở rộng nằm ở <Wrapper>/<App>.app/PlugIns
            for w in env.list("\(b)/Wrapper", .any, suffix: ".app") {
                parts += env.list("\(w)/PlugIns", .any, suffix: ".appex").map { ($0, true) }
            }
            // XPC service, app con đầy đủ (Instruments, Simulator trong Xcode): nằm hẳn trong gói, id khác hãng vẫn
            // là của app (LINE: `LINE.MediaService`)
            parts += env.list("\(b)/Contents/XPCServices", .any, suffix: ".xpc").map { ($0, false) }
            parts += env.list("\(b)/Contents/Applications", .any, suffix: ".app").map { ($0, false) }
            parts += env.list("\(b)/Contents/Developer/Applications", .any, suffix: ".app").map { ($0, false) }
            for (p, sameVendorOnly) in parts {
                guard let id = env.appInfoPlist(p).flatMap({ env.plistString($0, "CFBundleIdentifier") })?.lowercased(),
                      !id.isEmpty, id != bid else { continue }
                if strict {
                    if sameVendorOnly {
                        guard let vendor, AppUninstaller.vendorPrefix(id) == vendor else { continue }
                    } else if AppUninstaller.isSharedComponentID(id, appIsApple: app.isApple) {
                        continue
                    }
                }
                // Thành phần con `bid.*` đã được luật bundle id bắt.
                if !(bid.map { id.hasPrefix($0 + ".") } ?? false), !embedded.contains(id) { embedded.append(id) }
                if let info = signing.signingInfo(atPath: env.physicalPath(p)) {
                    for g in info.appGroups { groups.insert(g.lowercased()) }
                }
            }
            // helper root mang sẵn trong gói (SMJobBless): tên file = label cài vào /Library/PrivilegedHelperTools
            for h in env.list("\(b)/Contents/Library/LaunchServices", .any) {
                let n = PathResolver.tail(h)
                guard Names.looksLikeBundleID(n) else { continue }
                if strict { guard let vendor, AppUninstaller.vendorPrefix(n.lowercased()) == vendor else { continue } }
                helpers.insert(n)
            }
        }
        var names: [(String, AppFileMatch)] = []
        var allNames: [String] = []
        let minLen = 2
        let fileNorm = Names.norm(app.name)
        for (raw, kind) in [(app.name, AppFileMatch.name)] + app.bundleNames.map({ ($0, AppFileMatch.bundleName) }) {
            let nn = Names.norm(raw)
            if nn.count >= minLen, !allNames.contains(nn) { allNames.append(nn) }
            guard nn.count >= minLen, !Names.systemKeep.contains(nn), !AppUninstaller.normalizationDropsLetters(raw),
                  !names.contains(where: { $0.0 == nn }) else { continue }
            names.append((nn, kind))
        }
        var idWords: String?
        if let bid {
            let comps = bid.split(separator: ".").map(String.init)
            let w = Names.norm(comps.dropFirst().joined())
            if comps.count >= 3, w.count >= 6, !Names.systemKeep.contains(w), !names.contains(where: { $0.0 == w }) {
                idWords = w
            }
        }
        var prefixes: [String] = []
        for p in [app.bundlePath, app.path, env.resolved(app.bundlePath)] where !prefixes.contains(p + "/") {
            prefixes.append(p + "/")
        }
        // Vendor: từ đầu của tên file app, đồng thời là thành phần thứ hai của bundle id (com.google.Chrome).
        var vendor: String?
        var children = Set<String>()
        let words = Names.words(app.name)
        if words.count >= 2, words[0].count >= 3, let bid,
           bid.split(separator: ".").dropFirst().first.map({ Names.norm(String($0)) }) == words[0] {
            vendor = words[0]
            let rest = words.dropFirst().joined()
            if rest.count >= minLen { children.insert(rest) }
            for (n, _) in names where n != fileNorm { children.insert(n) }
            children.subtract(Names.systemKeep)
            if children.isEmpty || Names.systemKeep.contains(words[0]) { vendor = nil }
        }
        var keys = Set<String>()
        if let second = bid?.split(separator: ".").dropFirst().first {
            let k = Names.norm(String(second))
            if k.count >= 3 { keys.insert(k) }
        }
        if words.count >= 2, words[0].count >= 3 { keys.insert(words[0]) }
        keys.subtract(Names.systemKeep)
        return Profile(app: app, bundleID: bid, embeddedIDs: embedded, groups: groups, names: names, allNames: allNames,
                       prefixNames: names.map(\.0).filter { $0.count >= 4 }, idWords: idWords, helpers: helpers,
                       bundlePrefixes: prefixes, vendor: vendor, vendorChildNames: children, vendorKeys: keys)
    }

    /// Thư mục gốc có luật thư mục vendor (dữ liệu, cache, log).
    static func vendorRoots(homePath h: String) -> [String] {
        ["\(h)/Library/Application Support", "\(h)/Library/Caches", "\(h)/Library/Logs",
         "/Library/Application Support", "/Library/Caches", "/Library/Logs"]
    }

    /// Mục con của các thư mục vendor (`<gốc>/<Vendor>/*`, chỉ thư mục thật) cho các vendor cần xét.
    func vendorEntries(_ entries: [Entry], vendors: Set<String>) -> [Entry] {
        guard !vendors.isEmpty else { return [] }
        let roots = Set(AppUninstaller.vendorRoots(homePath: env.homePath))
        var out: [Entry] = []
        for e in entries where roots.contains(e.root) && vendors.contains(e.normBase) && env.isRealDirectory(e.path) {
            for c in env.list(e.path, .realDirectories) {
                let tail = PathResolver.tail(c)
                out.append(Entry(path: c, root: e.path, tail: tail, lowerBase: tail.lowercased(), normBase: Names.norm(tail),
                                 vendor: e.normBase))
            }
        }
        return out
    }

    /// Hai thành phần đầu của bundle id (`com.foo.bar` → `com.foo`). Apple: ba thành phần (`com.apple.dt`), vì mọi
    /// app của Apple chung `com.apple`.
    static func vendorPrefix(_ bid: String) -> String {
        let parts = bid.split(separator: ".", omittingEmptySubsequences: false)
        let n = parts.count > 2 && parts[0] == "com" && parts[1] == "apple" ? 3 : 2
        return parts.prefix(n).joined(separator: ".")
    }

    /// `x == bid || x.hasPrefix(bid + ".")`. bundle id không có dấu chấm chỉ khớp chính xác.
    static func idMatches(_ x: String, _ bid: String) -> Bool {
        guard !bid.isEmpty else { return false }
        return x == bid || (bid.contains(".") && x.hasPrefix(bid + "."))
    }

    /// Khớp mạnh nhất của `e` với app `p`; nil = không liên quan. `broad`: phía "app khác" của kiểm tra dùng chung -
    /// luật thư mục hãng xét mọi tên hãng có thể của app.
    static func match(_ e: Entry, _ p: Profile, broad: Bool = false) -> Match? {
        // Tên trùng thành phần của macOS (Logs/Sync, Caches/PassKit...) không bao giờ khớp theo tên.
        let nameAllowed = !Names.systemKeep.contains(e.normBase)
        switch e.special {
        case .xcode(let kind)?:
            return p.bundleID == xcodeBundleID ? Match(kind: kind, specificity: 0) : nil
        case .updaterCache?:
            guard nameAllowed, p.names.contains(where: { $0.0 == e.normBase }) else { return nil }
            return Match(kind: .updaterCache, specificity: 0)
        case nil:
            break
        }
        // Mục con của thư mục vendor: chỉ luật vendor (tên con BẰNG phần còn lại của tên app).
        if let v = e.vendor {
            guard v == p.vendor, p.vendorChildNames.contains(e.normBase) else { return nil }
            return Match(kind: .vendorSubfolder, specificity: 0)
        }
        // 1. bundle id (parity: `$lb == $bid || $lb == $bid.*`)
        if let bid = p.bundleID, idMatches(e.lowerBase, bid) {
            return Match(kind: e.teamPrefixed ? .teamPrefixedBundleID : .bundleID, specificity: bid.count)
        }
        for id in p.embeddedIDs where idMatches(e.lowerBase, id) {
            return Match(kind: .embeddedBundleID, specificity: id.count)
        }
        // 2. container có tên tự sinh: id thật trong metadata
        if let cid = e.containerID {
            for id in p.bundleIDs where idMatches(cid, id) { return Match(kind: .containerMetadata, specificity: id.count) }
        }
        // 3. App Group khai trong chữ ký (Group Containers và Application Scripts cùng mang tên group)
        if e.mayBeAppGroup, p.groups.contains(e.tail.lowercased()) { return Match(kind: .appGroup, specificity: 0) }
        // 4. launchd
        if e.isLaunchdPlist {
            if let l = e.label?.lowercased() {
                for id in p.bundleIDs where idMatches(l, id) { return Match(kind: .launchdLabel, specificity: id.count) }
            }
            for id in p.bundleIDs where e.associated.contains(id) {
                return Match(kind: .launchdAssociatedBundle, specificity: id.count)
            }
            if let prog = e.program, prog.hasPrefix("/") {
                let lex = PathResolver.lexical(prog)
                if p.bundlePrefixes.contains(where: { lex.hasPrefix($0) }) {
                    return Match(kind: .launchdProgramInBundle, specificity: 0)
                }
            }
        }
        // 5. helper root khai trong SMPrivilegedExecutables (+ plist LaunchDaemon cùng tên)
        if !p.helpers.isEmpty {
            if e.isHelperTool, p.helpers.contains(e.tail) { return Match(kind: .privilegedHelper, specificity: 0) }
            if e.isLaunchdPlist, e.root == "/Library/LaunchDaemons",
               p.helpers.contains(Names.removingSuffix(e.tail, ".plist")) || e.label.map(p.helpers.contains) == true {
                return Match(kind: .privilegedHelper, specificity: 0)
            }
        }
        guard nameAllowed else { return nil }
        // 6. tên chuẩn hóa BẰNG NHAU (parity: `norm_name base == norm_name app`)
        for (n, kind) in p.names where e.normBase == n { return Match(kind: kind, specificity: 0) }
        // 7. Gần đúng, chỉ ở gốc dữ liệu (Application Support, Caches, Logs)
        guard e.isDataRoot else { return nil }
        if broad ? p.vendorKeys.contains(e.normBase) : (p.vendor == e.normBase) {
            return Match(kind: .vendorFolder, specificity: 0)
        }
        if let w = p.idWords, e.normBase == w { return Match(kind: .bundleIDWords, specificity: 0) }
        for n in p.prefixNames where e.normBase.count > n.count && e.normBase.hasPrefix(n)
            && continuesWithoutSeparator(e.tail, afterNormalized: n.count) {
            return Match(kind: .namePrefix, specificity: 0)
        }
        return nil
    }

    /// Sau `count` ký tự `[a-z0-9]` đầu của `s`, ký tự kế tiếp vẫn là chữ/số (`ZaloPC`), không phải dấu ngăn cách bắt
    /// đầu một tên khác (`Code - Insiders`, `Notion Calendar`, `Demo App Pro`).
    static func continuesWithoutSeparator(_ s: String, afterNormalized count: Int) -> Bool {
        var seen = 0
        for u in s.lowercased().unicodeScalars {
            let alnum = (u >= "a" && u <= "z") || (u >= "0" && u <= "9")
            if seen == count { return alnum }
            if alnum { seen += 1 }
        }
        return false
    }
}

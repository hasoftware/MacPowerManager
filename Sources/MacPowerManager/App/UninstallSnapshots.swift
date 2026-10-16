#if DEBUG
import CleanCore
import Foundation

/// Dữ liệu giả cho ảnh chụp trang Gỡ ứng dụng (`--render-snapshots`, MPM_SNAPSHOT_FILTER=uninstall).
@MainActor
enum UninstallMock {
    /// Backend không làm gì: ảnh chụp không chạm đĩa, không đọc tiến trình.
    struct Backend: UninstallBackend {
        func loadApps(cancellation: CancellationToken) throws -> AppCatalog.Listing { AppCatalog.Listing(apps: []) }
        func appSize(_ app: InstalledApp, cancellation: CancellationToken) -> Int64? { nil }
        func collect(_ apps: [InstalledApp], cancellation: CancellationToken) throws -> UninstallCollection {
            UninstallCollection(listing: AppCatalog.Listing(apps: []), apps: apps, findings: [])
        }
        /// App đang chạy giả (trang đọc lại khi hiện ra).
        var running: [String: AppRunState] = [:]
        func runStates(of apps: [InstalledApp], findings: [Finding]) -> [String: AppRunState] {
            running.filter { key, _ in apps.contains { $0.path == key } }
        }
        func quit(_ app: InstalledApp, processes: [RunningProcess]) -> Bool { false }
    }

    static let home = CleanupMock.home
    static let mb: Int64 = 1_048_576
    private static let day: TimeInterval = 86_400
    private static let now = Date()

    private static func app(_ name: String, _ bid: String, _ version: String, daysAgo: Double?, folder: String = "/Applications") -> InstalledApp {
        InstalledApp(path: "\(folder)/\(name).app", name: name, bundleID: bid, version: version,
                     lastUsed: daysAgo.map { now.addingTimeInterval(-$0 * day) })
    }

    static let warp = app("Cloudflare WARP", "com.cloudflare.1dot1dot1dot1.macos", "2026.9.1", daysAgo: 0)
    static let messenger = app("Messenger", "com.facebook.archon.developerID", "507.0", daysAgo: 12)
    static let altTab = app("AltTab", "com.lwouis.alt-tab-macos", "10.12.0", daysAgo: 140)
    static let zalo = app("Zalo", "com.vng.zalo", "26.9.10", daysAgo: 21)

    static let apps: [InstalledApp] = [
        altTab,
        app("Antigravity", "com.google.antigravity", "1.4.2", daysAgo: 3),
        warp,
        app("Ghostty", "com.mitchellh.ghostty", "1.2.0", daysAgo: 0.2),
        app("Google Chrome", "com.google.Chrome", "141.0.7390.66", daysAgo: 1),
        app("iMazing", "com.DigiDNA.iMazing3Mac", "3.2.1", daysAgo: 64),
        app("LINE", "jp.naver.line.mac", "9.11.0", daysAgo: 2),
        messenger,
        app("Microsoft Word", "com.microsoft.Word", "16.101", daysAgo: 30),
        app("Notion", "notion.id", "4.21.0", daysAgo: 5),
        app("Notion Calendar", "com.cron.electron", "1.131.0", daysAgo: nil),
        app("SF Symbols", "com.apple.SFSymbols", "7.1", daysAgo: 220, folder: "/Applications/Utilities"),
        app("WhatsApp", "net.whatsapp.WhatsApp", "25.28.74", daysAgo: 9),
        app("Xcode", "com.apple.dt.Xcode", "26.1", daysAgo: 0.5),
        zalo,
    ]

    static let sizes: [String: Int64] = {
        let values: [String: Int64] = [
            "AltTab": 30 * mb, "Antigravity": 690 * mb, "Cloudflare WARP": 118 * mb, "Ghostty": 42 * mb,
            "Google Chrome": 1_420 * mb, "iMazing": 610 * mb, "LINE": 702 * mb, "Messenger": 286 * mb,
            "Microsoft Word": 2_140 * mb, "Notion": 410 * mb, "Notion Calendar": 255 * mb, "WhatsApp": 372 * mb,
            "Zalo": 746 * mb,
        ]
        // SF Symbols, Xcode: chưa tính xong
        return Dictionary(uniqueKeysWithValues: apps.compactMap { a in values[a.name].map { (a.path, $0) } })
    }()

    // MARK: Xem lại

    private static func related(_ app: InstalledApp, _ path: String, _ match: AppFileMatch, _ size: Int64 = 0,
                                category: CleanCategory = .appFiles, launchd: String? = nil, domain: String = "gui/501",
                                needsAdmin: Bool = false) -> Finding {
        let name = (path as NSString).lastPathComponent
        let action: CleanAction = launchd.map { .launchdJob(plist: path, label: $0, domain: domain) } ?? .trashPath(path: path)
        return Finding(category: category, severity: .high, name: name, target: path,
                       reason: .appRelated(app.ref, match: match), sizeBytes: size, action: action, needsAdmin: needsAdmin)
    }

    private static func bundle(_ app: InstalledApp, needsAdmin: Bool = false) -> Finding {
        Finding(category: .app, severity: .high, name: app.name, target: app.path, reason: .appBundle(app.ref),
                sizeBytes: sizes[app.path] ?? 0, action: .trashPath(path: app.path), needsAdmin: needsAdmin)
    }

    /// Bundle, container, group container dùng chung, LaunchAgent, LaunchDaemon + helper cần quản trị, biên nhận,
    /// bundle cần quyền (AltTab), app đang chạy cùng dịch vụ root (WARP), khớp gần đúng + chỉ xóa dữ liệu (Zalo).
    static let findings: [Finding] = {
        let lib = home + "/Library"
        let m = messenger, w = warp, a = altTab, z = zalo
        return [
            bundle(m),
            related(m, lib + "/Containers/com.facebook.archon.developerID", .bundleID, 212 * mb),
            related(m, lib + "/Containers/com.facebook.archon.developerID.ShareExtension", .embeddedBundleID, 1 * mb),
            Finding(category: .appFiles, severity: .info, name: "group.com.facebook.family",
                    target: lib + "/Group Containers/group.com.facebook.family",
                    reason: .appRelatedShared(m.ref, match: .appGroup, sharedWith: ["WhatsApp"]), sizeBytes: 48 * mb,
                    action: .reportOnly),
            related(m, lib + "/Application Scripts/com.facebook.archon.developerID", .bundleID),
            related(m, lib + "/LaunchAgents/com.facebook.archon.developerID.updater.plist", .launchdProgramInBundle,
                    launchd: "com.facebook.archon.developerID.updater"),

            bundle(w, needsAdmin: true),
            related(w, lib + "/Caches/com.cloudflare.1dot1dot1dot1.macos", .bundleID, 6 * mb),
            related(w, lib + "/Preferences/com.cloudflare.1dot1dot1dot1.macos.plist", .bundleID),
            related(w, "/Library/LaunchDaemons/com.cloudflare.1dot1dot1dot1.macos.warp.daemon.plist", .launchdProgramInBundle,
                    launchd: "com.cloudflare.1dot1dot1dot1.macos.warp.daemon", domain: "system", needsAdmin: true),
            related(w, "/Library/PrivilegedHelperTools/com.cloudflare.1dot1dot1dot1.macos.helper", .privilegedHelper, 3 * mb,
                    needsAdmin: true),
            Finding(category: .receipt, severity: .medium, name: "com.cloudflare.1dot1dot1dot1.macos",
                    target: "/var/db/receipts/com.cloudflare.1dot1dot1dot1.macos",
                    reason: .appRelated(w.ref, match: .packageReceipt), action: .pkgReceipt(id: "com.cloudflare.1dot1dot1dot1.macos"),
                    needsAdmin: true),

            bundle(a, needsAdmin: true),
            related(a, lib + "/Application Support/com.lwouis.alt-tab-macos", .bundleID, 1 * mb / 10),
            related(a, lib + "/Preferences/com.lwouis.alt-tab-macos.plist", .bundleID),
            related(a, lib + "/LaunchAgents/com.lwouis.alt-tab-macos.plist", .launchdLabel, launchd: "com.lwouis.alt-tab-macos"),

            bundle(z, needsAdmin: true),
            related(z, lib + "/Application Support/ZaloPC", .namePrefix, 1_397 * mb),
            related(z, lib + "/Application Support/ZaloData", .namePrefix, 833 * mb),
            related(z, lib + "/Application Support/Caches/zalo-updater", .updaterCache, 304 * mb),
            related(z, lib + "/Preferences/com.vng.zalo.plist", .bundleID),
        ]
    }()

    static let reviewApps = [messenger, warp, altTab, zalo]

    static var selected: Set<String> {
        let names: Set = ["Messenger", "com.facebook.archon.developerID", "com.lwouis.alt-tab-macos.plist",
                          "com.cloudflare.1dot1dot1dot1.macos.plist", "zalo-updater"]
        return Set(findings.filter { names.contains($0.name) }.map(\.id))
    }

    static let warpDaemon = RunningService(label: "com.cloudflare.1dot1dot1dot1.macos.warp.daemon", domain: "system",
                                           findingID: findings.first { $0.name.hasSuffix("warp.daemon.plist") }?.id ?? "",
                                           isSelectable: false)

    static let running: [String: AppRunState] = [
        warp.path: AppRunState(processes: [
            .init(process: RunningProcess(pid: 971, executablePath: warp.path + "/Contents/MacOS/Cloudflare WARP"), kind: .app),
            .init(process: RunningProcess(pid: 778, executablePath: warp.path + "/Contents/Resources/CloudflareWARP", ppid: 1),
                  kind: .service(warpDaemon), parentName: "launchd"),
        ]),
    ]

    /// Xcode đang dùng bởi công cụ khác (không có app để Thoát) và là thư mục developer đang chọn.
    static let xcode = apps.first { $0.name == "Xcode" }!

    static func xcodeModel() -> UninstallModel {
        let lib = home + "/Library"
        let x = xcode
        let fs = [bundle(x),
                  related(x, lib + "/Developer/Xcode/DerivedData", .developerData, 9_400 * mb),
                  Finding(category: .appFiles, severity: .high, name: "Archives", target: lib + "/Developer/Xcode/Archives",
                          reason: .appRelated(x.ref, match: .developerArchives), sizeBytes: 2_100 * mb, action: .reportOnly),
                  related(x, lib + "/Preferences/com.apple.dt.Xcode.plist", .bundleID)]
        let state = AppRunState(processes: [
            .init(process: RunningProcess(pid: 32907, executablePath: x.path + "/Contents/Developer/usr/bin/sourcekit-lsp"),
                  kind: .helper, parentName: "claude"),
        ])
        let m = UninstallModel(backend: Backend(running: [x.path: state]), removal: CleanupMock.Backend())
        m.setPreview(apps: apps, sizes: sizes, phase: .review, findings: fs, reviewApps: [x], running: [x.path: state],
                     activeDeveloperApps: [x.path])
        return m
    }

    static func model(_ phase: UninstallModel.Phase = .list, appSelection: Set<String> = [],
                      sortOrder: UninstallModel.SortOrder = .name) -> UninstallModel {
        let review = phase != .list
        let m = UninstallModel(backend: Backend(running: review ? running : [:]), removal: CleanupMock.Backend())
        m.setPreview(apps: apps, sizes: sizes, appSelection: appSelection, sortOrder: sortOrder, excluded: 2, phase: phase,
                     findings: review ? findings : [], reviewApps: review ? reviewApps : [],
                     selection: review ? selected : [], running: review ? running : [:],
                     rootOwnedApps: review ? [warp.path] : [])
        return m
    }

    /// Ghi chú bảng kết quả (cùng chuỗi với `UninstallModel`).
    static var resultNotes: [String] {
        let z = zalo.name, x = xcode.name
        return [String(localized: "\(z) vẫn còn cài; chỉ dữ liệu của nó đã được chuyển vào Thùng rác."),
                String(localized: "Đã gỡ \(x) đang được xcode-select dùng: chạy \"sudo xcode-select --reset\" trong Terminal để git, clang, swift chạy lại.")]
    }

    static var listSelection: Set<String> { [messenger.path, warp.path, altTab.path] }

    static var selectedItems: [CleanupItem] {
        let ids = selected
        return CleanupModel.makeItems(findings).filter { ids.contains($0.id) }
    }
}
#endif

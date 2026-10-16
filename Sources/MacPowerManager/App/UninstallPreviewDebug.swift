#if DEBUG
import CleanCore
import Foundation

/// `--uninstall-preview <tên app | đường dẫn | bundle id>...`: chạy luồng gỡ ứng dụng của CleanCore trên máy thật,
/// CHỈ ĐỌC (không gỡ gì), in mọi mục sẽ được đưa ra xem lại rồi thoát. `--uninstall-preview --list` liệt kê app.
enum UninstallPreviewDebug {
    static func run(_ args: [String]) {
        let clock = ContinuousClock()
        let runner = ProcessCommandRunner()
        let env = ScanEnvironment(homePath: FileManager.default.homeDirectoryForCurrentUser.path)
        let catalog = AppCatalog(env: env)
        let t0 = clock.now
        guard let listing = try? catalog.load() else { print("lỗi liệt kê app"); return }
        print("apps=\(listing.apps.count) references=\(listing.references.count) excluded=\(listing.excluded.count) "
              + "(\(format(clock.now - t0)))")
        let queries = args.prefix { !$0.hasPrefix("--") || $0 == "--list" }
        if queries.isEmpty || queries.contains("--list") {
            for a in listing.apps {
                print("  \(a.name)\t\(a.bundleID ?? "-")\t\(a.version ?? "-")\tteam=\(a.teamID ?? "-")\t"
                      + "lastUsed=\(a.lastUsed.map { "\($0)" } ?? "-")\t\(a.path)")
            }
            for x in listing.excluded { print("  [loại: \(x.reason.rawValue)] \(x.app.path)") }
            return
        }
        let uninstaller = AppUninstaller(env: env, runner: runner)
        let table = ProcessTableLister().runningProcesses()
        for q in queries {
            let found = listing.find(q)
            guard let app = found.first else {
                let ex = listing.findExcluded(q)
                if ex.isEmpty { print("\n== \(q): không tìm thấy") }
                for x in ex { print("\n== \(q): KHÔNG gỡ được (\(x.reason.rawValue)) \(x.app.path)") }
                continue
            }
            print("\n== \(app.name) \(app.version ?? "") [\(app.bundleID ?? "?")] \(app.path)")
            if app.bundlePath != app.path { print("   bundle thật: \(app.bundlePath)") }
            print("   team=\(app.teamID ?? "-") groups=\(app.appGroups) helpers=\(app.privilegedHelpers) "
                  + "names=\(app.bundleNames) lastUsed=\(app.lastUsed.map { "\($0)" } ?? "-")")
            let t1 = clock.now
            let findings: [Finding]
            do {
                findings = try uninstaller.collect([app], listing: listing)
            } catch {
                print("   lỗi: \(error)")
                continue
            }
            let state = AppUninstaller.runStates(apps: [app], findings: findings, table: table, env: env)[app.path]
            let procs = (state?.processes ?? []).map { p -> String in
                let kind: String = switch p.kind {
                case .app: "app"
                case .helper: "helper(parent=\(p.parentName ?? "?"))"
                case .service(let s): "service(\(s.domain)/\(s.label) selectable=\(s.isSelectable))"
                }
                return "\(p.process.pid):\(p.process.name) \(kind)"
            }
            print("   running=\(procs)")
            if AppUninstaller.activeDeveloperApps([app], env: env).contains(app.path) {
                print("   CẢNH BÁO: chứa thư mục developer đang chọn (xcode-select)")
            }
            print("   \(findings.count) mục, \(mb(findings.totalSizeBytes)) (\(format(clock.now - t1)))")
            for f in findings {
                let why: String
                switch f.reason {
                case .appBundle: why = "bundle"
                case .appRelated(_, let m): why = m.rawValue
                case .appRelatedShared(_, let m, let others): why = "\(m.rawValue) SHARED with \(others)"
                case .appRelatedJoint(_, let m, let co): why = "\(m.rawValue) JOINT with \(co.map(\.name))"
                default: why = "\(f.reason)"
                }
                let low = f.appFileMatch?.isLowConfidence == true ? " LOW" : ""
                print("   [\(f.category.rawValue)] \(why)\(low) size=\(mb(f.sizeBytes)) kind=\(f.kind.rawValue) "
                      + "needsAdmin=\(f.needsAdmin) \(f.target)")
            }
        }
    }

    private static func mb(_ b: Int64) -> String { String(format: "%.1fMB", Double(b) / 1_048_576) }

    private static func format(_ d: Duration) -> String {
        let c = d.components
        return String(format: "%.3fs", Double(c.seconds) + Double(c.attoseconds) / 1e18)
    }
}
#endif

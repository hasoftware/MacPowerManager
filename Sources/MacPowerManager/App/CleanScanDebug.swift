#if DEBUG
import CleanCore
import Foundation

/// `--clean-scan`: chạy toàn bộ bộ quét của CleanCore trên máy thật (CHỈ ĐỌC, không gỡ gì), in từng finding và thời
/// gian của từng bộ quét rồi thoát. Lặp lại đúng các bước của `ScanEngine.run` để đo được từng bộ quét.
enum CleanScanDebug {
    static func run() {
        let clock = ContinuousClock()
        let runner = ProcessCommandRunner()
        let started = clock.now
        let env = ScanEnvironment.live(runner: runner)
        let envTime = clock.now - started
        let ignored = Set(IgnoreList(env: env).load())
        let fda = env.hasFullDiskAccess()
        let indexStart = clock.now
        let index: AppIndex
        do {
            index = try AppIndex.build(env: env, runner: runner, isCancelled: { false })
        } catch {
            print("lỗi dựng chỉ mục: \(error)")
            return
        }
        let indexTime = clock.now - indexStart
        let ctx = ScanContext(env: env, index: index, runner: runner, hasFullDiskAccess: fda,
                              cancellation: CancellationToken())
        print("home=\(env.homePath) uid=\(env.uid) fda=\(fda) shellEnv=\(env.shellEnvironment != nil) "
              + "apps=\(index.validApps.count) deadApps=\(index.deadApps.count) bundleIDs=\(index.bundleIDs.count)")
        print("môi trường: \(format(envTime))  chỉ mục: \(format(indexTime))")

        var all: [Finding] = []
        var timings: [(String, Duration, Int)] = []
        for scanner in ScanEngine.defaultScanners {
            let t0 = clock.now
            do {
                let found = try scanner.scan(ctx)
                all += found
                timings.append((scanner.id, clock.now - t0, found.count))
            } catch {
                print("bộ quét \(scanner.id) lỗi: \(error)")
                timings.append((scanner.id, clock.now - t0, -1))
            }
        }
        let (kept, ignoredCount) = IgnoreList.apply(all, ignoring: ignored)
        let findings = kept.map { f -> Finding in
            var f = f
            f.needsAdmin = Remover.needsAdmin(f, env: env)
            return f
        }.sortedForReport()

        print("\n== FINDINGS (\(findings.count), bỏ qua \(ignoredCount)) ==")
        for f in findings {
            print("[\(f.severity.rawValue)] \(f.category.rawValue) | \(f.name) | \(f.target)")
            print("    reason=\(f.reason) size=\(f.sizeBytes)B kind=\(f.kind.rawValue) needsAdmin=\(f.needsAdmin)")
        }
        print("\n== THEO NHÓM ==")
        let groups = Dictionary(grouping: findings) { "\($0.category.rawValue)/\($0.severity.rawValue)" }
        for key in groups.keys.sorted() { print("\(key): \(groups[key]?.count ?? 0)") }
        print("\n== THỜI GIAN ==")
        for (id, d, n) in timings.sorted(by: { $0.1 > $1.1 }) { print("\(id)\t\(format(d))\t\(n)") }
        print("tổng: \(format(clock.now - started))")
    }

    private static func format(_ d: Duration) -> String {
        let c = d.components
        return String(format: "%.3fs", Double(c.seconds) + Double(c.attoseconds) / 1e18)
    }
}
#endif

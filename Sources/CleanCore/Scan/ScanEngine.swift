import Foundation

/// Tiến độ quét gửi về UI.
public struct ScanProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case indexing
        case scanning(scannerID: String)
        case finishing
    }

    public var phase: Phase
    /// Số bộ quét đã xong / tổng số.
    public var completed: Int
    public var total: Int
}

/// Kết quả một lượt quét.
public struct ScanResult: Sendable {
    /// Đã lọc ignore và sắp xếp như `sort_findings`.
    public var findings: [Finding]
    public var ignoredCount: Int
    public var hasFullDiskAccess: Bool
    public var index: AppIndex
    /// Bộ quét ném lỗi (không phải hủy): id → mô tả. Các bộ quét khác vẫn chạy.
    public var scannerErrors: [String: String]
}

/// Chạy mọi bộ quét (`run_all_scans`): load ignore → FDA → dựng chỉ mục MỘT lần → các bộ quét theo thứ tự →
/// áp ignore → sắp xếp. Chỉ chạy khi người dùng bấm; không có quét định kỳ. Gọi ngoài main thread.
public struct ScanEngine: Sendable {
    public let env: ScanEnvironment
    public let runner: CommandRunner
    public let scanners: [Scanner]
    public let ignoreList: IgnoreList
    public let signing: SigningInfoReader

    public init(env: ScanEnvironment, runner: CommandRunner, scanners: [Scanner] = ScanEngine.defaultScanners,
                ignoreList: IgnoreList? = nil, signing: SigningInfoReader = SecuritySigningInfoReader()) {
        self.env = env
        self.runner = runner
        self.scanners = scanners
        self.ignoreList = ignoreList ?? IgnoreList(env: env)
        self.signing = signing
    }

    /// Các bộ quét mức người dùng của P0, đúng thứ tự `run_all_scans` (thứ tự chỉ ảnh hưởng khóa phụ khi sắp xếp).
    public static let defaultScanners: [Scanner] = [
        EnvironmentScanner(),       // scan_path + scan_envvars
        AppSupportScanner(),        // scan_appsupport
        CachesScanner(),            // scan_caches
        PreferencesScanner(),       // scan_prefs
        ContainersScanner(),        // scan_containers
        SavedStateScanner(),        // scan_state (Saved Application State)
        LibraryMiscScanner(),       // scan_state (HTTPStorages, WebKit, Application Scripts, Cookies) + scan_logs
        LaunchdScanner(),           // scan_launchd
        LoginItemsScanner(),        // scan_loginitems
        HelpersScanner(),           // scan_helpers
        ReceiptsScanner(),          // scan_receipts
        DyldScanner(),              // scan_dyld
        CertificatesScanner(),      // scan_certs
        FirewallScanner(),          // scan_firewall
        TCCScanner(),               // scan_tcc
        SystemExtensionScanner(),   // scan_sysext
        SymlinkScanner(),           // scan_symlinks
        LaunchServicesScanner(),    // scan_lsregister
        NativeMessagingScanner(),   // scan_nativemsg
        PluginScanner(),            // scan_plugins
        BrokenAppScanner(),         // scan_brokenapps
        DockerScanner(),            // scan_docker
    ]

    /// Chạy toàn bộ. Ném `CancellationError` khi bị hủy.
    public func run(cancellation: CancellationToken = CancellationToken(),
                    progress: ((ScanProgress) -> Void)? = nil) throws -> ScanResult {
        let ignored = Set(ignoreList.load())
        let fda = env.hasFullDiskAccess()
        progress?(ScanProgress(phase: .indexing, completed: 0, total: scanners.count))
        let index = try AppIndex.build(env: env, runner: runner, signing: signing,
                                       isCancelled: { cancellation.isCancelled })
        let ctx = ScanContext(env: env, index: index, runner: runner, hasFullDiskAccess: fda, cancellation: cancellation)

        var all: [Finding] = []
        var errors: [String: String] = [:]
        for (i, s) in scanners.enumerated() {
            try ctx.checkCancelled()
            progress?(ScanProgress(phase: .scanning(scannerID: s.id), completed: i, total: scanners.count))
            do {
                all += try s.scan(ctx)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                errors[s.id] = String(describing: error)
            }
        }
        try ctx.checkCancelled()
        progress?(ScanProgress(phase: .finishing, completed: scanners.count, total: scanners.count))
        let (kept, ignoredCount) = IgnoreList.apply(all, ignoring: ignored)
        let findings = kept.map { f -> Finding in
            var f = f
            f.needsAdmin = Remover.needsAdmin(f, env: env)
            return f
        }.sortedForReport()
        return ScanResult(findings: findings, ignoredCount: ignoredCount, hasFullDiskAccess: fda, index: index,
                          scannerErrors: errors)
    }
}

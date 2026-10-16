import AppKit
import CleanCore
import Foundation

/// Kết quả một lần gom (đọc ngoài main actor).
struct UninstallCollection: Sendable {
    /// Danh sách app liệt kê lại NGAY trước khi gom: app cài sau lần liệt kê trước cũng được tính khi xét dùng chung.
    var listing: AppCatalog.Listing
    /// App được xem lại, đọc lại từ danh sách mới (giữ thứ tự).
    var apps: [InstalledApp]
    var findings: [Finding]
    /// App có gói đã không còn (vd đã kéo vào Thùng rác bằng Finder): chỉ còn phần sót lại.
    var missingApps: Set<String> = []
    /// App chứa thư mục developer đang chọn (`xcode-select -p`).
    var activeDeveloperApps: Set<String> = []
    /// App có gói thuộc root (cài bằng trình cài đặt/App Store): kéo vào Thùng rác cũng cần mật khẩu quản trị.
    var rootOwnedApps: Set<String> = []
}

/// Mọi việc chạm đĩa/tiến trình của trang Gỡ ứng dụng. Đồng bộ, gọi NGOÀI main actor (trừ `quit`). Test tiêm bản giả.
/// Việc gỡ (Thùng rác, sao lưu, kết quả) dùng chung `CleanupBackend.remove` với trang Quét tàn dư.
protocol UninstallBackend: Sendable {
    /// Liệt kê app (không tính dung lượng). Ném `CancellationError` khi bị hủy.
    func loadApps(cancellation: CancellationToken) throws -> AppCatalog.Listing
    /// Dung lượng bundle; nil khi bị hủy.
    func appSize(_ app: InstalledApp, cancellation: CancellationToken) -> Int64?
    /// Liệt kê lại app rồi gom bundle + file liên quan (đã tính dung lượng). Ném `CancellationError` khi bị hủy.
    func collect(_ apps: [InstalledApp], cancellation: CancellationToken) throws -> UninstallCollection
    /// Đọc bảng tiến trình MỚI: đường dẫn app → tiến trình chạy từ trong bundle, đã phân loại theo `findings`.
    /// App không chạy thì không có khóa.
    func runStates(of apps: [InstalledApp], findings: [Finding]) -> [String: AppRunState]
    /// Yêu cầu app thoát như Cmd-Q (app được hỏi lưu dữ liệu). false = không tiến trình nào nhận yêu cầu.
    @MainActor func quit(_ app: InstalledApp, processes: [RunningProcess]) -> Bool
}

/// Backend thật của trang Gỡ ứng dụng: AppCatalog + AppUninstaller của CleanCore, bảng tiến trình libproc,
/// NSRunningApplication để yêu cầu app thoát.
struct LiveUninstallBackend: UninstallBackend {
    var runner: CommandRunner
    var signing: SigningInfoReader
    var processes: RunningProcessLister
    var makeEnvironment: @Sendable () -> ScanEnvironment

    init(runner: CommandRunner = ProcessCommandRunner(), signing: SigningInfoReader = SecuritySigningInfoReader(),
         processes: RunningProcessLister = ProcessTableLister(),
         makeEnvironment: @escaping @Sendable () -> ScanEnvironment = {
             ScanEnvironment(homePath: FileManager.default.homeDirectoryForCurrentUser.path)
         }) {
        self.runner = runner
        self.signing = signing
        self.processes = processes
        self.makeEnvironment = makeEnvironment
    }

    private func catalog(_ env: ScanEnvironment) -> AppCatalog {
        AppCatalog(env: env, signing: signing, processes: processes)
    }

    func loadApps(cancellation: CancellationToken) throws -> AppCatalog.Listing {
        try catalog(makeEnvironment()).load { cancellation.isCancelled }
    }

    func appSize(_ app: InstalledApp, cancellation: CancellationToken) -> Int64? {
        catalog(makeEnvironment()).size(of: app) { cancellation.isCancelled }
    }

    func collect(_ apps: [InstalledApp], cancellation: CancellationToken) throws -> UninstallCollection {
        let env = makeEnvironment()
        // ~0,15 s, không tính dung lượng: rẻ hơn nhiều so với rủi ro coi thư mục chung là của riêng một app
        let listing = try catalog(env).load { cancellation.isCancelled }
        let fresh = apps.map { a in listing.apps.first { $0.path == a.path } ?? a }
        let findings = try AppUninstaller(env: env, runner: runner, signing: signing)
            .collect(fresh, listing: listing) { cancellation.isCancelled }
        return UninstallCollection(
            listing: listing, apps: fresh, findings: findings,
            missingApps: Set(fresh.filter { !env.lexists($0.bundlePath) }.map(\.path)),
            activeDeveloperApps: AppUninstaller.activeDeveloperApps(fresh, env: env),
            rootOwnedApps: Set(fresh.filter { FileProbe.stat(env.physicalPath($0.bundlePath))?.st_uid == 0 }.map(\.path)))
    }

    func runStates(of apps: [InstalledApp], findings: [Finding]) -> [String: AppRunState] {
        AppUninstaller.runStates(apps: apps, findings: findings, table: processes.runningProcesses(), env: makeEnvironment())
    }

    @MainActor
    func quit(_ app: InstalledApp, processes: [RunningProcess]) -> Bool {
        // App chính (có giao diện) nhận yêu cầu thoát; helper của nó thường tự thoát theo.
        let pids = Set(processes.map(\.pid))
        let bundlePaths = Set([app.path, app.bundlePath].map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        let targets = NSWorkspace.shared.runningApplications.filter { running in
            if pids.contains(running.processIdentifier) { return true }
            guard let url = running.bundleURL?.resolvingSymlinksInPath() else { return false }
            return bundlePaths.contains(url.path)
        }
        var asked = false
        for target in targets where target.terminate() { asked = true }
        return asked
    }
}

import CleanCore
import Foundation
import XCTest
@testable import MacPowerManager

/// Backend giả của trang Gỡ ứng dụng: trả dữ liệu cấu hình sẵn, ghi lại lời gọi.
final class FakeUninstallBackend: UninstallBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _apps: [InstalledApp] = []
    private var _findings: [Finding] = []
    private var _sizes: [String: Int64] = [:]
    private var _running: [String: AppRunState] = [:]
    private var _missing: Set<String> = []
    private var _activeDeveloper: Set<String> = []
    private var _blockedSize: String?
    private var _sizeCalls: [String] = []
    private var _loadCount = 0
    private var _collectCalls: [[String]] = []
    private var _quitCalls: [String] = []
    private var _blockCollect = false
    private var _collectStarted = 0
    var quitResult = true

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    var apps: [InstalledApp] { get { locked { _apps } } set { locked { _apps = newValue } } }
    var findings: [Finding] { get { locked { _findings } } set { locked { _findings = newValue } } }
    var sizes: [String: Int64] { get { locked { _sizes } } set { locked { _sizes = newValue } } }
    var running: [String: AppRunState] { get { locked { _running } } set { locked { _running = newValue } } }
    var missing: Set<String> { get { locked { _missing } } set { locked { _missing = newValue } } }
    var activeDeveloper: Set<String> { get { locked { _activeDeveloper } } set { locked { _activeDeveloper = newValue } } }
    /// Tính dung lượng app này chờ tới khi bị hủy (hoặc tới khi bỏ chặn).
    var blockedSize: String? { get { locked { _blockedSize } } set { locked { _blockedSize = newValue } } }
    var blockCollect: Bool { get { locked { _blockCollect } } set { locked { _blockCollect = newValue } } }
    var sizeCalls: [String] { locked { _sizeCalls } }
    var loadCount: Int { locked { _loadCount } }
    var collectCalls: [[String]] { locked { _collectCalls } }
    var collectStarted: Int { locked { _collectStarted } }
    var quitCalls: [String] { locked { _quitCalls } }

    func loadApps(cancellation: CancellationToken) throws -> AppCatalog.Listing {
        locked { _loadCount += 1 }
        return AppCatalog.Listing(apps: apps, excluded: [ExcludedApp(app: InstalledApp(path: "/System/Applications/Safari.app",
                                                                                    name: "Safari"), reason: .system)])
    }

    func appSize(_ app: InstalledApp, cancellation: CancellationToken) -> Int64? {
        locked { _sizeCalls.append(app.path) }
        while blockedSize == app.path && !cancellation.isCancelled { usleep(1_000) }
        if cancellation.isCancelled { return nil }
        return sizes[app.path] ?? 1
    }

    func collect(_ apps: [InstalledApp], cancellation: CancellationToken) throws -> UninstallCollection {
        locked { _collectCalls.append(apps.map(\.path)); _collectStarted += 1 }
        while blockCollect && !cancellation.isCancelled { usleep(1_000) }
        if cancellation.isCancelled { throw CancellationError() }
        let listing = try loadApps(cancellation: cancellation)
        let paths = Set(apps.map(\.path))
        return UninstallCollection(listing: listing, apps: apps,
                                   findings: findings.filter { $0.uninstallOwner.map { paths.contains($0.path) } ?? false },
                                   missingApps: missing.intersection(paths), activeDeveloperApps: activeDeveloper.intersection(paths))
    }

    func runStates(of apps: [InstalledApp], findings: [Finding]) -> [String: AppRunState] {
        let table = running
        var out: [String: AppRunState] = [:]
        for app in apps { if let p = table[app.path] { out[app.path] = p } }
        return out
    }

    func quit(_ app: InstalledApp, processes: [RunningProcess]) -> Bool {
        locked { _quitCalls.append(app.path) }
        return quitResult
    }
}

@MainActor
final class UninstallModelTests: XCTestCase {
    private var backend: FakeUninstallBackend!
    private var removal: FakeCleanupBackend!
    private var model: UninstallModel!

    private let day: TimeInterval = 86_400
    private lazy var alpha = InstalledApp(path: "/Applications/Alpha.app", name: "Alpha", bundleID: "com.vendor.alpha",
                                          version: "1.0", lastUsed: Date().addingTimeInterval(-30 * day))
    private lazy var beta = InstalledApp(path: "/Applications/Beta.app", name: "Beta", bundleID: "org.beta.app",
                                         version: "2.1", lastUsed: Date().addingTimeInterval(-1 * day))
    private lazy var gamma = InstalledApp(path: "/Applications/Utilities/Gamma.app", name: "Gamma", bundleID: "io.gamma")

    private let home = "/Users/t/Library"

    // Alpha: bundle, container, LaunchAgent (chọn được); helper + LaunchDaemon cần quản trị; biên nhận; thư mục dùng chung.
    private lazy var alphaBundle = Finding(category: .app, severity: .high, name: "Alpha", target: alpha.path,
                                           reason: .appBundle(alpha.ref), sizeBytes: 500, action: .trashPath(path: alpha.path))
    private lazy var alphaContainer = related(alpha, home + "/Containers/com.vendor.alpha", .bundleID, size: 200)
    private lazy var alphaAgent = Finding(category: .appFiles, severity: .high, name: "com.vendor.alpha.agent.plist",
                                          target: home + "/LaunchAgents/com.vendor.alpha.agent.plist",
                                          reason: .appRelated(alpha.ref, match: .launchdProgramInBundle),
                                          action: .launchdJob(plist: home + "/LaunchAgents/com.vendor.alpha.agent.plist",
                                                              label: "com.vendor.alpha.agent", domain: "gui/501"))
    private lazy var alphaHelper = related(alpha, "/Library/PrivilegedHelperTools/com.vendor.alpha.helper", .privilegedHelper,
                                           size: 10, needsAdmin: true)
    private lazy var alphaReceipt = Finding(category: .receipt, severity: .medium, name: "com.vendor.alpha",
                                            target: "/var/db/receipts/com.vendor.alpha",
                                            reason: .appRelated(alpha.ref, match: .packageReceipt),
                                            action: .pkgReceipt(id: "com.vendor.alpha"), needsAdmin: true)
    private lazy var alphaShared = Finding(category: .appFiles, severity: .info, name: "Vendor",
                                           target: home + "/Application Support/Vendor",
                                           reason: .appRelatedShared(alpha.ref, match: .name, sharedWith: ["Gamma"]),
                                           sizeBytes: 50, action: .reportOnly)
    private lazy var betaBundle = Finding(category: .app, severity: .high, name: "Beta", target: beta.path,
                                          reason: .appBundle(beta.ref), sizeBytes: 900, action: .trashPath(path: beta.path))
    private lazy var betaPrefs = related(beta, home + "/Preferences/org.beta.app.plist", .bundleID, size: 1)

    private var alphaItems: [Finding] { [alphaBundle, alphaContainer, alphaAgent, alphaHelper, alphaReceipt, alphaShared] }

    private func appRunning(_ app: InstalledApp, pid: Int32 = 42) -> AppRunState {
        AppRunState(processes: [.init(process: RunningProcess(pid: pid, executablePath: app.path + "/Contents/MacOS/x"), kind: .app)])
    }

    private func related(_ app: InstalledApp, _ path: String, _ match: AppFileMatch, size: Int64 = 0,
                         needsAdmin: Bool = false) -> Finding {
        Finding(category: .appFiles, severity: .high, name: (path as NSString).lastPathComponent, target: path,
                reason: .appRelated(app.ref, match: match), sizeBytes: size, action: .trashPath(path: path),
                needsAdmin: needsAdmin)
    }

    override func setUp() async throws {
        backend = FakeUninstallBackend()
        backend.apps = [alpha, beta, gamma]
        backend.sizes = [alpha.path: 500, beta.path: 900, gamma.path: 20]
        backend.findings = alphaItems + [betaBundle, betaPrefs]
        removal = FakeCleanupBackend()
        model = UninstallModel(backend: backend, removal: removal)
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("hết thời gian chờ", file: file, line: line)
    }

    private func open() async {
        model.pageAppeared()
        await model.loadTask?.value
        await model.sizeTask?.value
    }

    private func review(_ apps: [InstalledApp]) async {
        await open()
        for app in apps { model.setAppSelected(app.path, true) }
        model.findRelatedFiles()
        await model.task?.value
    }

    // MARK: Danh sách app

    func testListsAppsOnFirstOpenNothingSelectedSizesComputed() async {
        XCTAssertEqual(backend.loadCount, 0, "không đọc gì trước khi mở trang")
        await open()
        XCTAssertEqual(backend.loadCount, 1)
        XCTAssertEqual(model.apps.map(\.id), [alpha.path, beta.path, gamma.path])
        XCTAssertEqual(model.excludedCount, 1)
        XCTAssertTrue(model.appSelection.isEmpty)
        XCTAssertEqual(model.sizes, [alpha.path: 500, beta.path: 900, gamma.path: 20])
        XCTAssertFalse(model.isSizing)
        // mở lại trang: không liệt kê lại, không tính lại
        model.pageDisappeared()
        await open()
        XCTAssertEqual(backend.loadCount, 1)
        XCTAssertEqual(backend.sizeCalls.count, 3)
    }

    func testSortAndSearch() async {
        await open()
        model.sortOrder = .size
        XCTAssertEqual(model.visibleApps.map(\.id), [beta.path, alpha.path, gamma.path])
        model.sortOrder = .lastUsed
        XCTAssertEqual(model.visibleApps.map(\.id), [beta.path, alpha.path, gamma.path], "chưa rõ lần dùng thì cuối")
        model.sortOrder = .name
        model.searchText = "IO.GAMMA"
        XCTAssertEqual(model.visibleApps.map(\.id), [gamma.path], "tìm theo bundle id, không phân biệt hoa thường")
        model.searchText = ""
        XCTAssertEqual(model.visibleApps.count, 3)
    }

    func testSizesStopWhenLeavingPageAndResumeOnReturn() async throws {
        backend.blockedSize = beta.path
        model.pageAppeared()
        await model.loadTask?.value
        try await waitUntil { backend.sizeCalls.contains(beta.path) }
        XCTAssertTrue(model.isSizing)
        model.pageDisappeared()
        XCTAssertFalse(model.isSizing)
        try await waitUntil { model.sizeTask == nil }
        // đợi việc nền cũ kết thúc rồi kiểm tra không tính tiếp
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.sizes[alpha.path], 500)
        XCTAssertNil(model.sizes[beta.path])
        XCTAssertFalse(backend.sizeCalls.contains(gamma.path), "rời trang thì không tính app tiếp theo")

        backend.blockedSize = nil
        model.pageAppeared()
        await model.sizeTask?.value
        XCTAssertEqual(model.sizes[beta.path], 900)
        XCTAssertEqual(model.sizes[gamma.path], 20)
        XCTAssertEqual(backend.sizeCalls.filter { $0 == alpha.path }.count, 1, "không tính lại app đã có dung lượng")
    }

    // MARK: Xem lại

    func testCollectGroupsPerAppNothingPreselected() async {
        await review([beta, alpha])
        XCTAssertEqual(model.phase, .review)
        XCTAssertEqual(backend.collectCalls, [[alpha.path, beta.path]], "theo thứ tự tên")
        XCTAssertEqual(model.groups.map(\.id), [alpha.path, beta.path])
        XCTAssertEqual(model.groups[0].items.map(\.id), alphaItems.map(\.id))
        XCTAssertEqual(model.groups[0].adminCount, 2)
        XCTAssertEqual(model.groups[0].sharedCount, 1)
        XCTAssertEqual(model.groups[0].removableBytes, 500 + 200)
        XCTAssertEqual(model.groups[0].reportBytes, 10 + 50)
        XCTAssertTrue(model.selection.isEmpty, "không chọn sẵn gì")
        XCTAssertEqual(model.rows.count, 2 + alphaItems.count + 2)
    }

    func testAdminReceiptAndSharedItemsNeverSelectable() async {
        await review([alpha])
        for f in [alphaHelper, alphaReceipt, alphaShared] {
            model.setSelected(f.id, true)
        }
        XCTAssertTrue(model.selection.isEmpty)
        let group = model.groups[0]
        model.setGroup(group, selected: true)
        XCTAssertEqual(model.selection, [alphaBundle.id, alphaContainer.id, alphaAgent.id], "chỉ mục chọn được")
        XCTAssertTrue(model.isGroupFullySelected(group))
        model.setGroup(group, selected: false)
        XCTAssertTrue(model.selection.isEmpty)
    }

    func testRunningAppBlocksSelectionUntilQuitAndRecheck() async {
        backend.running = [alpha.path: appRunning(alpha)]
        await review([alpha, beta])
        XCTAssertEqual(model.runningApps.map(\.path), [alpha.path])
        model.setSelected(alphaContainer.id, true)
        model.setGroup(model.groups[0], selected: true)
        XCTAssertTrue(model.selection.isEmpty, "mục của app đang chạy không chọn được")
        model.setSelected(betaPrefs.id, true)
        XCTAssertEqual(model.selection, [betaPrefs.id], "app khác không bị ảnh hưởng")

        model.quit(alpha)
        XCTAssertEqual(backend.quitCalls, [alpha.path])
        XCTAssertTrue(model.quitRequested.contains(alpha.path))
        // vẫn chạy khi kiểm tra lại: còn chặn
        model.recheckRunning()
        await model.runningTask?.value
        XCTAssertTrue(model.isRunning(alpha.path))

        backend.running = [:]
        model.recheckRunning()
        await model.runningTask?.value
        XCTAssertTrue(model.runningApps.isEmpty)
        XCTAssertTrue(model.quitRequested.isEmpty)
        model.setSelected(alphaContainer.id, true)
        XCTAssertTrue(model.isSelected(alphaContainer.id))
    }

    func testQuitFailureIsReported() async {
        backend.running = [alpha.path: appRunning(alpha)]
        backend.quitResult = false
        await review([alpha])
        model.quit(alpha)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.quitRequested.contains(alpha.path))
    }

    func testRemovalRechecksRunningAppsRightBefore() async {
        await review([alpha, beta])
        model.setSelected(alphaContainer.id, true)
        model.setSelected(betaPrefs.id, true)
        // người dùng mở lại Alpha sau khi chọn
        backend.running = [alpha.path: appRunning(alpha, pid: 7)]
        model.removeSelected()
        XCTAssertEqual(model.phase, .removing)
        await model.task?.value
        XCTAssertEqual(model.phase, .review)
        XCTAssertTrue(removal.removeCalls.isEmpty, "không gỡ gì khi còn app đang chạy")
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.isRunning(alpha.path))
        XCTAssertEqual(model.selection, [betaPrefs.id], "bỏ chọn mục của app đang chạy")
    }

    func testRemoveOutcomesHistoryAndClose() async throws {
        let cleanup = CleanupModel(backend: removal)
        UninstallModel.link(model, with: cleanup)
        cleanup.loadHistory()
        await cleanup.historyTask?.value
        XCTAssertTrue(cleanup.sessions.isEmpty)
        let session = CleanupSession(directory: URL(fileURLWithPath: "/tmp/backup"), name: "20261017_100000", date: nil,
                                     entryCount: 3, bytes: 700)
        removal.sessionList = [session]
        removal.outcomes = [alphaAgent.id: .failed(.trashFailed)]

        await review([alpha, beta])
        model.setGroup(model.groups[0], selected: true)
        let chosen = model.selectedItems.map(\.id)
        XCTAssertEqual(chosen, [alphaBundle.id, alphaContainer.id, alphaAgent.id])
        model.removeSelected()
        await model.task?.value
        guard case .finished(let run) = model.phase else { return XCTFail("phải có kết quả") }
        XCTAssertEqual(removal.removeCalls.map { $0.map(\.id) }, [[alphaBundle.id, alphaAgent.id, alphaContainer.id]],
                       "đúng các mục đã chọn: gói → job launchd → dữ liệu")
        XCTAssertEqual(run.count(.done), 2)
        XCTAssertEqual(run.count(.failed), 1)
        try await waitUntil { !cleanup.sessions.isEmpty }
        XCTAssertEqual(cleanup.sessions.map(\.name), [session.name], "Lịch sử dọn đọc lại sau khi gỡ")

        // Đóng: mục đã gỡ biến mất, mục lỗi còn lại, app có bundle đã gỡ bỏ khỏi lựa chọn; danh sách app liệt kê lại.
        model.closeResults(backToList: false)
        XCTAssertEqual(model.phase, .review)
        XCTAssertFalse(model.items.contains { $0.id == alphaBundle.id || $0.id == alphaContainer.id })
        XCTAssertTrue(model.items.contains { $0.id == alphaAgent.id })
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertFalse(model.appSelection.contains(alpha.path))
        XCTAssertTrue(model.appSelection.contains(beta.path))
        await model.loadTask?.value
        XCTAssertEqual(backend.loadCount, 3, "mở trang, gom (liệt kê lại), sau khi gỡ")
    }

    func testCloseBackToListReturnsToAppList() async {
        await review([beta])
        model.setGroup(model.groups[0], selected: true)
        model.removeSelected()
        await model.task?.value
        model.closeResults(backToList: true)
        XCTAssertEqual(model.phase, .list)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertTrue(model.appSelection.isEmpty)
        XCTAssertNil(model.sizes[beta.path], "dung lượng app đã gỡ bị bỏ")
    }

    func testNoParallelRemovalWithCleanupPage() async throws {
        let cleanup = CleanupModel(backend: removal)
        UninstallModel.link(model, with: cleanup)
        removal.removalGate = 0
        await review([beta])
        model.setGroup(model.groups[0], selected: true)
        model.removeSelected()
        try await waitUntil { removal.removeStarted }
        XCTAssertTrue(model.isRemoving)
        XCTAssertFalse(cleanup.canStartRestore, "không khôi phục khi đang gỡ ứng dụng")
        removal.releaseRemoval()
        await model.task?.value
        XCTAssertTrue(cleanup.canStartRestore)
    }

    func testCancelCollectDropsLateResult() async throws {
        await open()
        model.setAppSelected(alpha.path, true)
        backend.blockCollect = true
        model.findRelatedFiles()
        XCTAssertEqual(model.phase, .collecting)
        try await waitUntil { backend.collectStarted == 1 }
        model.cancelCollect()
        XCTAssertEqual(model.phase, .list)
        await model.task?.value
        XCTAssertEqual(model.phase, .list)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertTrue(model.appSelection.contains(alpha.path), "giữ app đã chọn")
    }

    func testCancelRefreshKeepsReview() async throws {
        await review([alpha])
        backend.blockCollect = true
        model.refreshReview()
        try await waitUntil { backend.collectStarted == 2 }
        model.cancelCollect()
        XCTAssertEqual(model.phase, .review)
        XCTAssertEqual(model.items.count, alphaItems.count)
        await model.task?.value
    }

    func testBackToListKeepsAppSelection() async {
        await review([alpha])
        model.setSelected(alphaContainer.id, true)
        model.backToList()
        XCTAssertEqual(model.phase, .list)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertEqual(model.appSelection, [alpha.path])
    }

    func testAppSelectionOnlyInListPhase() async {
        await review([alpha])
        model.setAppSelected(beta.path, true)
        XCTAssertFalse(model.appSelection.contains(beta.path))
    }

    // MARK: Rà soát P1

    func testCollectRelistsAppsSoSharedCheckSeesNewApps() async {
        await open()
        XCTAssertEqual(backend.loadCount, 1)
        let delta = InstalledApp(path: "/Applications/Delta.app", name: "Delta", bundleID: "com.vendor.delta")
        backend.apps = [alpha, beta, gamma, delta]       // cài sau lần liệt kê đầu
        model.setAppSelected(alpha.path, true)
        model.findRelatedFiles()
        await model.task?.value
        XCTAssertEqual(backend.loadCount, 2, "gom luôn liệt kê lại")
        XCTAssertTrue(model.apps.contains { $0.id == delta.path })
    }

    func testStaleListingReloadsOnReturnAndReviewRechecksRunning() async {
        var clock = Date()
        model.now = { clock }
        await open()
        model.pageDisappeared()
        clock = clock.addingTimeInterval(UninstallModel.listingMaxAge + 1)
        await open()
        XCTAssertEqual(backend.loadCount, 2, "danh sách cũ: liệt kê lại khi mở trang")

        await review([alpha])
        backend.running = [alpha.path: appRunning(alpha)]
        model.pageDisappeared()
        model.pageAppeared()
        await model.runningTask?.value
        XCTAssertTrue(model.isRunning(alpha.path), "quay lại trang khi đang xem lại: đọc lại app đang chạy")
    }

    func testJointItemNeedsEveryOwnerBundle() async {
        let joint = Finding(category: .appFiles, severity: .high, name: "group.shared", target: home + "/Group Containers/group.shared",
                            reason: .appRelatedJoint(alpha.ref, match: .appGroup, coOwners: [beta.ref]), sizeBytes: 5,
                            action: .trashPath(path: home + "/Group Containers/group.shared"))
        backend.findings = alphaItems + [betaBundle, betaPrefs, joint]
        await review([alpha, beta])
        model.setSelected(joint.id, true)
        XCTAssertFalse(model.isSelected(joint.id), "gói các app chủ chưa chọn")
        model.setSelected(alphaBundle.id, true)
        model.setSelected(joint.id, true)
        XCTAssertFalse(model.isSelected(joint.id), "Beta vẫn ở lại")
        model.setSelected(betaBundle.id, true)
        model.setSelected(joint.id, true)
        XCTAssertTrue(model.isSelected(joint.id))
        model.setSelected(betaBundle.id, false)
        XCTAssertFalse(model.isSelected(joint.id), "bỏ chọn gói Beta thì bỏ luôn mục chung")
        // Chọn tất cả của Alpha: Beta chưa chọn nên mục chung không vào
        model.setGroup(model.groups[0], selected: true)
        XCTAssertFalse(model.isSelected(joint.id))
        model.setGroup(model.groups[1], selected: true)
        model.setGroup(model.groups[0], selected: true)
        XCTAssertTrue(model.isSelected(joint.id))
    }

    func testLowConfidenceItemsNotInSelectAll() async {
        let guess = related(alpha, home + "/Application Support/AlphaData", .namePrefix, size: 70)
        backend.findings = alphaItems + [guess]
        await review([alpha])
        model.setGroup(model.groups[0], selected: true)
        XCTAssertFalse(model.isSelected(guess.id))
        XCTAssertEqual(model.groups[0].lowConfidenceCount, 1)
        model.setSelected(guess.id, true)
        XCTAssertTrue(model.isSelected(guess.id), "chọn từng mục thì được")
        XCTAssertTrue(model.confirmWarnings.contains { $0.contains("Alpha") })
    }

    /// WARP: GUI + LaunchDaemon root chạy từ gói. Thoát GUI xong thì thôi chờ; dữ liệu gỡ được, gói thì không.
    func testRootServiceBlocksOnlyBundleAndQuitDoesNotSpinForever() async {
        let daemon = RunningService(label: "com.vendor.alpha.daemon", domain: "system", findingID: alphaHelper.id, isSelectable: false)
        let svc = AppRunState.Process(process: RunningProcess(pid: 778, executablePath: alpha.path + "/Contents/Resources/d", ppid: 1),
                                      kind: .service(daemon), parentName: "launchd")
        let gui = AppRunState.Process(process: RunningProcess(pid: 971, executablePath: alpha.path + "/Contents/MacOS/Alpha"), kind: .app)
        backend.running = [alpha.path: AppRunState(processes: [gui, svc])]
        await review([alpha])
        model.setSelected(alphaContainer.id, true)
        XCTAssertFalse(model.isSelected(alphaContainer.id), "GUI đang chạy: khóa hết")
        model.quit(alpha)
        XCTAssertEqual(model.quitRequested, [alpha.path])
        backend.running = [alpha.path: AppRunState(processes: [svc])]   // GUI thoát, daemon (KeepAlive) còn
        model.recheckRunning()
        await model.runningTask?.value
        XCTAssertTrue(model.quitRequested.isEmpty, "không còn app để chờ thoát")
        XCTAssertTrue(model.isRunning(alpha.path))
        model.setSelected(alphaContainer.id, true)
        XCTAssertTrue(model.isSelected(alphaContainer.id), "dữ liệu người dùng gỡ được")
        model.setSelected(alphaBundle.id, true)
        XCTAssertFalse(model.isSelected(alphaBundle.id), "gói bị khóa tới khi dịch vụ root dừng")
        XCTAssertEqual(model.runBlock(model.items.first { $0.id == alphaBundle.id }!),
                       .serviceNeedsAdmin(label: "com.vendor.alpha.daemon", domain: "system"))
        XCTAssertEqual(UninstallModel.stopCommand(for: daemon), "sudo launchctl bootout system/com.vendor.alpha.daemon")
    }

    /// Agent người dùng chạy từ gói: gỡ được khi chọn cả job (dừng trước); không chọn job thì không gỡ gì.
    func testUserServiceMustBeSelectedToRemove() async {
        let agent = RunningService(label: "com.vendor.alpha.agent", domain: "gui/501", findingID: alphaAgent.id, isSelectable: true)
        backend.running = [alpha.path: AppRunState(processes: [
            .init(process: RunningProcess(pid: 5, executablePath: alpha.path + "/Contents/Resources/agent"), kind: .service(agent)),
        ])]
        await review([alpha])
        model.setSelected(alphaBundle.id, true)
        XCTAssertTrue(model.isSelected(alphaBundle.id))
        XCTAssertTrue(model.confirmWarnings.contains { $0.contains(alphaAgent.name) }, "gói được chọn mà job thì không")
        model.removeSelected()
        await model.task?.value
        XCTAssertEqual(model.phase, .review)
        XCTAssertTrue(removal.removeCalls.isEmpty)
        XCTAssertTrue(model.errorMessage?.contains("com.vendor.alpha.agent") == true)
        model.errorMessage = nil
        model.setSelected(alphaAgent.id, true)
        model.removeSelected()
        await model.task?.value
        XCTAssertEqual(removal.removeCalls.map { $0.map(\.id) }, [[alphaBundle.id, alphaAgent.id]])
    }

    func testDataOnlyAndActiveDeveloperWarningsAndNotes() async {
        backend.activeDeveloper = [alpha.path]
        await review([alpha, beta])
        let alphaGroup = model.groups[0], betaGroup = model.groups[1]
        model.setSelected(betaPrefs.id, true)
        XCTAssertTrue(model.isDataOnly(betaGroup))
        XCTAssertFalse(model.isDataOnly(alphaGroup))
        XCTAssertTrue(model.confirmWarnings.contains { $0.contains("Beta") })
        model.setSelected(alphaBundle.id, true)
        XCTAssertTrue(model.confirmWarnings.contains { $0.contains("xcode-select") })
        model.removeSelected()
        await model.task?.value
        guard case .finished = model.phase else { return XCTFail("phải có kết quả") }
        XCTAssertTrue(model.resultNotes.contains { $0.contains("Beta") }, "Beta vẫn còn cài")
        XCTAssertTrue(model.resultNotes.contains { $0.contains("xcode-select --reset") })
    }

    func testMissingBundleIsNotDataOnly() async {
        backend.missing = [beta.path]
        backend.findings = alphaItems + [betaPrefs]
        await review([beta])
        model.setSelected(betaPrefs.id, true)
        XCTAssertFalse(model.isDataOnly(model.groups[0]), "gói đã gỡ bằng Finder: chỉ còn phần sót lại")
    }

    func testSizeSortWaitsForSizingToFinish() async throws {
        backend.blockedSize = gamma.path
        model.sortOrder = .size
        model.pageAppeared()
        await model.loadTask?.value
        try await waitUntil { backend.sizeCalls.contains(gamma.path) }
        XCTAssertEqual(model.visibleApps.map(\.id), [alpha.path, beta.path, gamma.path], "không đảo dòng khi đang tính")
        backend.blockedSize = nil
        await model.sizeTask?.value
        try await waitUntil { model.visibleApps.first?.id == beta.path }
        XCTAssertEqual(model.visibleApps.map(\.id), [beta.path, alpha.path, gamma.path])
        XCTAssertFalse(model.selectedAppsSizePending)
    }

    func testLastUsedText() {
        let now = Date()
        XCTAssertFalse(UninstallText.lastUsed(nil).isEmpty)
        XCTAssertEqual(UninstallText.lastUsed(now, now: now), UninstallText.lastUsed(now.addingTimeInterval(-1), now: now))
        XCTAssertNotEqual(UninstallText.lastUsed(now.addingTimeInterval(-40 * day), now: now), UninstallText.lastUsed(now, now: now))
    }
}

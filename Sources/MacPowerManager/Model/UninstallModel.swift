import CleanCore
import Foundation
import Observation

// MARK: - Dòng hiển thị

/// Một app trong danh sách (khóa tìm kiếm tính sẵn).
struct UninstallAppRow: Identifiable, Equatable, Sendable {
    let app: InstalledApp
    let searchKey: String

    var id: String { app.path }

    init(app: InstalledApp) {
        self.app = app
        searchKey = ([app.name] + app.bundleNames + [app.bundleID ?? ""]).joined(separator: "\n").lowercased()
    }
}

/// Các mục của một app trong bước xem lại.
struct UninstallGroup: Identifiable, Equatable {
    let app: InstalledApp
    let items: [CleanupItem]
    /// Mục chọn được (không chỉ báo, không cần quản trị).
    let selectableIDs: [String]
    /// Mục "Chọn tất cả của app này" lấy: chọn được và không phải khớp gần đúng.
    let bulkIDs: [String]
    /// Tổng dung lượng mục chọn được (không tính hai lần mục nằm trong mục khác).
    let removableBytes: Int64
    /// Tổng dung lượng mục chỉ báo/cần quản trị/dùng chung.
    let reportBytes: Int64
    let adminCount: Int
    let sharedCount: Int
    let lowConfidenceCount: Int
    /// Mục gói ứng dụng (nil khi gói không còn hoặc bị chốt an toàn chặn).
    let bundleID: String?

    var id: String { app.path }

    init(app: InstalledApp, items: [CleanupItem]) {
        self.app = app
        self.items = items
        selectableIDs = items.filter(\.selectable).map(\.id)
        bulkIDs = items.filter { $0.selectable && $0.finding.appFileMatch?.isLowConfidence != true }.map(\.id)
        let paths = items.map(\.finding.target)
        func nested(_ t: String) -> Bool { paths.contains { t.hasPrefix($0 + "/") } }
        removableBytes = items.filter { $0.selectable && !nested($0.finding.target) }.reduce(0) { $0 + $1.finding.sizeBytes }
        reportBytes = items.filter { !$0.selectable && !nested($0.finding.target) }.reduce(0) { $0 + $1.finding.sizeBytes }
        adminCount = items.filter(\.finding.needsAdmin).count
        sharedCount = items.filter { $0.finding.isSharedAppFile || $0.finding.isJointAppFile }.count
        lowConfidenceCount = items.filter { $0.finding.appFileMatch?.isLowConfidence == true }.count
        bundleID = items.first { if case .appBundle = $0.finding.reason { true } else { false } }?.id
    }
}

/// Một dòng của danh sách xem lại (tiêu đề app hoặc mục): một ForEach phẳng, ID ổn định.
enum UninstallRow: Identifiable, Equatable {
    case header(UninstallGroup)
    case item(CleanupItem)

    var id: String {
        switch self {
        // ID mục luôn có "|", tiêu đề thì không
        case .header(let g): "#" + g.id
        case .item(let i): i.id
        }
    }
}

// MARK: - Model

/// Trang Gỡ ứng dụng: chọn app → gom file liên quan → xem lại từng mục (không chọn sẵn gì) → chuyển vào Thùng rác có
/// sao lưu (khôi phục trong Lịch sử dọn). Dung lượng app tính lười ở nền, dừng khi rời trang. Không timer.
@MainActor
@Observable
final class UninstallModel {
    enum Phase: Equatable {
        case list
        case collecting
        case review
        /// Tiến độ ở `removalProgress`.
        case removing
        case finished(CleanupRemovalRun)
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case name, size, lastUsed
        var id: Self { self }
    }

    /// Danh sách app cũ hơn chừng này thì mở lại trang sẽ liệt kê lại (app mới cài/đã gỡ).
    static let listingMaxAge: TimeInterval = 10 * 60

    private(set) var phase: Phase = .list

    // Danh sách app
    private(set) var isLoadingApps = false
    private(set) var appsLoaded = false
    /// Mọi app gỡ được, theo tên.
    private(set) var apps: [UninstallAppRow] = []
    /// Sau tìm kiếm và sắp xếp.
    private(set) var visibleApps: [UninstallAppRow] = []
    /// App thấy được nhưng không cho gỡ (hệ thống, chính app này…).
    private(set) var excludedCount = 0
    /// Đường dẫn app → dung lượng bundle (tính dần ở nền).
    private(set) var sizes: [String: Int64] = [:]
    private(set) var isSizing = false
    private(set) var appSelection: Set<String> = []
    var searchText = "" { didSet { if searchText != oldValue { rebuildVisibleApps() } } }
    var sortOrder: SortOrder = .name { didSet { if sortOrder != oldValue { rebuildVisibleApps() } } }

    /// App đang được gom file.
    private(set) var collectingApps: [InstalledApp] = []

    // Xem lại
    private(set) var reviewApps: [InstalledApp] = []
    private(set) var items: [CleanupItem] = []
    private(set) var groups: [UninstallGroup] = []
    private(set) var rows: [UninstallRow] = []
    private(set) var selection: Set<String> = []
    /// Đường dẫn app đang chạy → tiến trình đã phân loại (đọc lúc gom, khi bấm Kiểm tra lại, khi có app thoát, khi
    /// quay lại trang, ngay trước khi gỡ).
    private(set) var running: [String: AppRunState] = [:]
    /// App đã được yêu cầu thoát, đang chờ (chỉ khi còn tiến trình dạng app).
    private(set) var quitRequested: Set<String> = []
    /// App có gói đã không còn (gỡ bằng Finder): chỉ còn phần sót lại.
    private(set) var missingApps: Set<String> = []
    /// App chứa thư mục developer đang chọn (`xcode-select`).
    private(set) var activeDeveloperApps: Set<String> = []
    /// App có gói thuộc root.
    private(set) var rootOwnedApps: Set<String> = []
    private(set) var removalProgress = CleanupProgress(done: 0, total: 0)
    /// Ghi chú kèm bảng kết quả (app vẫn còn cài, lệnh xcode-select…).
    private(set) var resultNotes: [String] = []
    var errorMessage: String?

    /// Trang Dọn dẹp khác đang gỡ/khôi phục (cùng sửa đĩa và thư mục sao lưu): không gỡ song song.
    @ObservationIgnored var isOtherWorkBusy: () -> Bool = { false }
    /// Có phiên sao lưu mới (để Lịch sử dọn đọc lại).
    @ObservationIgnored var onSessionRecorded: () -> Void = {}

    @ObservationIgnored private let backend: UninstallBackend
    @ObservationIgnored private let removal: CleanupBackend
    @ObservationIgnored private var listing: AppCatalog.Listing?
    @ObservationIgnored private var listingDate: Date?
    @ObservationIgnored private var token: CancellationToken?
    @ObservationIgnored private var loadToken: CancellationToken?
    @ObservationIgnored private var sizeToken: CancellationToken?
    /// Tăng mỗi lần bắt đầu/hủy gom: kết quả đến muộn của lượt cũ bị bỏ.
    @ObservationIgnored private var generation = 0
    /// Hủy gom thì quay về bước trước đó (danh sách, hoặc xem lại khi đang tìm lại).
    @ObservationIgnored private var phaseBeforeCollect: Phase = .list
    @ObservationIgnored private var pageVisible = false
    /// Đồng hồ (test tiêm).
    @ObservationIgnored var now: () -> Date = Date.init
    // Việc nền gần nhất (test `await` để chờ).
    @ObservationIgnored private(set) var task: Task<Void, Never>?
    @ObservationIgnored private(set) var loadTask: Task<Void, Never>?
    @ObservationIgnored private(set) var sizeTask: Task<Void, Never>?
    @ObservationIgnored private(set) var runningTask: Task<Void, Never>?

    init(backend: UninstallBackend, removal: CleanupBackend) {
        self.backend = backend
        self.removal = removal
    }

    /// Nối với trang Quét tàn dư/Lịch sử dọn: không gỡ khi bên kia đang gỡ/khôi phục, lịch sử đọc lại sau mỗi lần gỡ.
    static func link(_ uninstall: UninstallModel, with cleanup: CleanupModel) {
        uninstall.isOtherWorkBusy = { [weak cleanup] in cleanup?.isModifyingDisk ?? false }
        uninstall.onSessionRecorded = { [weak cleanup] in cleanup?.refreshHistoryIfLoaded() }
        cleanup.isOtherWorkBusy = { [weak uninstall] in uninstall?.isRemoving ?? false }
    }

    var isRemoving: Bool { phase == .removing }

    // MARK: Vòng đời trang

    /// Mở trang: liệt kê app lần đầu (hoặc khi danh sách đã cũ), tính tiếp dung lượng còn thiếu; đang xem lại thì
    /// đọc lại app đang chạy (người dùng có thể đã thoát app ở trang khác).
    func pageAppeared() {
        pageVisible = true
        switch phase {
        case .review:
            recheckRunning()
        case .list:
            if !appsLoaded || listingDate.map({ now().timeIntervalSince($0) > Self.listingMaxAge }) == true {
                if !isLoadingApps { loadApps() }
            } else {
                startSizing()
            }
        default:
            if !appsLoaded && !isLoadingApps { loadApps() }
        }
    }

    /// Rời trang: dừng tính dung lượng (tiếp tục khi quay lại). Việc gom/gỡ đang chạy vẫn chạy tiếp.
    func pageDisappeared() {
        pageVisible = false
        stopSizing()
    }

    // MARK: Danh sách app

    /// Liệt kê lại app. `keepSizes`: giữ dung lượng đã tính của app còn đó (sau khi gỡ); false khi người dùng làm mới.
    func loadApps(keepSizes: Bool = true) {
        loadToken?.cancel()
        stopSizing()
        if !keepSizes { sizes = [:] }
        let token = CancellationToken()
        loadToken = token
        isLoadingApps = true
        let backend = backend
        loadTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try backend.loadApps(cancellation: token) }
            }.value
            self.finishLoad(result, token: token)
        }
    }

    private func finishLoad(_ result: Result<AppCatalog.Listing, Error>, token: CancellationToken) {
        guard token === loadToken else { return }
        loadToken = nil
        isLoadingApps = false
        switch result {
        case .success(let listing):
            apply(listing)
            if pageVisible && phase == .list { startSizing() }
        case .failure(let error):
            if !(error is CancellationError) {
                errorMessage = String(localized: "Không liệt kê được ứng dụng: \(String(describing: error))")
            }
        }
    }

    /// Nhận danh sách app mới (lúc liệt kê, hoặc lúc gom - gom luôn liệt kê lại).
    private func apply(_ listing: AppCatalog.Listing) {
        self.listing = listing
        listingDate = now()
        apps = listing.apps.map(UninstallAppRow.init)
        excludedCount = listing.excluded.count
        let paths = Set(apps.map(\.id))
        appSelection.formIntersection(paths)
        sizes = sizes.filter { paths.contains($0.key) }
        appsLoaded = true
        rebuildVisibleApps()
    }

    nonisolated static func sorted(_ rows: [UninstallAppRow], by order: SortOrder, sizes: [String: Int64]) -> [UninstallAppRow] {
        // `rows` đã theo tên: sort ổn định giữ thứ tự tên khi bằng nhau
        switch order {
        case .name:
            return rows
        case .size:
            return rows.enumerated().sorted { a, b in
                let sa = sizes[a.element.id] ?? -1, sb = sizes[b.element.id] ?? -1
                return sa != sb ? sa > sb : a.offset < b.offset
            }.map(\.element)
        case .lastUsed:
            return rows.enumerated().sorted { a, b in
                let da = a.element.app.lastUsed ?? .distantPast, db = b.element.app.lastUsed ?? .distantPast
                return da != db ? da > db : a.offset < b.offset
            }.map(\.element)
        }
    }

    private func rebuildVisibleApps() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = query.isEmpty ? apps : apps.filter { $0.searchKey.contains(query) }
        visibleApps = Self.sorted(filtered, by: sortOrder, sizes: sizes)
    }

    func isAppSelected(_ path: String) -> Bool { appSelection.contains(path) }

    func setAppSelected(_ path: String, _ on: Bool) {
        guard phase == .list else { return }
        if on {
            guard apps.contains(where: { $0.id == path }) else { return }
            appSelection.insert(path)
        } else {
            appSelection.remove(path)
        }
    }

    func clearAppSelection() { appSelection = [] }

    /// App đã chọn, theo tên.
    var selectedApps: [InstalledApp] { apps.filter { appSelection.contains($0.id) }.map(\.app) }

    /// Tổng dung lượng các app đã chọn (chỉ phần đã tính).
    var selectedAppsBytes: Int64 { appSelection.reduce(0) { $0 + (sizes[$1] ?? 0) } }

    /// Có app đã chọn chưa tính xong dung lượng (tổng chưa đủ).
    var selectedAppsSizePending: Bool { appSelection.contains { sizes[$0] == nil } }

    // MARK: Dung lượng (lười, nền, hủy được)

    private func startSizing() {
        guard sizeTask == nil, appsLoaded else { return }
        // dòng đang hiện trước, rồi tới phần còn lại
        let order = visibleApps + apps.filter { row in !visibleApps.contains { $0.id == row.id } }
        let pending = order.filter { sizes[$0.id] == nil }.map(\.app)
        guard !pending.isEmpty else { return }
        let token = CancellationToken()
        sizeToken = token
        isSizing = true
        let backend = backend
        sizeTask = Task {
            for app in pending {
                let size = await Task.detached(priority: .utility) { backend.appSize(app, cancellation: token) }.value
                if token.isCancelled { break }
                if let size { self.sizes[app.path] = size }
            }
            if self.sizeToken === token {
                self.sizeToken = nil
                self.sizeTask = nil
                self.isSizing = false
            }
            // Sắp theo dung lượng: sắp lại MỘT lần khi tính xong (hoặc dừng), không đảo dòng dưới con trỏ chuột.
            if self.sortOrder == .size { self.rebuildVisibleApps() }
        }
    }

    private func stopSizing() {
        sizeToken?.cancel()
        sizeToken = nil
        sizeTask = nil
        isSizing = false
    }

    // MARK: Gom file liên quan

    var canCollect: Bool { phase == .list && listing != nil && !appSelection.isEmpty && !isLoadingApps }

    /// Gom bundle + mọi file liên quan của các app đã chọn (chỉ đọc).
    func findRelatedFiles() {
        guard canCollect else { return }
        collect(selectedApps, returnTo: .list)
    }

    /// Gom lại cho đúng các app đang xem (sau khi cấp quyền, thoát app, hay tự dọn bằng tay).
    func refreshReview() {
        guard phase == .review, !reviewApps.isEmpty else { return }
        collect(reviewApps, returnTo: .review)
    }

    private func collect(_ chosen: [InstalledApp], returnTo: Phase) {
        stopSizing()
        loadToken?.cancel()
        loadToken = nil
        isLoadingApps = false
        generation += 1
        let gen = generation
        let token = CancellationToken()
        self.token = token
        errorMessage = nil
        phaseBeforeCollect = returnTo
        collectingApps = chosen
        phase = .collecting
        let backend = backend
        task = Task {
            let result = await Task.detached(priority: .userInitiated) {
                () -> Result<(UninstallCollection, [CleanupItem], [String: AppRunState]), Error> in
                Result {
                    // gom luôn liệt kê lại app: xét dùng chung trên danh sách mới, không phải danh sách cũ nhiều ngày
                    let c = try backend.collect(chosen, cancellation: token)
                    let running = backend.runStates(of: c.apps, findings: c.findings)
                    return (c, CleanupModel.makeItems(c.findings), running)
                }
            }.value
            self.finishCollect(result, generation: gen)
        }
    }

    private func finishCollect(_ result: Result<(UninstallCollection, [CleanupItem], [String: AppRunState]), Error>,
                               generation gen: Int) {
        guard gen == generation else { return }
        token = nil
        switch result {
        case .success(let (c, newItems, newRunning)):
            apply(c.listing)
            reviewApps = c.apps
            items = newItems
            // Kết quả mới: không giữ lựa chọn cũ, không chọn sẵn gì.
            selection = []
            running = newRunning
            quitRequested = []
            missingApps = c.missingApps
            activeDeveloperApps = c.activeDeveloperApps
            rootOwnedApps = c.rootOwnedApps
            // dung lượng bundle đã có sẵn trong kết quả gom
            for item in newItems {
                if case .appBundle(let ref) = item.finding.reason, item.finding.sizeBytes > 0 {
                    sizes[ref.path] = item.finding.sizeBytes
                }
            }
            if sortOrder == .size { rebuildVisibleApps() }
            rebuildGroups()
            phase = .review
        case .failure(let error):
            if !(error is CancellationError) {
                errorMessage = String(localized: "Không tìm được file liên quan: \(String(describing: error))")
            }
            phase = phaseBeforeCollect
            if phase == .list, pageVisible { startSizing() }
        }
    }

    func cancelCollect() {
        guard phase == .collecting else { return }
        token?.cancel()
        token = nil
        generation += 1
        phase = phaseBeforeCollect
        if phase == .list, pageVisible { startSizing() }
    }

    /// Về danh sách app (giữ các app đã chọn).
    func backToList() {
        guard phase == .review else { return }
        clearReview()
        phase = .list
        if pageVisible { startSizing() }
    }

    private func clearReview() {
        reviewApps = []
        items = []
        groups = []
        rows = []
        selection = []
        running = [:]
        quitRequested = []
        missingApps = []
        activeDeveloperApps = []
        rootOwnedApps = []
    }

    private func rebuildGroups() {
        var buckets: [String: [CleanupItem]] = [:]
        for item in items {
            guard let owner = item.finding.uninstallOwner?.path else { continue }
            buckets[owner, default: []].append(item)
        }
        groups = reviewApps.map { UninstallGroup(app: $0, items: buckets[$0.path] ?? []) }
        rows = groups.flatMap { [UninstallRow.header($0)] + $0.items.map(UninstallRow.item) }
        selection.formIntersection(Set(items.map(\.id)))
    }

    // MARK: Chọn mục

    func isRunning(_ appPath: String) -> Bool { running[appPath].map { !$0.isEmpty } ?? false }

    /// Vì sao mục chưa chọn được do app/dịch vụ đang chạy (nil = không bị chặn vì việc đang chạy).
    func runBlock(_ item: CleanupItem) -> UninstallBlock? {
        AppUninstaller.block(item.finding, states: running, selected: nil)
    }

    /// Mục chung nhiều app: gói của mọi app chủ phải cùng được chọn (hoặc đã không còn).
    private func jointOwnersSelected(_ f: Finding, in selection: Set<String>) -> Bool {
        guard f.isJointAppFile else { return true }
        return f.uninstallOwners.allSatisfy { owner in
            if missingApps.contains(owner.path) { return true }
            guard let bundle = groups.first(where: { $0.app.path == owner.path })?.bundleID else { return false }
            return selection.contains(bundle)
        }
    }

    /// Chọn được: không chỉ báo, không cần quản trị, không bị app/dịch vụ đang chạy chặn; mục chung nhiều app chỉ
    /// khi gói của mọi app chủ đã được chọn.
    func canSelect(_ item: CleanupItem) -> Bool {
        canSelect(item, given: selection)
    }

    private func canSelect(_ item: CleanupItem, given selection: Set<String>) -> Bool {
        guard item.selectable, item.finding.uninstallOwner != nil, runBlock(item) == nil else { return false }
        return jointOwnersSelected(item.finding, in: selection)
    }

    func isSelected(_ id: String) -> Bool { selection.contains(id) }

    func setSelected(_ id: String, _ on: Bool) {
        guard phase == .review else { return }
        if on {
            guard let item = items.first(where: { $0.id == id }), canSelect(item) else { return }
            selection.insert(id)
        } else {
            selection.remove(id)
            pruneSelection()
        }
    }

    func toggle(_ id: String) { setSelected(id, !isSelected(id)) }

    /// "Chọn tất cả của app này": chỉ mục chọn được, KHÔNG gồm mục khớp gần đúng (người dùng tự xem từng mục).
    func setGroup(_ group: UninstallGroup, selected: Bool) {
        guard phase == .review else { return }
        if selected {
            let candidates = items.filter { group.bulkIDs.contains($0.id) }
            var next = selection
            // gói trước, rồi mục chung nhiều app (cần gói các app chủ đã chọn)
            for item in candidates where !item.finding.isJointAppFile && canSelect(item, given: next) { next.insert(item.id) }
            for item in candidates where item.finding.isJointAppFile && canSelect(item, given: next) { next.insert(item.id) }
            selection = next
        } else {
            selection.subtract(group.selectableIDs)
            pruneSelection()
        }
    }

    /// Mục có thể chọn bằng "Chọn tất cả" lúc này.
    func bulkSelectableIDs(_ group: UninstallGroup) -> [String] {
        group.bulkIDs.filter { id in items.first { $0.id == id }.map { runBlock($0) == nil } ?? false }
    }

    func isGroupFullySelected(_ group: UninstallGroup) -> Bool {
        let ids = bulkSelectableIDs(group)
        return !ids.isEmpty && ids.allSatisfy(selection.contains)
    }

    func clearSelection() { selection = [] }

    /// Bỏ chọn mục không còn chọn được (app vừa chạy lại, gói app chủ của mục chung bị bỏ chọn).
    private func pruneSelection() {
        let bad = items.filter { selection.contains($0.id) && !canSelect($0) }.map(\.id)
        guard !bad.isEmpty else { return }
        selection.subtract(bad)
        pruneSelection()
    }

    /// Mục đã chọn theo thứ tự gom.
    var selectedItems: [CleanupItem] { items.filter { selection.contains($0.id) } }

    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.finding.sizeBytes } }

    var canRemove: Bool { phase == .review && !selection.isEmpty && !isOtherWorkBusy() }

    // MARK: Cảnh báo

    /// Đã chọn dữ liệu của app mà không chọn gói: app vẫn còn cài, chỉ mất dữ liệu (đăng xuất, mất cài đặt).
    func isDataOnly(_ group: UninstallGroup) -> Bool {
        guard !missingApps.contains(group.app.path) else { return false }
        let picked = group.items.contains { selection.contains($0.id) }
        return picked && !(group.bundleID.map(selection.contains) ?? false)
    }

    /// Gói được chọn nhưng job launchd của app thì không: job còn nạp, trỏ vào app đã gỡ.
    func orphanedJobs(_ group: UninstallGroup) -> [CleanupItem] {
        guard let bundle = group.bundleID, selection.contains(bundle) else { return [] }
        return group.items.filter { item in
            guard case .launchdJob = item.finding.action, !selection.contains(item.id) else { return false }
            return true
        }
    }

    /// Cảnh báo cho bảng xác nhận, theo thứ tự xem lại.
    var confirmWarnings: [String] {
        var out: [String] = []
        for g in groups {
            let name = g.app.name
            if isDataOnly(g) {
                out.append(String(localized: "\(name) vẫn còn cài: chỉ xóa dữ liệu của nó (có thể bị đăng xuất, mất cài đặt)."))
            }
            let jobs = orphanedJobs(g)
            if !jobs.isEmpty {
                let list = jobs.map(\.displayName).joined(separator: ", ")
                out.append(String(localized: "Gỡ \(name) nhưng giữ job launchd \(list): job sẽ trỏ tới ứng dụng đã gỡ và launchd báo lỗi mỗi lần chạy lại."))
            }
            if let bundle = g.bundleID, selection.contains(bundle), activeDeveloperApps.contains(g.app.path) {
                out.append(String(localized: "\(name) đang là công cụ dòng lệnh mặc định (xcode-select): git, clang, swift sẽ lỗi cho tới khi chạy \"sudo xcode-select --reset\"."))
            }
            let low = g.items.filter { selection.contains($0.id) && $0.finding.appFileMatch?.isLowConfidence == true }.count
            if low > 0 {
                out.append(String(localized: "\(low) mục của \(name) chỉ khớp gần đúng: hãy chắc đó là dữ liệu của ứng dụng này."))
            }
        }
        return out
    }

    // MARK: App đang chạy

    /// App đang xem có tiến trình chạy từ trong gói, theo thứ tự xem lại.
    var runningApps: [InstalledApp] { reviewApps.filter { isRunning($0.path) } }

    /// Yêu cầu app thoát (như Cmd-Q). Không timer: trang kiểm tra lại khi macOS báo có app thoát, hoặc khi bấm.
    func quit(_ app: InstalledApp) {
        guard phase == .review, let procs = running[app.path]?.appProcesses, !procs.isEmpty else { return }
        if backend.quit(app, processes: procs) {
            quitRequested.insert(app.path)
        } else {
            errorMessage = String(localized: "Không yêu cầu \(app.name) thoát được. Hãy tự thoát ứng dụng rồi bấm Kiểm tra lại.")
        }
    }

    /// Đọc lại bảng tiến trình cho các app đang xem.
    func recheckRunning() {
        guard phase == .review, !reviewApps.isEmpty else { return }
        let apps = reviewApps
        let findings = items.map(\.finding)
        let backend = backend
        let previous = runningTask
        runningTask = Task {
            await previous?.value
            let result = await Task.detached(priority: .userInitiated) { backend.runStates(of: apps, findings: findings) }.value
            self.applyRunning(result, apps: apps)
        }
    }

    /// macOS báo một app vừa thoát: kiểm tra lại ngay; helper của app thường thoát chậm hơn một chút nên còn app
    /// đang chờ thoát thì kiểm tra thêm MỘT lần nữa sau ít giây (không lặp).
    func appDidTerminate() {
        guard phase == .review, !running.isEmpty else { return }
        recheckRunning()
        let previous = runningTask
        runningTask = Task {
            await previous?.value
            guard !self.running.isEmpty else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            let apps = self.reviewApps
            let findings = self.items.map(\.finding)
            let backend = self.backend
            let result = await Task.detached(priority: .utility) { backend.runStates(of: apps, findings: findings) }.value
            self.applyRunning(result, apps: apps)
        }
    }

    private func applyRunning(_ result: [String: AppRunState], apps: [InstalledApp]) {
        // kết quả của lượt xem lại cũ: bỏ
        guard phase == .review || phase == .removing, apps == reviewApps else { return }
        running = result
        // hết tiến trình dạng app (dịch vụ/helper còn chạy không thoát bằng Cmd-Q được): thôi chờ
        quitRequested = quitRequested.filter { !(result[$0]?.appProcesses.isEmpty ?? true) }
        pruneSelection()
    }

    // MARK: Gỡ

    private enum Attempt: Sendable {
        case blocked([String: AppRunState], [UninstallPreflight.Blocked])
        case ran(CleanupRemovalRun)
    }

    /// Kiểm tra lại app đang chạy NGAY TRƯỚC khi gỡ (người dùng có thể vừa mở lại app): còn mục nào bị chặn thì
    /// không gỡ gì cả và báo lại. Thứ tự gỡ: theo app, gói → job launchd → dữ liệu, mục chung cuối cùng.
    func removeSelected() {
        guard canRemove else { return }
        let chosen = AppUninstaller.removalOrder(selectedItems.map(\.finding).filter(CleanupModel.isSelectable))
        guard !chosen.isEmpty else { return }
        let owners = reviewApps.filter { app in chosen.contains { $0.uninstallOwners.contains(app.ref) } }
        let all = items.map(\.finding)
        let missing = missingApps
        let token = CancellationToken()
        self.token = token
        removalProgress = CleanupProgress(done: 0, total: chosen.count)
        resultNotes = []
        phase = .removing
        let backend = backend
        let removal = removal
        task = Task {
            let attempt = await Task.detached(priority: .userInitiated) { () -> Attempt in
                let states = backend.runStates(of: owners, findings: all)
                let pre = AppUninstaller.preflight(chosen, states: states, missingApps: missing)
                if !pre.blocked.isEmpty { return .blocked(states, pre.blocked) }
                return .ran(removal.remove(pre.allowed, cancellation: token) { done, total in
                    Task { @MainActor [weak self] in self?.applyRemovalProgress(done, total) }
                })
            }.value
            self.finishRemoval(attempt, owners: owners, chosen: chosen)
        }
    }

    private func applyRemovalProgress(_ done: Int, _ total: Int) {
        guard phase == .removing, done > removalProgress.done else { return }
        removalProgress = CleanupProgress(done: done, total: total)
    }

    private func finishRemoval(_ attempt: Attempt, owners: [InstalledApp], chosen: [Finding]) {
        token = nil
        switch attempt {
        case .blocked(let states, let blocked):
            phase = .review
            for app in owners { running[app.path] = states[app.path] }
            pruneSelection()
            errorMessage = Self.blockedMessage(blocked)
        case .ran(let run):
            resultNotes = notes(after: run, chosen: chosen)
            phase = .finished(run)
            if run.backupDirectory != nil { onSessionRecorded() }
        }
    }

    /// "Chưa gỡ gì: …" kèm lý do từng loại.
    static func blockedMessage(_ blocked: [UninstallPreflight.Blocked]) -> String {
        var lines: [String] = []
        var seen = Set<UninstallBlock>()
        for b in blocked where seen.insert(b.reason).inserted {
            let owner = b.finding.uninstallOwner?.name ?? ""
            switch b.reason {
            case .running:
                lines.append(String(localized: "\(owner) đang chạy. Thoát ứng dụng rồi thử lại."))
            case .serviceNeedsAdmin(let label, _):
                lines.append(String(localized: "Dịch vụ nền \(label) đang chạy từ gói \(owner) và cần quyền quản trị để dừng."))
            case .serviceNotSelected(let label):
                lines.append(String(localized: "Dịch vụ nền \(label) của \(owner) đang chạy: chọn cả mục job của nó để dừng nó trước khi gỡ."))
            case .sharedWithKeptApp(let app):
                lines.append(String(localized: "\(b.finding.name) dùng chung với \(app), mà gói \(app) không được gỡ cùng."))
            }
        }
        return String(localized: "Chưa gỡ gì.") + "\n" + lines.joined(separator: "\n")
    }

    /// Ghi chú cho bảng kết quả: app vẫn còn cài sau khi xóa dữ liệu, lệnh cần chạy sau khi gỡ Xcode đang chọn.
    private func notes(after run: CleanupRemovalRun, chosen: [Finding]) -> [String] {
        let done = Set(run.items.filter(\.removed).map(\.findingID))
        var out: [String] = []
        for app in reviewApps {
            let mine = chosen.filter { $0.uninstallOwner == app.ref }
            let bundle = mine.first { if case .appBundle = $0.reason { true } else { false } }
            let bundleGone = bundle.map { done.contains($0.id) } ?? missingApps.contains(app.path)
            let dataRemoved = mine.contains { f in
                if case .appBundle = f.reason { return false }
                return done.contains(f.id)
            }
            if !bundleGone, dataRemoved {
                out.append(String(localized: "\(app.name) vẫn còn cài; chỉ dữ liệu của nó đã được chuyển vào Thùng rác."))
            }
            if let bundle, done.contains(bundle.id), activeDeveloperApps.contains(app.path) {
                out.append(String(localized: "Đã gỡ \(app.name) đang được xcode-select dùng: chạy \"sudo xcode-select --reset\" trong Terminal để git, clang, swift chạy lại."))
            }
        }
        return out
    }

    /// Dừng giữa chừng: mục chưa làm được báo "bỏ qua", mục đã làm vẫn có trong sao lưu.
    func cancelRemoval() {
        guard phase == .removing else { return }
        token?.cancel()
    }

    /// Đóng bảng kết quả. Mục không còn bị bỏ khỏi danh sách; `backToList` (hoặc không còn mục nào): về danh sách app
    /// và liệt kê lại (app vừa gỡ biến mất).
    func closeResults(backToList: Bool) {
        guard case .finished(let run) = phase else { return }
        let gone = run.goneIDs
        let removedApps = Set(items.compactMap { item -> String? in
            guard gone.contains(item.id), case .appBundle(let ref) = item.finding.reason else { return nil }
            return ref.path
        })
        items.removeAll { gone.contains($0.id) }
        selection = []
        resultNotes = []
        appSelection.subtract(removedApps)
        for path in removedApps { sizes[path] = nil }
        missingApps.formUnion(removedApps)
        if backToList || items.isEmpty {
            clearReview()
            phase = .list
        } else {
            rebuildGroups()
            phase = .review
        }
        if !removedApps.isEmpty || phase == .list { loadApps() }
    }

    // MARK: Lệnh quản trị

    func adminCommand(for finding: Finding) async -> String {
        let removal = removal
        return await Task.detached(priority: .userInitiated) { removal.adminCommand(for: finding) }.value
    }

    /// Lệnh dừng dịch vụ (bootout) để người dùng tự chạy.
    static func stopCommand(for service: RunningService) -> String {
        let target = "\(service.domain)/\(service.label)"
        return service.isSystem ? "sudo launchctl bootout \(target)" : "launchctl bootout \(target)"
    }

    #if DEBUG
    /// Trạng thái giả cho chế độ chụp giao diện.
    func setPreview(apps: [InstalledApp], sizes: [String: Int64] = [:], appSelection: Set<String> = [],
                    sortOrder: SortOrder = .name, excluded: Int = 0, phase: Phase = .list,
                    findings: [Finding] = [], reviewApps: [InstalledApp] = [], selection: Set<String> = [],
                    running: [String: AppRunState] = [:], activeDeveloperApps: Set<String> = [],
                    rootOwnedApps: Set<String> = []) {
        listing = AppCatalog.Listing(apps: apps)
        listingDate = Date()
        self.apps = apps.map(UninstallAppRow.init)
        appsLoaded = true
        excludedCount = excluded
        self.sizes = sizes
        self.appSelection = appSelection
        self.sortOrder = sortOrder
        rebuildVisibleApps()
        self.reviewApps = reviewApps
        items = CleanupModel.makeItems(findings)
        self.running = running
        self.activeDeveloperApps = activeDeveloperApps
        self.rootOwnedApps = rootOwnedApps
        rebuildGroups()
        self.selection = selection
        self.phase = phase
    }
    #endif
}

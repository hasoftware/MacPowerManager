import CleanCore
import Foundation
import Observation

// MARK: - Kiểu dữ liệu phía app
// ScanResult, RemovalReport, RestoreReport, BackupInfo của CleanCore không tạo được ngoài module (init nội bộ), nên
// backend chuyển sang các kiểu dưới đây: test dựng được bản giả.

/// Kết quả một lượt quét.
struct CleanupScanOutput: Sendable {
    var findings: [Finding]
    var ignoredCount: Int
    var hasFullDiskAccess: Bool
    /// id bộ quét → lỗi (các bộ quét khác vẫn chạy).
    var scannerErrors: [String: String]
}

/// Tiến độ quét.
struct CleanupScanStatus: Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        /// Đọc môi trường (shell đăng nhập), trước khi dựng chỉ mục.
        case preparing
        case indexing
        /// id bộ quét (vd "AppSupport").
        case scanner(String)
        case finishing
    }

    var stage: Stage
    var done: Int
    var total: Int

    var fraction: Double { total > 0 ? min(Double(done) / Double(total), 1) : 0 }
}

/// Kết quả gỡ một mục.
struct CleanupItemOutcome: Equatable, Sendable, Identifiable {
    var findingID: String
    var category: CleanCategory
    var name: String
    var target: String
    var outcome: RemovalOutcome

    var id: String { findingID }
    /// Đã gỡ (kể cả một phần): bỏ khỏi danh sách sau khi đóng bảng kết quả.
    var removed: Bool { outcome.status == .done || outcome.status == .partial }
}

/// Kết quả một lần gỡ.
struct CleanupRemovalRun: Equatable, Sendable {
    var backupDirectory: URL?
    var items: [CleanupItemOutcome]
    /// Không tạo được phiên sao lưu: không gỡ gì.
    var sessionFailed: Bool
    var cancelled: Bool

    func count(_ status: RemovalOutcome.Status) -> Int { items.filter { $0.outcome.status == status }.count }

    /// Mục không còn trên đĩa: đã gỡ, hoặc nằm trong mục cha đã gỡ (bỏ qua vì "đã nằm trong mục khác").
    var goneIDs: Set<String> {
        let removed = items.filter(\.removed)
        let removedTargets = Set(removed.map { PathResolver.lexical($0.target) })
        var ids = Set(removed.map(\.findingID))
        for item in items {
            if case .skipped(.coveredBy(let parent)) = item.outcome, removedTargets.contains(parent) { ids.insert(item.findingID) }
        }
        return ids
    }
    /// Mục cần chú ý lên trước (lỗi, cần quản trị, một phần, bỏ qua, xong), ổn định trong nhóm.
    var sortedForDisplay: [CleanupItemOutcome] {
        items.enumerated().sorted {
            ($0.element.outcome.displayRank, $0.offset) < ($1.element.outcome.displayRank, $1.offset)
        }.map(\.element)
    }
}

/// Một lần dọn đã sao lưu (thư mục trong dataDir).
struct CleanupSession: Identifiable, Equatable, Sendable {
    var directory: URL
    var name: String
    var date: Date?
    var entryCount: Int
    /// Tổng dung lượng đã chuyển vào Thùng rác (file tóm tắt của app); nil với bản sao lưu cũ.
    var bytes: Int64?
    /// Kết quả khôi phục đã lưu (restored.json): nil khi chưa khôi phục lần nào.
    var restore: CleanupRestoreRun?

    var id: String { name }

    /// Tên thư mục `yyyyMMdd_HHmmss[_n]` → ngày giờ địa phương.
    static func date(fromName name: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.date(from: String(name.prefix(15)))
    }
}

struct CleanupRestoreItem: Equatable, Sendable {
    /// Vị trí entry trong manifest.
    var index: Int
    var entry: ManifestEntry
    var status: RestoreStatus

    /// Không cần làm gì (dựng lại LaunchServices: macOS tự đăng ký lại app). Restorer báo "không khôi phục được".
    static func notNeeded(_ s: RestoreStatus) -> Bool { s == .manual(.notRestorable(kind: CleanKind.lsRebuild.rawValue)) }
}

struct CleanupRestoreRun: Equatable, Sendable {
    var manifestFound: Bool
    /// Theo thứ tự manifest.
    var items: [CleanupRestoreItem]
    /// Lúc khôi phục (lưu cùng kết quả trong thư mục sao lưu).
    var date: Date?

    var restoredCount: Int { items.filter { $0.status == .restored }.count }
    var failedCount: Int { items.filter { if case .failed = $0.status { true } else { false } }.count }
    var manualCount: Int {
        items.filter { if case .manual = $0.status { !CleanupRestoreItem.notNeeded($0.status) } else { false } }.count
    }
    /// Entry là file cấu hình bị sửa sau lần dọn: hỏi người dùng có ghi đè không.
    var modifiedIndices: Set<Int> { Set(items.filter { $0.status == .manual(.modifiedSinceCleanup) }.map(\.index)) }
    var hasModifiedFiles: Bool { !modifiedIndices.isEmpty }

    func item(at index: Int) -> CleanupRestoreItem? { items.first { $0.index == index } }

    /// Gộp kết quả chạy lại một phần (vd chỉ ghi đè file đã sửa): entry có trong `partial` lấy kết quả mới.
    func merging(_ partial: CleanupRestoreRun) -> CleanupRestoreRun {
        var byIndex = Dictionary(items.map { ($0.index, $0) }, uniquingKeysWith: { a, _ in a })
        for item in partial.items { byIndex[item.index] = item }
        return CleanupRestoreRun(manifestFound: manifestFound && partial.manifestFound,
                                 items: byIndex.values.sorted { $0.index < $1.index }, date: partial.date ?? date)
    }
}

/// Tiến độ gỡ (tách khỏi `phase` để mỗi bước không vẽ lại cả danh sách).
struct CleanupProgress: Equatable, Sendable {
    var done: Int
    var total: Int
}

/// Mọi việc chạm đĩa của trang Dọn dẹp. Đồng bộ, gọi NGOÀI main actor. Test tiêm bản giả.
protocol CleanupBackend: Sendable {
    func hasFullDiskAccess() -> Bool
    /// Ném `CancellationError` khi bị hủy.
    func scan(cancellation: CancellationToken,
              progress: @escaping @Sendable (CleanupScanStatus) -> Void) throws -> CleanupScanOutput
    /// `progress(đã xong, tổng)`.
    func remove(_ findings: [Finding], cancellation: CancellationToken,
                progress: @escaping @Sendable (Int, Int) -> Void) -> CleanupRemovalRun
    func adminCommand(for finding: Finding) -> String
    func ignore(_ ids: [String]) throws
    func unignore(_ ids: Set<String>) throws
    /// File danh sách bỏ qua (để mở trong Finder).
    func ignoreFileURL() -> URL
    /// Mới nhất trước.
    func sessions() -> [CleanupSession]
    func entries(of session: URL) -> [ManifestEntry]?
    /// `onlyEntries`: chỉ các entry ở các vị trí này (nil = tất cả); kết quả chỉ có các entry đó.
    func restore(_ session: URL, overwriteModifiedFiles: Bool, onlyEntries: Set<Int>?) -> CleanupRestoreRun
    /// Lưu kết quả khôi phục vào thư mục sao lưu (đọc lại ở `sessions()`).
    func saveRestore(_ run: CleanupRestoreRun, in session: URL)
}

// MARK: - Dòng hiển thị

/// Một finding kèm chữ đã dịch sẵn (tính một lần, ngoài main actor, không tính trong body).
struct CleanupItem: Identifiable, Equatable, Sendable {
    /// `Finding.id` tính sẵn (vốn là chuỗi ghép mỗi lần đọc).
    let id: String
    let finding: Finding
    /// Thứ tự trong kết quả quét (để hoàn tác bỏ qua trả về đúng chỗ).
    let order: Int
    let displayName: String
    let displayTarget: String
    let reasonText: String
    let sizeText: String?
    let selectable: Bool
    /// Chữ thường của tên, đường dẫn, lý do để tìm kiếm.
    let searchKey: String

    init(finding: Finding, order: Int) {
        id = finding.id
        self.finding = finding
        self.order = order
        displayName = CleanupText.displayName(finding)
        displayTarget = CleanupText.displayTarget(finding)
        reasonText = CleanupText.reason(finding.reason)
        sizeText = finding.sizeBytes > 0 ? Format.bytes(UInt64(finding.sizeBytes)) : nil
        selectable = CleanupModel.isSelectable(finding)
        searchKey = [displayName, finding.name, finding.target, reasonText].joined(separator: "\n").lowercased()
    }
}

struct CleanupSection: Identifiable, Equatable {
    let category: CleanCategory
    let items: [CleanupItem]
    let selectableIDs: [String]
    var id: CleanCategory { category }

    init(category: CleanCategory, items: [CleanupItem]) {
        self.category = category
        self.items = items
        selectableIDs = items.filter(\.selectable).map(\.id)
    }
}

/// Một dòng của danh sách phẳng (tiêu đề nhóm hoặc mục): một ForEach duy nhất, ID ổn định.
enum CleanupRow: Identifiable, Equatable {
    case header(CleanupSection)
    case item(CleanupItem)

    var id: String {
        switch self {
        // ID mục luôn có "|", tiêu đề thì không: không trùng
        case .header(let s): "#" + s.category.rawValue
        case .item(let i): i.id
        }
    }
}

// MARK: - Model

/// Trang Quét tàn dư và Lịch sử dọn. Chỉ quét khi người dùng bấm, không chọn sẵn gì, mọi việc nặng chạy ngoài main
/// actor và hủy được. Không timer, không quét nền.
@MainActor
@Observable
final class CleanupModel {
    enum Phase: Equatable {
        case idle
        case scanning(CleanupScanStatus)
        case results
        /// Tiến độ ở `removalProgress`.
        case removing
        case finished(CleanupRemovalRun)
    }

    enum SeverityFilter: CaseIterable, Identifiable {
        case all, high, medium, info
        var id: Self { self }

        func matches(_ s: Severity) -> Bool {
            switch self {
            case .all: true
            case .high: s == .high
            case .medium: s == .medium
            case .info: s == .info
            }
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var removalProgress = CleanupProgress(done: 0, total: 0)
    /// Mọi mục của lần quét gần nhất (trừ mục vừa bỏ qua), theo thứ tự báo cáo.
    private(set) var items: [CleanupItem] = []
    /// Các nhóm sau khi lọc.
    private(set) var sections: [CleanupSection] = []
    /// `sections` trải phẳng cho List.
    private(set) var rows: [CleanupRow] = []
    private(set) var visibleCount = 0
    /// ID chọn được trong bộ lọc hiện tại.
    private(set) var visibleSelectableIDs: [String] = []
    // quan sát được: thanh dưới báo mục chọn bị ẩn khi đổi bộ lọc
    private var visibleIDs: Set<String> = []
    private(set) var selection: Set<String> = []
    private(set) var severityCounts: [Severity: Int] = [:]
    /// Tổng dung lượng các mục chọn được.
    private(set) var reclaimableBytes: Int64 = 0
    /// Nhóm có trong kết quả (để lọc), theo thứ tự hiển thị.
    private(set) var categories: [(category: CleanCategory, count: Int)] = []
    private(set) var hiddenByIgnoreList = 0
    private(set) var scannerErrors: [String: String] = [:]
    private(set) var lastScanDate: Date?
    private(set) var hasFullDiskAccess: Bool?
    /// Mục đã bỏ qua vĩnh viễn từ lúc mở app (hoàn tác được, kể cả sau khi quét lại), mới nhất cuối.
    private(set) var ignoredThisSession: [CleanupItem] = []
    /// Mục bỏ qua trước lần quét gần nhất: đã nằm trong `hiddenByIgnoreList`.
    @ObservationIgnored private var ignoredBeforeLastScan: Set<String> = []
    /// Lỗi gần nhất (đã dịch) để hiện dưới dạng thông báo.
    var errorMessage: String?

    var severityFilter: SeverityFilter = .all { didSet { if severityFilter != oldValue { rebuildSections() } } }
    var categoryFilter: CleanCategory? { didSet { if categoryFilter != oldValue { rebuildSections() } } }
    var searchText = "" { didSet { if searchText != oldValue { rebuildSections() } } }

    // Lịch sử dọn
    private(set) var sessions: [CleanupSession] = []
    private(set) var historyLoaded = false
    private(set) var sessionEntries: [URL: [ManifestEntry]] = [:]
    private(set) var restoreRuns: [URL: CleanupRestoreRun] = [:]
    private(set) var restoringSession: URL?
    @ObservationIgnored private var loadingEntries: Set<URL> = []

    @ObservationIgnored private let backend: CleanupBackend
    @ObservationIgnored private var token: CancellationToken?
    /// Tăng mỗi lần bắt đầu/hủy quét: kết quả hay tiến độ đến muộn của lượt cũ bị bỏ.
    @ObservationIgnored private var generation = 0
    /// Việc nền gần nhất (test `await` để chờ).
    @ObservationIgnored private(set) var task: Task<Void, Never>?
    /// Ghi danh sách bỏ qua nối tiếp nhau (bỏ qua rồi hoàn tác nhanh không bị đảo thứ tự).
    @ObservationIgnored private(set) var writeTask: Task<Void, Never>?
    @ObservationIgnored private(set) var historyTask: Task<Void, Never>?

    init(backend: CleanupBackend) {
        self.backend = backend
    }

    // MARK: Quy tắc chọn

    /// Kiểu gỡ chạy được ở P0 bằng quyền người dùng (và hoàn tác được qua manifest hoặc vô hại).
    nonisolated static let executableKinds: Set<CleanKind> = [.trashPath, .symlink, .pathEntry, .envLine, .launchdJob,
                                                  .tccReset, .lsRebuild]

    /// Chỉ báo và cần quyền quản trị không bao giờ chọn được.
    nonisolated static func isSelectable(_ f: Finding) -> Bool {
        !f.needsAdmin && executableKinds.contains(f.kind)
    }

    /// Đang quét hoặc gỡ.
    var isBusy: Bool {
        switch phase {
        case .scanning, .removing: true
        default: false
        }
    }

    /// Quét, gỡ và khôi phục loại trừ nhau: cùng đọc/sửa một file (vd ~/.zshrc) hoặc khôi phục phiên đang ghi dở.
    var isRestoring: Bool { restoringSession != nil }

    var hasResults: Bool { lastScanDate != nil }

    func isSelected(_ id: String) -> Bool { selection.contains(id) }

    func setSelected(_ id: String, _ on: Bool) {
        guard phase == .results else { return }
        if on {
            guard let item = item(id), item.selectable else { return }
            selection.insert(id)
        } else {
            selection.remove(id)
        }
    }

    func toggle(_ id: String) { setSelected(id, !isSelected(id)) }

    var allVisibleSelected: Bool {
        let ids = visibleSelectableIDs
        return !ids.isEmpty && ids.allSatisfy(selection.contains)
    }

    /// Mục đã chọn nhưng bị bộ lọc/tìm kiếm ẩn.
    var hiddenSelectionCount: Int { selection.subtracting(visibleIDs).count }

    /// Bỏ mọi bộ lọc và tìm kiếm.
    func clearFilters() {
        severityFilter = .all
        categoryFilter = nil
        searchText = ""
    }

    /// Bỏ chọn các mục đang bị bộ lọc ẩn.
    func deselectHidden() {
        selection.formIntersection(visibleIDs)
    }

    /// Chọn tất cả chỉ trong bộ lọc đang áp dụng.
    func selectAllVisible() {
        guard phase == .results else { return }
        selection.formUnion(visibleSelectableIDs)
    }

    func deselectAllVisible() {
        selection.subtract(visibleSelectableIDs)
    }

    func setSection(_ section: CleanupSection, selected: Bool) {
        guard phase == .results else { return }
        if selected { selection.formUnion(section.selectableIDs) } else { selection.subtract(section.selectableIDs) }
    }

    func clearSelection() { selection = [] }

    /// Mục đã chọn theo thứ tự báo cáo (thứ tự gỡ).
    var selectedItems: [CleanupItem] { items.filter { selection.contains($0.id) && $0.selectable } }

    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.finding.sizeBytes } }

    private func item(_ id: String) -> CleanupItem? { items.first { $0.id == id } }

    // MARK: Lọc

    nonisolated static func filter(_ items: [CleanupItem], severity: SeverityFilter, category: CleanCategory?,
                                   search: String) -> [CleanupItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return items.filter { item in
            severity.matches(item.finding.severity)
                && (category == nil || item.finding.category == category)
                && (query.isEmpty || item.searchKey.contains(query))
        }
    }

    /// Nhóm theo category: nhóm có mục mức cao hơn lên trước, rồi theo thứ tự khai báo.
    nonisolated static func group(_ items: [CleanupItem]) -> [CleanupSection] {
        var buckets: [CleanCategory: [CleanupItem]] = [:]
        for item in items { buckets[item.finding.category, default: []].append(item) }
        let order = Dictionary(uniqueKeysWithValues: CleanCategory.allCases.enumerated().map { ($1, $0) })
        return buckets.map { CleanupSection(category: $0.key, items: $0.value) }.sorted { a, b in
            let ra = a.items.map(\.finding.severity.rank).min() ?? 9
            let rb = b.items.map(\.finding.severity.rank).min() ?? 9
            if ra != rb { return ra < rb }
            return (order[a.category] ?? 0) < (order[b.category] ?? 0)
        }
    }

    private func rebuildSections() {
        let visible = Self.filter(items, severity: severityFilter, category: categoryFilter, search: searchText)
        visibleCount = visible.count
        visibleIDs = Set(visible.map(\.id))
        let grouped = Self.group(visible)
        sections = grouped
        rows = grouped.flatMap { [CleanupRow.header($0)] + $0.items.map(CleanupRow.item) }
        visibleSelectableIDs = grouped.flatMap(\.selectableIDs)
    }

    private func rebuildSummary() {
        var counts: [Severity: Int] = [:]
        var bytes: Int64 = 0
        var cats: [CleanCategory: Int] = [:]
        for item in items {
            counts[item.finding.severity, default: 0] += 1
            cats[item.finding.category, default: 0] += 1
            if item.selectable { bytes += item.finding.sizeBytes }
        }
        severityCounts = counts
        reclaimableBytes = bytes
        categories = Self.group(items).map { ($0.category, cats[$0.category] ?? 0) }
        if let c = categoryFilter, cats[c] == nil { categoryFilter = nil }
        // bỏ chọn mục không còn
        let ids = Set(items.map(\.id))
        selection.formIntersection(ids)
        rebuildSections()
    }

    /// Dựng dòng hiển thị (dịch, định dạng dung lượng, khóa tìm kiếm): gọi ngoài main actor.
    nonisolated static func makeItems(_ findings: [Finding]) -> [CleanupItem] {
        var seen = Set<String>()
        // ID trùng (hiếm): giữ mục đầu, ForEach cần ID duy nhất.
        return findings.enumerated().compactMap { i, f in
            let item = CleanupItem(finding: f, order: i)
            return seen.insert(item.id).inserted ? item : nil
        }
    }

    private func setItems(_ newItems: [CleanupItem]) {
        items = newItems
        rebuildSummary()
    }

    // MARK: Full Disk Access

    func refreshAccess() {
        let backend = backend
        Task {
            let granted = await Task.detached(priority: .utility) { backend.hasFullDiskAccess() }.value
            self.hasFullDiskAccess = granted
        }
    }

    // MARK: Quét

    func startScan() {
        guard !isBusy, !isRestoring else { return }
        generation += 1
        let gen = generation
        let token = CancellationToken()
        self.token = token
        errorMessage = nil
        phase = .scanning(CleanupScanStatus(stage: .preparing, done: 0, total: 0))
        let backend = backend
        task = Task {
            let result = await Task.detached(priority: .utility) { () -> Result<(CleanupScanOutput, [CleanupItem]), Error> in
                Result {
                    let output = try backend.scan(cancellation: token) { status in
                        Task { @MainActor [weak self] in self?.applyScanProgress(status, generation: gen) }
                    }
                    return (output, CleanupModel.makeItems(output.findings))
                }
            }.value
            self.finishScan(result, generation: gen)
        }
    }

    private func applyScanProgress(_ status: CleanupScanStatus, generation gen: Int) {
        guard gen == generation, case .scanning = phase else { return }
        phase = .scanning(status)
    }

    private func finishScan(_ result: Result<(CleanupScanOutput, [CleanupItem]), Error>, generation gen: Int) {
        guard gen == generation else { return }
        token = nil
        switch result {
        case .success(let (output, newItems)):
            // Kết quả mới: không giữ lựa chọn cũ, không chọn sẵn gì. Mục đã bỏ qua vẫn hoàn tác được.
            selection = []
            ignoredBeforeLastScan = Set(ignoredThisSession.map(\.id))
            hiddenByIgnoreList = output.ignoredCount
            scannerErrors = output.scannerErrors
            hasFullDiskAccess = output.hasFullDiskAccess
            lastScanDate = Date()
            setItems(newItems)
            phase = .results
        case .failure(let error):
            if !(error is CancellationError) { errorMessage = String(localized: "Không quét được: \(String(describing: error))") }
            phase = hasResults ? .results : .idle
        }
    }

    /// Dừng quét: trở lại ngay trạng thái trước đó, kết quả đến muộn bị bỏ.
    func cancelScan() {
        guard case .scanning = phase else { return }
        token?.cancel()
        token = nil
        generation += 1
        phase = hasResults ? .results : .idle
    }

    // MARK: Gỡ

    func removeSelected() {
        guard phase == .results, !isRestoring else { return }
        let chosen = selectedItems.map(\.finding).filter(Self.isSelectable)
        guard !chosen.isEmpty else { return }
        let token = CancellationToken()
        self.token = token
        removalProgress = CleanupProgress(done: 0, total: chosen.count)
        phase = .removing
        let backend = backend
        task = Task {
            let run = await Task.detached(priority: .userInitiated) {
                backend.remove(chosen, cancellation: token) { done, total in
                    Task { @MainActor [weak self] in self?.applyRemovalProgress(done, total) }
                }
            }.value
            self.finishRemoval(run)
        }
    }

    private func applyRemovalProgress(_ done: Int, _ total: Int) {
        guard phase == .removing, done > removalProgress.done else { return }
        removalProgress = CleanupProgress(done: done, total: total)
    }

    private func finishRemoval(_ run: CleanupRemovalRun) {
        token = nil
        phase = .finished(run)
        // Lịch sử có thể đã đọc manifest đang ghi dở của phiên này: đọc lại.
        if let dir = run.backupDirectory { sessionEntries[dir] = nil }
        if historyLoaded { loadHistory() }
    }

    /// Dừng giữa chừng: mục chưa làm được báo "bỏ qua", mục đã làm vẫn có trong sao lưu.
    func cancelRemoval() {
        guard case .removing = phase else { return }
        token?.cancel()
    }

    /// Đóng bảng kết quả: bỏ các mục không còn khỏi danh sách, bỏ chọn tất cả (mục còn lại, kể cả mục bị dừng,
    /// phải chọn lại), quét lại nếu người dùng chọn.
    func closeRemovalResults(rescan: Bool) {
        guard case .finished(let run) = phase else { return }
        let gone = run.goneIDs
        items.removeAll { gone.contains($0.id) }
        selection = []
        rebuildSummary()
        phase = .results
        if rescan { startScan() }
    }

    // MARK: Bỏ qua vĩnh viễn

    func ignore(_ id: String) {
        guard phase == .results, let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: index)
        selection.remove(id)
        ignoredThisSession.append(item)
        rebuildSummary()
        persist { try $0.ignore([id]) }
    }

    /// Hoàn tác bỏ qua (mặc định mục gần nhất): trả về đúng vị trí cũ và xóa khỏi danh sách bỏ qua.
    func undoIgnore(_ id: String? = nil) {
        guard phase == .results else { return }
        let found: Int? = if let id { ignoredThisSession.lastIndex { $0.id == id } } else { ignoredThisSession.indices.last }
        guard let index = found else { return }
        let item = ignoredThisSession.remove(at: index)
        if ignoredBeforeLastScan.remove(item.id) != nil { hiddenByIgnoreList = max(hiddenByIgnoreList - 1, 0) }
        if !items.contains(where: { $0.id == item.id }) {
            let at = items.firstIndex { $0.order > item.order } ?? items.endIndex
            items.insert(item, at: at)
        }
        rebuildSummary()
        persist { try $0.unignore([item.id]) }
    }

    /// Mở ignore.txt trong Finder (hiện lại mục đã bỏ qua từ trước bằng cách xóa dòng).
    func ignoreFileURL() async -> URL {
        let backend = backend
        return await Task.detached(priority: .userInitiated) { backend.ignoreFileURL() }.value
    }

    private func persist(_ write: @escaping @Sendable (CleanupBackend) throws -> Void) {
        let backend = backend
        let previous = writeTask
        writeTask = Task {
            await previous?.value
            let result = await Task.detached(priority: .utility) { Result { try write(backend) } }.value
            if case .failure(let error) = result {
                self.errorMessage = String(localized: "Không ghi được danh sách bỏ qua: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Lệnh quản trị

    /// Lệnh tương đương để người dùng tự chạy bằng quyền quản trị (tính ngoài main actor).
    func adminCommand(for finding: Finding) async -> String {
        let backend = backend
        return await Task.detached(priority: .userInitiated) { backend.adminCommand(for: finding) }.value
    }

    // MARK: Lịch sử dọn

    func loadHistory() {
        let backend = backend
        let previous = historyTask
        historyTask = Task {
            await previous?.value
            let list = await Task.detached(priority: .utility) { backend.sessions() }.value
            self.applySessions(list)
        }
    }

    private func applySessions(_ list: [CleanupSession]) {
        sessions = list
        historyLoaded = true
        let counts = Dictionary(list.map { ($0.directory, $0.entryCount) }, uniquingKeysWith: { a, _ in a })
        // Phiên đã mất (người dùng xóa thư mục) hoặc manifest đổi số mục (đã đọc lúc đang dọn dở): bỏ dữ liệu đệm.
        let stale = sessionEntries.filter { counts[$0.key] != $0.value.count }.map(\.key)
        for dir in stale { sessionEntries[dir] = nil }
        restoreRuns = restoreRuns.filter { counts[$0.key] != nil }
        for session in list where restoreRuns[session.directory] == nil {
            if let run = session.restore { restoreRuns[session.directory] = run }
        }
        // đọc lại phiên đang đệm (thường là phiên đang xem)
        for session in list where stale.contains(session.directory) { loadEntries(for: session) }
    }

    func loadEntries(for session: CleanupSession) {
        let dir = session.directory
        guard sessionEntries[dir] == nil, !loadingEntries.contains(dir) else { return }
        loadingEntries.insert(dir)
        let backend = backend
        let previous = historyTask
        // nối sau việc đọc lịch sử trước đó: kết quả cũ không ghi đè kết quả mới
        historyTask = Task {
            await previous?.value
            let entries = await Task.detached(priority: .utility) { backend.entries(of: dir) }.value
            self.loadingEntries.remove(dir)
            self.sessionEntries[dir] = entries ?? []
        }
    }

    /// Đã khôi phục (kết quả lưu trong thư mục sao lưu): không chạy lại, chỉ còn ghi đè file đã sửa.
    func isRestored(_ session: CleanupSession) -> Bool { restoreRuns[session.directory]?.date != nil }

    /// Không khôi phục khi đang quét, đang gỡ (phiên đang ghi dở) hay đang khôi phục phiên khác.
    var canStartRestore: Bool { !isBusy && !isRestoring }

    func canRestore(_ session: CleanupSession) -> Bool {
        canStartRestore && session.entryCount > 0 && !isRestored(session)
    }

    func restore(_ session: CleanupSession) {
        guard canRestore(session) else { return }
        runRestore(session.directory, overwrite: false, only: nil)
    }

    /// Chỉ ghi đè các file cấu hình bị sửa sau lần dọn; mục đã khôi phục không bị chạy lại.
    func overwriteModifiedFiles(_ session: CleanupSession) {
        guard canStartRestore, let run = restoreRuns[session.directory], run.hasModifiedFiles else { return }
        runRestore(session.directory, overwrite: true, only: run.modifiedIndices)
    }

    private func runRestore(_ dir: URL, overwrite: Bool, only: Set<Int>?) {
        let backend = backend
        let previous = only == nil ? nil : restoreRuns[dir]
        restoringSession = dir
        task = Task {
            let run = await Task.detached(priority: .userInitiated) { () -> CleanupRestoreRun in
                var run = backend.restore(dir, overwriteModifiedFiles: overwrite, onlyEntries: only)
                run.date = Date()
                if let previous { run = previous.merging(run) }
                if run.manifestFound { backend.saveRestore(run, in: dir) }
                return run
            }.value
            self.restoreRuns[dir] = run
            self.restoringSession = nil
        }
    }

    #if DEBUG
    /// Trạng thái giả cho chế độ chụp giao diện.
    func setPreview(phase: Phase, findings: [Finding], selection: Set<String> = [], hasFullDiskAccess: Bool?,
                    hiddenByIgnoreList: Int = 0, progress: CleanupProgress? = nil, sessions: [CleanupSession] = [],
                    entries: [URL: [ManifestEntry]] = [:], restoreRuns: [URL: CleanupRestoreRun] = [:],
                    filter: SeverityFilter = .all) {
        setItems(Self.makeItems(findings))
        severityFilter = filter
        if let progress { removalProgress = progress }
        if !findings.isEmpty { lastScanDate = Date() }
        self.selection = selection
        self.phase = phase
        self.hasFullDiskAccess = hasFullDiskAccess
        self.hiddenByIgnoreList = hiddenByIgnoreList
        self.sessions = sessions
        historyLoaded = true
        sessionEntries = entries
        self.restoreRuns = restoreRuns
    }

    func setPreviewIgnored(_ findings: [Finding]) {
        ignoredThisSession = findings.enumerated().map { CleanupItem(finding: $1, order: 10_000 + $0) }
    }
    #endif
}

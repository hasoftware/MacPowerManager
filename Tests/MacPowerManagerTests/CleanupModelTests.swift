import CleanCore
import Foundation
import XCTest
@testable import MacPowerManager

/// Backend giả: ghi lại mọi lời gọi, trả kết quả cấu hình sẵn.
final class FakeCleanupBackend: CleanupBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _findings: [Finding] = []
    private var _ignored: [String] = []
    private var _removeCalls: [[Finding]] = []
    private var _restoreCalls: [(URL, Bool)] = []
    private var _scanCount = 0
    private var _scanStarted = false
    private var _removeStarted = false
    private var _restoreBlocked = false
    private var _restoreStarted = false
    private var _savedRestores: [URL: CleanupRestoreRun] = [:]
    private var _restoreOnly: [Set<Int>?] = []
    var fullDiskAccess = false
    /// Quét/gỡ chờ tới khi bị hủy (test hủy).
    var blockUntilCancelled = false
    /// Gỡ: số mục báo tiến độ rồi chờ `releaseRemoval` (test chạy song song).
    var removalGate: Int?
    private var _removalReleased = false
    var outcomes: [String: RemovalOutcome] = [:]
    var sessionList: [CleanupSession] = []
    var entryMap: [URL: [ManifestEntry]] = [:]
    var restoreResult = CleanupRestoreRun(manifestFound: true, items: [])

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    var findings: [Finding] {
        get { locked { _findings } }
        set { locked { _findings = newValue } }
    }
    var ignored: [String] { locked { _ignored } }
    var removeCalls: [[Finding]] { locked { _removeCalls } }
    var restoreCalls: [(URL, Bool)] { locked { _restoreCalls } }
    var scanCount: Int { locked { _scanCount } }
    var scanStarted: Bool { locked { _scanStarted } }
    var removeStarted: Bool { locked { _removeStarted } }
    var restoreStarted: Bool { locked { _restoreStarted } }
    var savedRestores: [URL: CleanupRestoreRun] { locked { _savedRestores } }
    var restoreOnly: [Set<Int>?] { locked { _restoreOnly } }
    /// Khôi phục chờ tới khi `releaseRestore()`.
    func blockRestore() { locked { _restoreBlocked = true } }
    func releaseRestore() { locked { _restoreBlocked = false } }
    func releaseRemoval() { locked { _removalReleased = true } }

    func hasFullDiskAccess() -> Bool { fullDiskAccess }

    func scan(cancellation: CancellationToken,
              progress: @escaping @Sendable (CleanupScanStatus) -> Void) throws -> CleanupScanOutput {
        locked { _scanCount += 1; _scanStarted = true }
        progress(CleanupScanStatus(stage: .indexing, done: 0, total: 2))
        if blockUntilCancelled {
            while !cancellation.isCancelled { usleep(1_000) }
        }
        if cancellation.isCancelled { throw CancellationError() }
        progress(CleanupScanStatus(stage: .scanner("Caches"), done: 1, total: 2))
        let ignored = Set(self.ignored)
        let all = findings
        let kept = all.filter { !ignored.contains($0.id) }
        return CleanupScanOutput(findings: kept, ignoredCount: all.count - kept.count,
                                 hasFullDiskAccess: fullDiskAccess, scannerErrors: [:])
    }

    func remove(_ findings: [Finding], cancellation: CancellationToken,
                progress: @escaping @Sendable (Int, Int) -> Void) -> CleanupRemovalRun {
        locked { _removeCalls.append(findings); _removeStarted = true }
        if blockUntilCancelled {
            while !cancellation.isCancelled { usleep(1_000) }
        }
        var items: [CleanupItemOutcome] = []
        for (i, f) in findings.enumerated() {
            if i == removalGate { while !locked({ _removalReleased }) { usleep(1_000) } }
            let outcome: RemovalOutcome = cancellation.isCancelled ? .skipped(.cancelled) : (outcomes[f.id] ?? .done)
            items.append(CleanupItemOutcome(findingID: f.id, category: f.category, name: f.name, target: f.target,
                                            outcome: outcome))
            progress(i + 1, findings.count)
        }
        return CleanupRemovalRun(backupDirectory: URL(fileURLWithPath: "/tmp/backup"), items: items,
                                 sessionFailed: false, cancelled: cancellation.isCancelled)
    }

    func adminCommand(for finding: Finding) -> String { "sudo rm \(finding.target)" }

    func ignore(_ ids: [String]) throws {
        locked { for id in ids where !_ignored.contains(id) { _ignored.append(id) } }
    }

    func unignore(_ ids: Set<String>) throws {
        locked { _ignored.removeAll { ids.contains($0) } }
    }

    func ignoreFileURL() -> URL { URL(fileURLWithPath: "/tmp/ignore.txt") }

    func sessions() -> [CleanupSession] { sessionList }
    func entries(of session: URL) -> [ManifestEntry]? { entryMap[session] }

    func restore(_ session: URL, overwriteModifiedFiles: Bool, onlyEntries: Set<Int>?) -> CleanupRestoreRun {
        locked { _restoreCalls.append((session, overwriteModifiedFiles)); _restoreOnly.append(onlyEntries); _restoreStarted = true }
        while locked({ _restoreBlocked }) { usleep(1_000) }
        var run = restoreResult
        if let onlyEntries { run.items = run.items.filter { onlyEntries.contains($0.index) } }
        return run
    }

    func saveRestore(_ run: CleanupRestoreRun, in session: URL) {
        locked { _savedRestores[session] = run }
    }
}

@MainActor
final class CleanupModelTests: XCTestCase {
    private var backend: FakeCleanupBackend!
    private var model: CleanupModel!

    // High: trash (chọn được), helper cần quản trị; Medium: trash, chỉ báo; Info: trash, tcc.
    private let highTrash = Finding(category: .appSupport, severity: .high, name: "com.old.app", target: "/Users/t/Library/Application Support/com.old.app",
                                    reason: .orphanBundleID("com.old.app"), sizeBytes: 100, action: .trashPath(path: "/Users/t/Library/Application Support/com.old.app"))
    private let highAdmin = Finding(category: .helper, severity: .high, name: "com.old.helper", target: "/Library/PrivilegedHelperTools/com.old.helper",
                                    reason: .helperOrphan, sizeBytes: 5, action: .trashPath(path: "/Library/PrivilegedHelperTools/com.old.helper"),
                                    needsAdmin: true)
    private let mediumTrash = Finding(category: .caches, severity: .medium, name: "Sketch", target: "/Users/t/Library/Caches/Sketch",
                                      reason: .orphanName("Sketch", days: 200), sizeBytes: 2_000, action: .trashPath(path: "/Users/t/Library/Caches/Sketch"))
    private let mediumReport = Finding(category: .security, severity: .medium, name: "sudoers.d/x", target: "/etc/sudoers.d/x",
                                       reason: .thirdPartySudoers(file: "x"), action: .reportOnly)
    private let infoTrash = Finding(category: .caches, severity: .info, name: "Figma", target: "/Users/t/Library/Caches/Figma",
                                    reason: .orphanName("Figma", days: 3), sizeBytes: 30, action: .trashPath(path: "/Users/t/Library/Caches/Figma"))
    private let infoTCC = Finding(category: .tcc, severity: .info, name: "us.zoom.xos", target: "Camera",
                                  reason: .tccOrphan(service: "Camera"), action: .tccReset(service: "Camera", client: "us.zoom.xos"))

    private var all: [Finding] { [highTrash, highAdmin, mediumTrash, mediumReport, infoTrash, infoTCC] }

    override func setUp() async throws {
        backend = FakeCleanupBackend()
        backend.findings = all
        model = CleanupModel(backend: backend)
    }

    private func scan() async {
        model.startScan()
        await model.task?.value
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("hết thời gian chờ", file: file, line: line)
    }

    // MARK: Quét

    func testStartsIdleAndNothingPreselectedAfterScan() async {
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(backend.scanCount, 0, "không quét khi chưa bấm")
        await scan()
        XCTAssertEqual(model.phase, .results)
        XCTAssertEqual(model.items.map(\.id), all.map(\.id))
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertEqual(model.severityCounts[.high], 2)
        XCTAssertEqual(model.reclaimableBytes, 100 + 2_000 + 30, "chỉ tính mục chọn được")
        XCTAssertEqual(model.hasFullDiskAccess, false)
    }

    func testRescanClearsSelection() async {
        await scan()
        model.setSelected(highTrash.id, true)
        XCTAssertFalse(model.selection.isEmpty)
        await scan()
        XCTAssertTrue(model.selection.isEmpty)
    }

    func testCancelScanReturnsImmediatelyAndDropsLateResult() async throws {
        backend.blockUntilCancelled = true
        model.startScan()
        try await waitUntil { backend.scanStarted }
        guard case .scanning = model.phase else { return XCTFail("phải đang quét") }
        model.cancelScan()
        XCTAssertEqual(model.phase, .idle)
        await model.task?.value
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.items.isEmpty)
    }

    func testCancelRescanKeepsPreviousResults() async throws {
        await scan()
        backend.blockUntilCancelled = true
        model.startScan()
        try await waitUntil { backend.scanCount == 2 }
        model.cancelScan()
        XCTAssertEqual(model.phase, .results)
        await model.task?.value
        XCTAssertEqual(model.items.count, all.count)
    }

    // MARK: Chọn

    func testReportOnlyAndNeedsAdminNeverSelectable() async {
        await scan()
        model.setSelected(mediumReport.id, true)
        model.setSelected(highAdmin.id, true)
        model.toggle(mediumReport.id)
        XCTAssertTrue(model.selection.isEmpty)
        model.selectAllVisible()
        XCTAssertEqual(model.selection, [highTrash.id, mediumTrash.id, infoTrash.id, infoTCC.id])
        XCTAssertFalse(CleanupModel.isSelectable(mediumReport))
        XCTAssertFalse(CleanupModel.isSelectable(highAdmin))
        // kiểu không chạy được ở P0
        var purge = infoTrash
        purge.action = .purgeAny(path: infoTrash.target)
        XCTAssertFalse(CleanupModel.isSelectable(purge))
    }

    func testSelectAllAppliesToCurrentFilterOnly() async {
        await scan()
        model.severityFilter = .high
        XCTAssertEqual(model.visibleCount, 2)
        model.selectAllVisible()
        XCTAssertEqual(model.selection, [highTrash.id])
        XCTAssertTrue(model.allVisibleSelected)

        model.severityFilter = .all
        XCTAssertFalse(model.allVisibleSelected)
        model.categoryFilter = .caches
        model.selectAllVisible()
        XCTAssertEqual(model.selection, [highTrash.id, mediumTrash.id, infoTrash.id])

        model.categoryFilter = nil
        model.searchText = "figma"
        XCTAssertEqual(model.visibleCount, 1)
        model.deselectAllVisible()
        XCTAssertEqual(model.selection, [highTrash.id, mediumTrash.id], "bỏ chọn cũng chỉ trong bộ lọc")
    }

    func testSearchMatchesReasonTextAndGroupsByCategory() async {
        await scan()
        model.searchText = "  CAMERA "
        XCTAssertEqual(model.sections.map(\.category), [.tcc])
        model.searchText = ""
        // nhóm có mục mức cao lên trước
        XCTAssertEqual(model.sections.first?.category, .appSupport)
        XCTAssertEqual(model.sections.flatMap(\.items).count, all.count)
    }

    func testSectionSelection() async {
        await scan()
        let caches = model.sections.first { $0.category == .caches }!
        model.setSection(caches, selected: true)
        XCTAssertEqual(model.selection, [mediumTrash.id, infoTrash.id])
        XCTAssertEqual(model.selectedBytes, 2_030)
        model.setSection(caches, selected: false)
        XCTAssertTrue(model.selection.isEmpty)
    }

    // MARK: Bỏ qua

    func testIgnorePersistsAndUndoRestoresPosition() async {
        await scan()
        model.setSelected(mediumTrash.id, true)
        model.ignore(mediumTrash.id)
        XCTAssertFalse(model.items.contains { $0.id == mediumTrash.id })
        XCTAssertFalse(model.selection.contains(mediumTrash.id))
        XCTAssertEqual(model.ignoredThisSession.map(\.id), [mediumTrash.id])
        await model.writeTask?.value
        XCTAssertEqual(backend.ignored, [mediumTrash.id])

        model.ignore(infoTrash.id)
        model.undoIgnore(mediumTrash.id)
        XCTAssertEqual(model.items.map(\.id), [highTrash.id, highAdmin.id, mediumTrash.id, mediumReport.id, infoTCC.id])
        XCTAssertFalse(model.selection.contains(mediumTrash.id), "hoàn tác không chọn lại")
        model.undoIgnore()
        XCTAssertEqual(model.items.map(\.id), all.map(\.id))
        XCTAssertTrue(model.ignoredThisSession.isEmpty)
        await model.writeTask?.value
        XCTAssertEqual(backend.ignored, [])
    }

    func testIgnoreCanBeUndoneAfterRescan() async {
        await scan()
        model.ignore(infoTrash.id)
        await model.writeTask?.value
        await scan()
        XCTAssertEqual(model.hiddenByIgnoreList, 1)
        XCTAssertEqual(model.ignoredThisSession.map(\.id), [infoTrash.id], "quét lại vẫn hoàn tác được")
        model.undoIgnore()
        XCTAssertTrue(model.items.contains { $0.id == infoTrash.id })
        XCTAssertEqual(model.hiddenByIgnoreList, 0)
        await model.writeTask?.value
        XCTAssertEqual(backend.ignored, [])
        await scan()
        XCTAssertEqual(model.items.filter { $0.id == infoTrash.id }.count, 1)
    }

    func testIgnoredItemStaysHiddenOnRescan() async {
        await scan()
        model.ignore(infoTCC.id)
        await model.writeTask?.value
        await scan()
        XCTAssertFalse(model.items.contains { $0.id == infoTCC.id })
        XCTAssertEqual(model.hiddenByIgnoreList, 1)
    }

    // MARK: Gỡ

    func testRemoveSendsOnlySelectedInReportOrderAndReportsOutcomes() async {
        await scan()
        model.removeSelected()
        XCTAssertEqual(model.phase, .results, "không có gì được chọn thì không làm gì")
        XCTAssertTrue(backend.removeCalls.isEmpty)

        backend.outcomes = [mediumTrash.id: .failed(.manualEditRequired(file: "/Users/t/.zshrc")),
                            infoTCC.id: .partial(.emptiedKeptFolder)]
        model.setSelected(infoTCC.id, true)
        model.setSelected(highTrash.id, true)
        model.setSelected(mediumTrash.id, true)
        model.removeSelected()
        XCTAssertEqual(model.phase, .removing)
        XCTAssertEqual(model.removalProgress.total, 3)
        await model.task?.value

        XCTAssertEqual(backend.removeCalls.first?.map(\.id), [highTrash.id, mediumTrash.id, infoTCC.id])
        guard case .finished(let run) = model.phase else { return XCTFail("phải có kết quả") }
        XCTAssertEqual(run.count(.done), 1)
        XCTAssertEqual(run.count(.failed), 1)
        XCTAssertEqual(run.count(.partial), 1)
        XCTAssertEqual(run.sortedForDisplay.first?.findingID, mediumTrash.id, "lỗi lên đầu")

        model.closeRemovalResults(rescan: false)
        XCTAssertEqual(model.phase, .results)
        XCTAssertEqual(model.items.map(\.id), [highAdmin.id, mediumTrash.id, mediumReport.id, infoTrash.id])
        XCTAssertTrue(model.selection.isEmpty, "mục lỗi không còn được chọn sẵn để bấm dọn lại")
        XCTAssertEqual(backend.scanCount, 1)
    }

    func testRescanAfterRemoval() async {
        await scan()
        model.setSelected(highTrash.id, true)
        model.removeSelected()
        await model.task?.value
        backend.findings = all.filter { $0.id != highTrash.id }
        model.closeRemovalResults(rescan: true)
        guard case .scanning = model.phase else { return XCTFail("phải quét lại") }
        await model.task?.value
        XCTAssertEqual(backend.scanCount, 2)
        XCTAssertEqual(model.phase, .results)
        XCTAssertFalse(model.items.contains { $0.id == highTrash.id })
        XCTAssertTrue(model.selection.isEmpty)
    }

    func testCancelRemovalSkipsRemaining() async throws {
        await scan()
        backend.blockUntilCancelled = true
        model.setSelected(highTrash.id, true)
        model.setSelected(infoTrash.id, true)
        model.removeSelected()
        try await waitUntil { backend.removeStarted }
        model.cancelRemoval()
        await model.task?.value
        guard case .finished(let run) = model.phase else { return XCTFail("phải có kết quả") }
        XCTAssertTrue(run.cancelled)
        XCTAssertEqual(run.count(.skipped), 2)
        model.closeRemovalResults(rescan: false)
        XCTAssertEqual(model.items.count, all.count, "không mục nào bị bỏ khỏi danh sách")
        XCTAssertTrue(model.selection.isEmpty, "bấm Dừng thì không còn mục nào chờ dọn tiếp")
    }

    func testCoveredChildDroppedOnlyWhenParentRemoved() async {
        let child = Finding(category: .caches, severity: .medium, name: "child", target: highTrash.target + "/Cache",
                            reason: .orphanName("child", days: 3), sizeBytes: 1, action: .trashPath(path: highTrash.target + "/Cache"))
        let orphanChild = Finding(category: .caches, severity: .medium, name: "child2", target: mediumTrash.target + "/x",
                                  reason: .orphanName("child2", days: 3), sizeBytes: 1, action: .trashPath(path: mediumTrash.target + "/x"))
        backend.findings = all + [child, orphanChild]
        await scan()
        backend.outcomes = [child.id: .skipped(.coveredBy(target: highTrash.target)),
                            mediumTrash.id: .failed(.trashFailed),
                            orphanChild.id: .skipped(.coveredBy(target: mediumTrash.target))]
        for f in [highTrash, child, mediumTrash, orphanChild] { model.setSelected(f.id, true) }
        model.removeSelected()
        await model.task?.value
        model.closeRemovalResults(rescan: false)
        let ids = Set(model.items.map(\.id))
        XCTAssertFalse(ids.contains(highTrash.id))
        XCTAssertFalse(ids.contains(child.id), "con đã vào Thùng rác cùng cha")
        XCTAssertTrue(ids.contains(mediumTrash.id))
        XCTAssertTrue(ids.contains(orphanChild.id), "cha lỗi thì con vẫn còn")
    }

    func testRemovalProgressDoesNotChangePhase() async throws {
        await scan()
        backend.removalGate = 1
        model.setSelected(highTrash.id, true)
        model.setSelected(infoTrash.id, true)
        model.removeSelected()
        try await waitUntil { model.removalProgress.done == 1 }
        XCTAssertEqual(model.phase, .removing, "tiến độ không đổi phase (danh sách không vẽ lại mỗi bước)")
        backend.releaseRemoval()
        await model.task?.value
        guard case .finished = model.phase else { return XCTFail("phải xong") }
    }

    func testHiddenSelectionIsReported() async {
        await scan()
        model.setSelected(highTrash.id, true)
        model.setSelected(infoTrash.id, true)
        XCTAssertEqual(model.hiddenSelectionCount, 0)
        model.severityFilter = .info
        XCTAssertEqual(model.hiddenSelectionCount, 1)
        model.searchText = "camera"
        XCTAssertEqual(model.hiddenSelectionCount, 2)
        model.clearFilters()
        XCTAssertEqual(model.hiddenSelectionCount, 0)
        model.searchText = "figma"
        model.deselectHidden()
        XCTAssertEqual(model.selection, [infoTrash.id], "chỉ bỏ chọn mục đang bị ẩn")
    }

    func testSelectionLockedWhileRemoving() async throws {
        await scan()
        backend.blockUntilCancelled = true
        model.setSelected(highTrash.id, true)
        model.removeSelected()
        model.setSelected(infoTrash.id, true)
        model.selectAllVisible()
        model.ignore(infoTrash.id)
        XCTAssertEqual(model.selection, [highTrash.id])
        XCTAssertTrue(model.ignoredThisSession.isEmpty)
        try await waitUntil { backend.removeStarted }
        model.cancelRemoval()
        await model.task?.value
    }

    func testAdminCommandComesFromBackend() async {
        let command = await model.adminCommand(for: highAdmin)
        XCTAssertEqual(command, "sudo rm /Library/PrivilegedHelperTools/com.old.helper")
    }

    // MARK: Lịch sử

    private let historyDir = URL(fileURLWithPath: "/tmp/backups/20261016_101500")
    private let zshrc = ManifestEntry(kind: CleanKind.pathEntry.rawValue, original: "/Users/t/.zshrc", backupRel: "files/001_.zshrc")
    private let trashed = ManifestEntry(kind: CleanKind.trashPath.rawValue, original: "/Users/t/Library/Caches/Docker")

    private func historySession(entries: Int = 2, restore: CleanupRestoreRun? = nil) -> CleanupSession {
        CleanupSession(directory: historyDir, name: "20261016_101500", date: CleanupSession.date(fromName: "20261016_101500"),
                       entryCount: entries, bytes: 10, restore: restore)
    }

    func testHistoryRestoreThenOverwriteOnlyModifiedFiles() async {
        let session = historySession()
        backend.sessionList = [session]
        backend.entryMap = [historyDir: [trashed, zshrc]]
        backend.restoreResult = CleanupRestoreRun(manifestFound: true, items: [
            CleanupRestoreItem(index: 0, entry: trashed, status: .restored),
            CleanupRestoreItem(index: 1, entry: zshrc, status: .manual(.modifiedSinceCleanup)),
        ])

        model.loadHistory()
        await model.historyTask?.value
        XCTAssertTrue(model.historyLoaded)
        XCTAssertEqual(model.sessions, [session])
        model.loadEntries(for: session)
        await model.historyTask?.value
        XCTAssertEqual(model.sessionEntries[historyDir], [trashed, zshrc])

        XCTAssertTrue(model.canRestore(session))
        model.restore(session)
        XCTAssertEqual(model.restoringSession, historyDir)
        await model.task?.value
        XCTAssertNil(model.restoringSession)
        let first = model.restoreRuns[historyDir]
        XCTAssertEqual(first?.hasModifiedFiles, true)
        XCTAssertEqual(first?.manualCount, 1)
        XCTAssertNotNil(first?.date)
        XCTAssertEqual(backend.savedRestores[historyDir], first, "kết quả được lưu cùng bản sao lưu")
        XCTAssertTrue(model.isRestored(session))
        XCTAssertFalse(model.canRestore(session), "đã khôi phục thì không chạy lại")
        model.restore(session)
        await model.task?.value
        XCTAssertEqual(backend.restoreCalls.count, 1)

        // Ghi đè: chỉ chạy lại entry bị sửa; mục Docker đã khôi phục giữ nguyên "Đã khôi phục"
        backend.restoreResult = CleanupRestoreRun(manifestFound: true, items: [
            CleanupRestoreItem(index: 0, entry: trashed, status: .manual(.alreadyExists)),
            CleanupRestoreItem(index: 1, entry: zshrc, status: .restored),
        ])
        model.overwriteModifiedFiles(session)
        await model.task?.value
        XCTAssertEqual(backend.restoreCalls.map(\.1), [false, true])
        XCTAssertEqual(backend.restoreOnly, [nil, [1]])
        let merged = model.restoreRuns[historyDir]
        XCTAssertEqual(merged?.items.map(\.status), [.restored, .restored])
        XCTAssertEqual(merged?.hasModifiedFiles, false)
        XCTAssertEqual(backend.savedRestores[historyDir], merged)
    }

    func testPersistedRestoreLoadsWithHistory() async {
        let saved = CleanupRestoreRun(manifestFound: true, items: [
            CleanupRestoreItem(index: 1, entry: zshrc, status: .manual(.modifiedSinceCleanup)),
        ], date: Date(timeIntervalSince1970: 1_000))
        let session = historySession(restore: saved)
        backend.sessionList = [session]
        model.loadHistory()
        await model.historyTask?.value
        XCTAssertEqual(model.restoreRuns[historyDir], saved)
        XCTAssertTrue(model.isRestored(session))
        XCTAssertFalse(model.canRestore(session), "sau khi mở lại app vẫn biết đã khôi phục")
    }

    func testRestoreAndRemovalAreMutuallyExclusive() async throws {
        let session = historySession()
        backend.sessionList = [session]
        await scan()
        // đang gỡ: không khôi phục (phiên mới nhất có thể đang ghi dở)
        backend.removalGate = 1
        model.setSelected(highTrash.id, true)
        model.setSelected(infoTrash.id, true)
        model.removeSelected()
        try await waitUntil { model.removalProgress.done == 1 }
        XCTAssertFalse(model.canRestore(session))
        model.restore(session)
        XCTAssertNil(model.restoringSession)
        XCTAssertTrue(backend.restoreCalls.isEmpty)
        backend.releaseRemoval()
        await model.task?.value
        model.closeRemovalResults(rescan: false)

        // đang khôi phục: không gỡ, không quét, không khôi phục phiên khác
        backend.blockRestore()
        model.restore(session)
        try await waitUntil { backend.restoreStarted }
        model.setSelected(mediumTrash.id, true)
        model.removeSelected()
        XCTAssertEqual(model.phase, .results)
        XCTAssertEqual(backend.removeCalls.count, 1)
        model.startScan()
        XCTAssertEqual(model.phase, .results)
        XCTAssertEqual(backend.scanCount, 1)
        let other = CleanupSession(directory: URL(fileURLWithPath: "/tmp/backups/x"), name: "x", date: nil, entryCount: 1, bytes: nil)
        XCTAssertFalse(model.canRestore(other))
        backend.releaseRestore()
        await model.task?.value
        XCTAssertNil(model.restoringSession)
        XCTAssertEqual(backend.restoreCalls.count, 1)
    }

    func testHistoryEntriesReloadWhenSessionGrows() async {
        // Mở Lịch sử lúc đang dọn: manifest mới có 1 mục; dọn xong có 2 → phải đọc lại, không giữ bản cắt cụt.
        backend.sessionList = [historySession(entries: 1)]
        backend.entryMap = [historyDir: [trashed]]
        model.loadHistory()
        await model.historyTask?.value
        model.loadEntries(for: model.sessions[0])
        await model.historyTask?.value
        XCTAssertEqual(model.sessionEntries[historyDir]?.count, 1)

        backend.sessionList = [historySession(entries: 2)]
        backend.entryMap = [historyDir: [trashed, zshrc]]
        model.loadHistory()
        await model.historyTask?.value
        await model.historyTask?.value
        XCTAssertEqual(model.sessionEntries[historyDir], [trashed, zshrc])
    }

    func testRestoreRunMergeAndNotNeededStatus() {
        let ls = ManifestEntry(kind: CleanKind.lsRebuild.rawValue, original: "LaunchServices")
        let run = CleanupRestoreRun(manifestFound: true, items: [
            CleanupRestoreItem(index: 0, entry: ls, status: .manual(.notRestorable(kind: CleanKind.lsRebuild.rawValue))),
            CleanupRestoreItem(index: 1, entry: zshrc, status: .manual(.modifiedSinceCleanup)),
        ])
        XCTAssertEqual(run.manualCount, 1, "dựng lại LaunchServices không tính là cần làm tay")
        XCTAssertEqual(CleanupText.restoreTitle(run.items[0].status), String(localized: "Không cần khôi phục"))
        XCTAssertEqual(run.modifiedIndices, [1])
        let merged = run.merging(CleanupRestoreRun(manifestFound: true, items: [
            CleanupRestoreItem(index: 1, entry: zshrc, status: .restored),
        ]))
        XCTAssertEqual(merged.items.map(\.index), [0, 1])
        XCTAssertEqual(merged.items[1].status, .restored)
        XCTAssertEqual(merged.manualCount, 0)
    }

    func testTrashOnlyWording() {
        XCTAssertTrue(CleanupText.isTrashOnly([highTrash, mediumTrash]))
        XCTAssertFalse(CleanupText.isTrashOnly([highTrash, infoTCC]), "thu hồi quyền không phải chuyển vào Thùng rác")
        XCTAssertNotNil(CleanupText.undoNote(infoTCC))
        XCTAssertNil(CleanupText.undoNote(highTrash))
    }

    func testSessionDateFromFolderName() {
        let d = CleanupSession.date(fromName: "20261016_101500_2")
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d!)
        XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute], [2026, 10, 16, 10, 15])
        XCTAssertNil(CleanupSession.date(fromName: "ScanHistory"))
    }

    func testFullDiskAccessRefresh() async throws {
        backend.fullDiskAccess = true
        model.refreshAccess()
        try await waitUntil { model.hasFullDiskAccess == true }
    }

    // MARK: Chữ

    func testEveryReasonAndOutcomeHasText() {
        let reasons: [CleanReason] = [
            .orphanBundleID("a"), .orphanName("a", days: 1), .emptyPathEntry, .duplicatePathEntry(firstIndex: 1),
            .deadPathDir(source: nil), .deadPathDir(source: "/f"), .envVarDead(name: "X", file: nil), .envVarDead(name: "X", file: "/f"),
            .missingProgram("p"), .ownerGone("o"), .loginItemDead, .needRootForBackgroundTasks, .helperOrphan, .helperNoJob,
            .receiptOrphan, .dockerGone, .dyldInsert(location: "l"), .thirdPartySudoers(file: "f"),
            .proxyRootCertificate(tool: "t"), .firewallRuleDead, .tccOrphan(service: "s"), .sysExtStale(state: "s"),
            .kextOrphan, .brokenSymlink(destination: "d"), .ghostLaunchServices(count: 2), .nativeHostDead(executable: "e"),
            .bundleBroken(executable: "e"), .pluginOrphan(owner: "o"), .hollowApp, .brokenApp(executable: "e"),
            .trashUsage(bytes: 1_000), .appBundle, .appRelated(name: "n"), .xcodeDerived, .xcodeDeviceSupport(version: "17"),
            .xcodeArchive, .simulatorUnavailable, .cacheOrphan(command: "c"), .cacheActive(command: "c"), .brewOrphan,
            .brewCache, .snapshot(date: "d"), .mobileSyncBackup(date: "d"), .hostsBlock(domain: "d"),
        ]
        XCTAssertEqual(Set(reasons.map(CleanupText.reason)).count, reasons.count, "mỗi lý do một câu riêng")
        let failures: [RemovalFailure] = [
            .refused(.homeDir), .trashFailed, .stillPresent, .symlinkRemoveFailed, .changedSinceScan, .backupFailed(file: "f"),
            .writeFailed(file: "f"), .lineNotFound(file: "f"), .manualEditRequired(file: "f"), .wouldBreakShellSyntax(file: "f"),
            .plistTrashFailed, .commandFailed(tool: "t"), .stillPresentNeedsAdmin, .notInTrash, .unsupportedKind("k"),
        ]
        XCTAssertEqual(Set(failures.map(CleanupText.failureMessage)).count, failures.count)
        XCTAssertNotNil(CleanupText.outcomeMessage(.skipped(.reportOnly)))
        XCTAssertNil(CleanupText.outcomeMessage(.done))
        for c in CleanCategory.allCases { XCTAssertFalse(CleanupText.category(c).isEmpty) }
    }
}

// MARK: - Backend thật trên cây thư mục tạm

/// Bộ quét giả trả finding cố định.
private struct FixedScanner: CleanScanner {
    let id = "Fixed"
    let findings: [Finding]
    func scan(_ context: ScanContext) throws -> [Finding] { findings }
}

private final class NoCommands: CommandRunner, @unchecked Sendable {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult { .notFound }
}

final class LiveCleanupBackendTests: XCTestCase {
    func testScanRemoveRestoreRoundTripInTemporaryTree() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CleanupUITests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = "/Users/tester"
        let cache = home + "/Library/Caches/com.gone.app"
        let phys = root.path + cache
        try FileManager.default.createDirectory(atPath: phys, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4_096).write(to: URL(fileURLWithPath: phys + "/blob"))
        let trash = root.appendingPathComponent("FakeTrash")
        let finding = Finding(category: .caches, severity: .high, name: "com.gone.app", target: cache,
                              reason: .orphanBundleID("com.gone.app"), sizeBytes: 4_096, action: .trashPath(path: cache))
        let backend = LiveCleanupBackend(appVersion: "0.0.0", runner: NoCommands(), trasher: DirectoryTrasher(trashDir: trash),
                                         scanners: [FixedScanner(findings: [finding])], signing: NoSigningInfoReader()) { _ in
            ScanEnvironment(root: root, homePath: home, uid: 501, userName: "tester", searchPath: [])
        }

        let output = try backend.scan(cancellation: CancellationToken()) { _ in }
        XCTAssertEqual(output.findings.map(\.id), [finding.id])
        XCTAssertFalse(output.findings[0].needsAdmin)

        let run = backend.remove(output.findings, cancellation: CancellationToken()) { _, _ in }
        XCTAssertEqual(run.items.map(\.outcome), [.done])
        XCTAssertFalse(FileManager.default.fileExists(atPath: phys))

        let sessions = backend.sessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].entryCount, 1)
        XCTAssertEqual(sessions[0].bytes, 4_096)
        XCTAssertNotNil(sessions[0].date)
        XCTAssertEqual(backend.entries(of: sessions[0].directory)?.first?.original, cache)

        var restored = backend.restore(sessions[0].directory, overwriteModifiedFiles: false, onlyEntries: nil)
        XCTAssertEqual(restored.items.map(\.status), [.restored])
        XCTAssertTrue(FileManager.default.fileExists(atPath: phys + "/blob"))
        XCTAssertNil(sessions[0].restore)
        restored.date = Date(timeIntervalSince1970: 1_792_000_000)
        backend.saveRestore(restored, in: sessions[0].directory)
        XCTAssertEqual(backend.sessions()[0].restore, restored, "đánh dấu đã khôi phục đọc lại được")
        XCTAssertEqual(backend.sessions()[0].entryCount, 1, "restored.json không lẫn vào manifest")

        // bỏ qua → lượt quét sau ẩn mục
        try backend.ignore([finding.id])
        let again = try backend.scan(cancellation: CancellationToken()) { _ in }
        XCTAssertTrue(again.findings.isEmpty)
        XCTAssertEqual(again.ignoredCount, 1)
        try backend.unignore([finding.id])
        XCTAssertEqual(try backend.scan(cancellation: CancellationToken()) { _ in }.findings.count, 1)
    }

    func testStoredRestoreStatusRoundTrip() {
        let all: [RestoreStatus] = [
            .restored, .failed(.moveFailed), .failed(.backupMissing), .failed(.writeFailed), .failed(.symlinkFailed),
            .manual(.alreadyExists), .manual(.notFoundInTrash), .manual(.trashItemReplaced), .manual(.permanentlyDeleted),
            .manual(.receiptNotReloadable(id: "a")), .manual(.readdFirewallRule(path: "/p")),
            .manual(.permissionAskedAgain(service: "Camera")), .manual(.modifiedSinceCleanup), .manual(.notRestorable(kind: "LsRebuild")),
        ]
        for status in all { XCTAssertEqual(StoredRestoreStatus(status).status, status) }
    }
}

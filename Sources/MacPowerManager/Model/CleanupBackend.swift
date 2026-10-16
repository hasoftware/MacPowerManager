import CleanCore
import Foundation

/// Backend thật: ScanEngine, Remover, Restorer, IgnoreList của CleanCore. Mỗi lời gọi dựng môi trường mới
/// (`now` dùng làm tên thư mục sao lưu). Test tiêm môi trường trong thư mục tạm, runner giả và Thùng rác giả.
struct LiveCleanupBackend: CleanupBackend {
    /// File tóm tắt của app trong thư mục sao lưu (dung lượng đã dọn). Restorer và restore.sh không đọc file này.
    static let summaryFileName = "summary.json"

    struct Summary: Codable {
        var format = 1
        var bytes: Int64
        var items: Int
    }

    /// File kết quả khôi phục của app trong thư mục sao lưu: đánh dấu đã khôi phục (không khôi phục lại nhầm).
    static let restoreFileName = "restored.json"

    struct RestoreRecord: Codable {
        struct Item: Codable {
            var index: Int
            var entry: ManifestEntry
            var status: StoredRestoreStatus
        }

        var format = 1
        var date: Date
        var items: [Item]

        init(_ run: CleanupRestoreRun) {
            date = run.date ?? Date()
            items = run.items.map { Item(index: $0.index, entry: $0.entry, status: StoredRestoreStatus($0.status)) }
        }

        var run: CleanupRestoreRun {
            CleanupRestoreRun(manifestFound: true, items: items.map {
                CleanupRestoreItem(index: $0.index, entry: $0.entry, status: $0.status.status)
            }, date: date)
        }
    }

    var appVersion: String
    var runner: CommandRunner
    /// Thùng rác thật khi nil.
    var trasher: Trasher?
    var scanners: [CleanScanner]
    var signing: SigningInfoReader
    /// `forScan`: quét cần môi trường shell đăng nhập (PATH, biến môi trường); gỡ/khôi phục thì không.
    var makeEnvironment: @Sendable (_ forScan: Bool) -> ScanEnvironment

    init(appVersion: String, runner: CommandRunner, trasher: Trasher? = nil,
         scanners: [CleanScanner] = ScanEngine.defaultScanners,
         signing: SigningInfoReader = SecuritySigningInfoReader(),
         makeEnvironment: @escaping @Sendable (Bool) -> ScanEnvironment) {
        self.appVersion = appVersion
        self.runner = runner
        self.trasher = trasher
        self.scanners = scanners
        self.signing = signing
        self.makeEnvironment = makeEnvironment
    }

    static func live(appVersion: String) -> LiveCleanupBackend {
        let runner = ProcessCommandRunner()
        return LiveCleanupBackend(appVersion: appVersion, runner: runner) { forScan in
            forScan ? ScanEnvironment.live(runner: runner)
                : ScanEnvironment(homePath: FileManager.default.homeDirectoryForCurrentUser.path)
        }
    }

    func hasFullDiskAccess() -> Bool { makeEnvironment(false).hasFullDiskAccess() }

    func scan(cancellation: CancellationToken,
              progress: @escaping @Sendable (CleanupScanStatus) -> Void) throws -> CleanupScanOutput {
        progress(CleanupScanStatus(stage: .preparing, done: 0, total: scanners.count))
        let env = makeEnvironment(true)
        if cancellation.isCancelled { throw CancellationError() }
        let engine = ScanEngine(env: env, runner: runner, scanners: scanners, signing: signing)
        let result = try engine.run(cancellation: cancellation) { p in
            let stage: CleanupScanStatus.Stage = switch p.phase {
            case .indexing: .indexing
            case .scanning(let id): .scanner(id)
            case .finishing: .finishing
            }
            progress(CleanupScanStatus(stage: stage, done: p.completed, total: p.total))
        }
        return CleanupScanOutput(findings: result.findings, ignoredCount: result.ignoredCount,
                                 hasFullDiskAccess: result.hasFullDiskAccess, scannerErrors: result.scannerErrors)
    }

    func remove(_ findings: [Finding], cancellation: CancellationToken,
                progress: @escaping @Sendable (Int, Int) -> Void) -> CleanupRemovalRun {
        let remover = Remover(env: makeEnvironment(false), runner: runner, trasher: trasher)
        let report = remover.removeSelected(findings, appVersion: appVersion, cancellation: cancellation) { _, done, total in
            progress(done, total)
        }
        let items = report.results.map {
            CleanupItemOutcome(findingID: $0.findingID, category: $0.category, name: $0.name, target: $0.target,
                               outcome: $0.outcome)
        }
        if let dir = report.backupDirectory {
            let removed = Set(items.filter(\.removed).map(\.findingID))
            let bytes = findings.filter { removed.contains($0.id) }.reduce(Int64(0)) { $0 + $1.sizeBytes }
            if let data = try? JSONEncoder().encode(Summary(bytes: bytes, items: removed.count)) {
                try? data.write(to: dir.appendingPathComponent(Self.summaryFileName), options: .atomic)
            }
        }
        return CleanupRemovalRun(backupDirectory: report.backupDirectory, items: items,
                                 sessionFailed: report.sessionFailed, cancelled: report.cancelled)
    }

    func adminCommand(for finding: Finding) -> String {
        Remover(env: makeEnvironment(false), runner: runner, trasher: trasher).adminCommand(for: finding)
    }

    func ignore(_ ids: [String]) throws { try IgnoreList(env: makeEnvironment(false)).add(ids) }

    func ignoreFileURL() -> URL { IgnoreList(env: makeEnvironment(false)).url }

    func unignore(_ ids: Set<String>) throws { try IgnoreList(env: makeEnvironment(false)).remove(ids) }

    func sessions() -> [CleanupSession] {
        Restorer.listBackups(env: makeEnvironment(false)).map { info in
            let summary = (try? Data(contentsOf: info.directory.appendingPathComponent(Self.summaryFileName)))
                .flatMap { try? JSONDecoder().decode(Summary.self, from: $0) }
            let restore = (try? Data(contentsOf: info.directory.appendingPathComponent(Self.restoreFileName)))
                .flatMap { try? Self.decoder.decode(RestoreRecord.self, from: $0) }
            return CleanupSession(directory: info.directory, name: info.name,
                                  date: CleanupSession.date(fromName: info.name), entryCount: info.entryCount,
                                  bytes: summary?.bytes, restore: restore?.run)
        }
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    func entries(of session: URL) -> [ManifestEntry]? { Restorer.loadEntries(directory: session) }

    func restore(_ session: URL, overwriteModifiedFiles: Bool, onlyEntries: Set<Int>?) -> CleanupRestoreRun {
        let report = Restorer(env: makeEnvironment(false), runner: runner)
            .restore(backupDirectory: session, overwriteModifiedFiles: overwriteModifiedFiles, onlyEntries: onlyEntries)
        return CleanupRestoreRun(manifestFound: report.manifestFound, items: report.results.map {
            CleanupRestoreItem(index: $0.index, entry: $0.entry, status: $0.status)
        })
    }

    func saveRestore(_ run: CleanupRestoreRun, in session: URL) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(RestoreRecord(run)) {
            try? data.write(to: session.appendingPathComponent(Self.restoreFileName), options: .atomic)
        }
    }
}

/// `RestoreStatus` dạng lưu được (mã + giá trị kèm theo).
struct StoredRestoreStatus: Codable, Equatable {
    var code: String
    var value: String?

    init(_ s: RestoreStatus) {
        switch s {
        case .restored: code = "restored"
        case .failed(.moveFailed): code = "failed.moveFailed"
        case .failed(.backupMissing): code = "failed.backupMissing"
        case .failed(.writeFailed): code = "failed.writeFailed"
        case .failed(.symlinkFailed): code = "failed.symlinkFailed"
        case .manual(.alreadyExists): code = "manual.alreadyExists"
        case .manual(.notFoundInTrash): code = "manual.notFoundInTrash"
        case .manual(.trashItemReplaced): code = "manual.trashItemReplaced"
        case .manual(.permanentlyDeleted): code = "manual.permanentlyDeleted"
        case .manual(.receiptNotReloadable(let id)): code = "manual.receiptNotReloadable"; value = id
        case .manual(.readdFirewallRule(let path)): code = "manual.readdFirewallRule"; value = path
        case .manual(.permissionAskedAgain(let service)): code = "manual.permissionAskedAgain"; value = service
        case .manual(.modifiedSinceCleanup): code = "manual.modifiedSinceCleanup"
        case .manual(.notRestorable(let kind)): code = "manual.notRestorable"; value = kind
        }
    }

    var status: RestoreStatus {
        let v = value ?? ""
        switch code {
        case "restored": return .restored
        case "failed.moveFailed": return .failed(.moveFailed)
        case "failed.backupMissing": return .failed(.backupMissing)
        case "failed.writeFailed": return .failed(.writeFailed)
        case "failed.symlinkFailed": return .failed(.symlinkFailed)
        case "manual.alreadyExists": return .manual(.alreadyExists)
        case "manual.notFoundInTrash": return .manual(.notFoundInTrash)
        case "manual.trashItemReplaced": return .manual(.trashItemReplaced)
        case "manual.permanentlyDeleted": return .manual(.permanentlyDeleted)
        case "manual.receiptNotReloadable": return .manual(.receiptNotReloadable(id: v))
        case "manual.readdFirewallRule": return .manual(.readdFirewallRule(path: v))
        case "manual.permissionAskedAgain": return .manual(.permissionAskedAgain(service: v))
        case "manual.modifiedSinceCleanup": return .manual(.modifiedSinceCleanup)
        default: return .manual(.notRestorable(kind: v.isEmpty ? code : v))
        }
    }
}

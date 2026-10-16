import Foundation

/// Vì sao một mục cần làm tay.
public enum RestoreManualReason: Sendable, Equatable {
    /// "BỎ QUA đã có ở chỗ cũ" - không bao giờ ghi đè thứ đã được tạo lại sau lần dọn.
    case alreadyExists
    /// "KHÔNG THẤY trong Thùng rác nào (đã đổ?)"
    case notFoundInTrash
    /// Tên trong Thùng rác giờ là một mục KHÁC (Thùng rác đã đổ rồi có mục trùng tên bỏ vào): không kéo về.
    case trashItemReplaced
    /// "KHÔNG THỂ đã xóa vĩnh viễn"
    case permanentlyDeleted
    /// "biên nhận gói '<id>' không nạp lại được"
    case receiptNotReloadable(id: String)
    /// "thêm lại luật tường lửa: <path>"
    case readdFirewallRule(path: String)
    /// "quyền '<service>' sẽ được hỏi lại khi app chạy"
    case permissionAskedAgain(service: String)
    /// File cấu hình đã bị sửa sau lần dọn: UI hỏi xác nhận rồi gọi lại với `overwriteModifiedFiles`.
    case modifiedSinceCleanup
    /// "BỎ QUA <kind> <orig>"
    case notRestorable(kind: String)
}

public enum RestoreFailure: Sendable, Equatable {
    /// "thiếu quyền? thử sudo"
    case moveFailed
    /// Không có/không thấy file backup.
    case backupMissing
    case writeFailed
    case symlinkFailed
}

public enum RestoreStatus: Sendable, Equatable {
    case restored
    case failed(RestoreFailure)
    case manual(RestoreManualReason)
}

public struct RestoreItemResult: Sendable, Equatable {
    /// Vị trí của entry trong manifest (đếm từ 0).
    public var index: Int
    public var entry: ManifestEntry
    public var status: RestoreStatus
}

public struct RestoreReport: Sendable {
    public var results: [RestoreItemResult]
    /// false khi thư mục không có manifest đọc được.
    public var manifestFound: Bool

    public var okCount: Int { results.filter { $0.status == .restored }.count }
    public var failCount: Int { results.filter { if case .failed = $0.status { return true }; return false }.count }
    public var manualCount: Int { results.filter { if case .manual = $0.status { return true }; return false }.count }
}

/// Một bản backup trong `dataDir`.
public struct BackupInfo: Sendable, Equatable {
    public var directory: URL
    public var name: String
    public var entryCount: Int
}

/// Khôi phục trong app từ manifest (`restore_from_manifest`). Cố ý không chạy restore.sh trong thư mục backup:
/// bản backup cũ vì thế tự động hưởng mọi bản vá sau này.
public struct Restorer: Sendable {
    public let env: ScanEnvironment
    public let runner: CommandRunner

    public init(env: ScanEnvironment, runner: CommandRunner) {
        self.env = env
        self.runner = runner
    }

    /// Các bản backup: thư mục con của `dataDir` có tên bắt đầu bằng chữ số, mới nhất trước.
    /// `ScanHistory` và `ignore.txt` nằm cùng chỗ nhưng không bắt đầu bằng chữ số nên không lẫn.
    public static func listBackups(env: ScanEnvironment) -> [BackupInfo] {
        let root = env.dataDir.path
        return FileProbe.childNames(root)
            .filter { $0.first?.isASCII == true && $0.first?.isNumber == true && FileProbe.isDirectory(root + "/" + $0) }
            .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            .reversed()
            .map { name in
                let dir = env.dataDir.appendingPathComponent(name)
                return BackupInfo(directory: dir, name: name, entryCount: loadEntries(directory: dir)?.count ?? 0)
            }
    }

    /// Đọc manifest.json; thiếu thì đọc manifest.tsv (định dạng MacTrash).
    public static func loadEntries(directory: URL) -> [ManifestEntry]? {
        let json = directory.appendingPathComponent(BackupSession.manifestJSONName)
        if let data = try? Data(contentsOf: json) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            if let m = try? dec.decode(Manifest.self, from: data) { return m.entries }
        }
        let tsv = directory.appendingPathComponent(BackupSession.manifestTSVName)
        guard let text = try? String(contentsOf: tsv, encoding: .utf8) else { return nil }
        return text.components(separatedBy: "\n").compactMap { ManifestEntry(tsvLine: $0) }
    }

    /// Khôi phục mọi entry theo thứ tự manifest.
    /// `overwriteModifiedFiles`: file cấu hình đã bị sửa sau lần dọn vẫn bị chép đè (chỉ khi người dùng xác nhận).
    /// `onlyEntries`: chỉ khôi phục các entry ở các vị trí này (vd chỉ ghi đè file đã sửa, không chạy lại mục đã
    /// khôi phục); kết quả chỉ có các entry đó.
    public func restore(backupDirectory dir: URL, overwriteModifiedFiles: Bool = false,
                        onlyEntries: Set<Int>? = nil) -> RestoreReport {
        guard let entries = Restorer.loadEntries(directory: dir) else {
            return RestoreReport(results: [], manifestFound: false)
        }
        // Nhiều mục cùng sửa một file: kỳ vọng nội dung hiện tại = nội dung sau lần ghi CUỐI; chỉ chép backup một lần.
        var lastHash: [String: String] = [:]
        for e in entries where e.contentHashAfter != nil { lastHash[e.original] = e.contentHashAfter }
        var restoredFiles = Set<String>()
        var results: [RestoreItemResult] = []
        for (i, e) in entries.enumerated() where onlyEntries?.contains(i) ?? true {
            let st = restoreOne(e, dir: dir, lastHash: lastHash, restoredFiles: &restoredFiles,
                                overwrite: overwriteModifiedFiles)
            results.append(RestoreItemResult(index: i, entry: e, status: st))
        }
        return RestoreReport(results: results, manifestFound: true)
    }

    private func restoreOne(_ e: ManifestEntry, dir: URL, lastHash: [String: String],
                            restoredFiles: inout Set<String>, overwrite: Bool) -> RestoreStatus {
        let orig = e.original
        let phys = env.physicalPath(orig)
        switch CleanKind(rawValue: e.kind) {
        case .trashPath:
            return restoreFromTrash(e)
        case .purgeTrash, .purgeAny:
            // zsh đưa PurgeAny vào nhánh Thùng rác (có thể kéo nhầm mục trùng tên về chỗ đã xóa vĩnh viễn).
            return .manual(.permanentlyDeleted)
        case .pathEntry, .envLine:
            if restoredFiles.contains(orig) { return .restored }
            guard let rel = e.backupRel, FileProbe.isRegularFile(dir.appendingPathComponent(rel).path),
                  let data = FileManager.default.contents(atPath: dir.appendingPathComponent(rel).path) else {
                return .failed(.backupMissing)
            }
            let target = FileProbe.isSymlink(phys) ? PathResolver.resolve(phys) : phys
            if !overwrite, let expected = lastHash[orig], let current = ContentHash.ofFile(target), current != expected {
                return .manual(.modifiedSinceCleanup)
            }
            guard ConfigFileEditor.write(data, to: target) else { return .failed(.writeFailed) }
            restoredFiles.insert(orig)
            return .restored
        case .launchdJob:
            guard let rel = e.backupRel, FileProbe.isRegularFile(dir.appendingPathComponent(rel).path) else {
                return .failed(.backupMissing)
            }
            // An toàn hơn `cp -a` của zsh: chỗ cũ đã có plist (được cài lại) thì không ghi đè.
            if FileProbe.lexists(phys) { return .manual(.alreadyExists) }
            do {
                try FileManager.default.createDirectory(atPath: PathResolver.parent(phys), withIntermediateDirectories: true)
                try FileManager.default.copyItem(atPath: dir.appendingPathComponent(rel).path, toPath: phys)
            } catch {
                return .failed(.writeFailed)
            }
            // extra = "<domain>/<label>", domain có thể là "gui/<uid>": cắt tại "/" CUỐI. (Lỗi zsh: `${extra%%/*}`
            // cho ra "gui", bootstrap luôn hỏng với job người dùng.)
            let extra = e.extra ?? ""
            let domain = extra.range(of: "/", options: .backwards).map { String(extra[..<$0.lowerBound]) } ?? ""
            if !domain.isEmpty { _ = runner.run(Tool.launchctl, ["bootstrap", domain, phys]) }
            return .restored
        case .symlink:
            if FileProbe.lexists(phys) { return .manual(.alreadyExists) }
            guard let dest = e.extra, !dest.isEmpty else { return .failed(.symlinkFailed) }
            return symlink(dest, phys) == 0 ? .restored : .failed(.symlinkFailed)
        case .pkgReceipt:
            return .manual(.receiptNotReloadable(id: orig))
        case .firewallApp:
            return .manual(.readdFirewallRule(path: orig))
        case .tccReset:
            return .manual(.permissionAskedAgain(service: e.extra ?? ""))
        default:
            return .manual(.notRestorable(kind: e.kind))
        }
    }

    /// Kéo từ Thùng rác về chỗ cũ, chỉ khi chỗ cũ đang TRỐNG.
    /// Nguồn: `trashedPath` (đường dẫn thực tế khi trash). Chỉ lùi về tra theo tên cuối khi manifest không có
    /// trường này (bản cũ/TSV) - tra theo tên có thể kéo nhầm mục trùng tên bỏ vào Thùng rác sau này.
    private func restoreFromTrash(_ e: ManifestEntry) -> RestoreStatus {
        let phys = env.physicalPath(e.original)
        if FileProbe.lexists(phys) { return .manual(.alreadyExists) }
        var source: String?
        if let t = e.trashedPath, !t.isEmpty {
            let p = env.physicalPath(t)
            if let st = FileProbe.lstat(p) {
                if let ino = e.trashedInode, let dev = e.trashedDevice,
                   UInt64(st.st_ino) != ino || Int64(st.st_dev) != dev {
                    return .manual(.trashItemReplaced)
                }
                source = p
            }
        } else {
            let base = PathResolver.tail(e.original)
            for c in [env.userTrashPath, env.homePath + "/.Trash", "/var/root/.Trash"] {
                let p = env.physicalPath(c + "/" + base)
                if FileProbe.lexists(p) { source = p; break }
            }
        }
        guard let src = source else { return .manual(.notFoundInTrash) }
        do {
            try FileManager.default.createDirectory(atPath: PathResolver.parent(phys), withIntermediateDirectories: true)
            // RENAME_EXCL: mục xuất hiện ở chỗ cũ SAU bước kiểm tra trên (app tự tạo lại) không bị ghi đè;
            // `rename` thường sẽ lặng lẽ thay file / thư mục rỗng đó.
            if renamex_np(src, phys, UInt32(RENAME_EXCL)) != 0 {
                if errno == EEXIST { return .manual(.alreadyExists) }
                // khác ổ (EXDEV...): moveItem tự từ chối khi đích đã có
                if FileProbe.lexists(phys) { return .manual(.alreadyExists) }
                try FileManager.default.moveItem(atPath: src, toPath: phys)
            }
        } catch {
            return .failed(.moveFailed)
        }
        // Trả chủ sở hữu gốc chỉ có nghĩa khi chạy root (P5); quyền người dùng thì chủ vốn đã đúng.
        if env.isRoot, let owner = e.owner ?? e.extra, owner.contains(":") {
            _ = runner.run("/usr/sbin/chown", ["-R", owner, phys])
        }
        return .restored
    }
}

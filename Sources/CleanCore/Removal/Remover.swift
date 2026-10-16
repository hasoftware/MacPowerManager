import Foundation

/// Vì sao gỡ thất bại (UI dịch; VI gốc ghi ở comment).
public enum RemovalFailure: Sendable, Equatable {
    /// "TỪ CHỐI: <lý do>" - chốt `is_deletable_path`.
    case refused(DeleteRefusal)
    /// "không chuyển được vào Thùng rác"
    case trashFailed
    /// "vẫn còn (đang bị khóa?)"
    case stillPresent
    /// "không xóa được symlink"
    case symlinkRemoveFailed
    /// Mục đã đổi từ lúc quét (vd symlink gãy giờ là file thật hoặc đã có đích) - không đụng vào.
    case changedSinceScan
    /// "không backup được <file>"
    case backupFailed(file: String)
    /// "không ghi được <file>"
    case writeFailed(file: String)
    /// Không còn dòng nào cần sửa trong file (zsh vẫn báo OK dù không đổi gì).
    case lineNotFound(file: String)
    /// Dòng khai báo không tắt an toàn được bằng comment (khối if, nối dòng, nhiều thư mục trên một dòng): người dùng
    /// tự sửa `file`. Không đổi gì.
    case manualEditRequired(file: String)
    /// Sửa xong thì file shell hỏng cú pháp (`zsh -n`/`bash -n`) trong khi trước đó không hỏng: không ghi.
    case wouldBreakShellSyntax(file: String)
    /// "không chuyển được plist vào Thùng rác"
    case plistTrashFailed
    /// "<tool> thất bại"
    case commandFailed(tool: String)
    /// "vẫn còn (thiếu quyền? thử sudo)"
    case stillPresentNeedsAdmin
    /// "TỪ CHỐI: đường dẫn không nằm trong Thùng rác"
    case notInTrash
    /// "kiểu gỡ chưa hỗ trợ: <kind>"
    case unsupportedKind(String)
}

/// Ghi chú khi xong một phần.
public enum PartialNote: Sendable, Equatable {
    /// ResEmptied: "đã xóa sạch nội dung; thư mục rỗng do macOS giữ lại"
    case emptiedKeptFolder
}

/// Vì sao bỏ qua.
public enum SkipReason: Sendable, Equatable {
    /// "chỉ báo, không tự gỡ"
    case reportOnly
    /// Đã nằm trong một mục TrashPath khác được chọn (cha hoặc trùng target).
    case coveredBy(target: String)
    /// Người dùng dừng giữa chừng.
    case cancelled
    /// Gỡ ứng dụng: gói của app `app` được chọn nhưng không gỡ được (lỗi, cần quản trị) → giữ lại dữ liệu của nó,
    /// không để app còn cài mà mất dữ liệu.
    case appKept(app: String)
}

/// Kết quả gỡ MỘT mục (zsh: 0 xong, 1 lỗi, 2 chỉ báo, 3 một phần).
public enum RemovalOutcome: Sendable, Equatable {
    case done
    case partial(PartialNote)
    case skipped(SkipReason)
    /// P0 không chạy quyền quản trị: trả lệnh tương đương để người dùng tự chạy.
    case needsAdmin(command: String)
    case failed(RemovalFailure)

    public enum Status: String, Sendable, Codable {
        case done, partial, skipped, needsAdmin, failed
    }

    public var status: Status {
        switch self {
        case .done: return .done
        case .partial: return .partial
        case .skipped: return .skipped
        case .needsAdmin: return .needsAdmin
        case .failed: return .failed
        }
    }

    /// Thứ tự hiển thị: mục cần chú ý lên trước (fail, sudo, part, skip, ok).
    public var displayRank: Int {
        switch status {
        case .failed: return 0
        case .needsAdmin: return 1
        case .partial: return 2
        case .skipped: return 3
        case .done: return 4
        }
    }
}

public struct RemovalResult: Sendable, Equatable {
    public var findingID: String
    public var category: CleanCategory
    public var name: String
    public var target: String
    public var outcome: RemovalOutcome
}

public struct RemovalReport: Sendable {
    /// Thư mục backup của lần dọn (nil khi không tạo được - khi đó không gỡ gì).
    public var backupDirectory: URL?
    public var results: [RemovalResult]
    /// `backup_init` lỗi → hủy toàn bộ.
    public var sessionFailed: Bool
    public var cancelled: Bool

    /// ok gồm cả partial (như zsh).
    public var okCount: Int { results.filter { $0.outcome.status == .done || $0.outcome.status == .partial }.count }
    public var failCount: Int { results.filter { $0.outcome.status == .failed }.count }
    public var needsAdminCount: Int { results.filter { $0.outcome.status == .needsAdmin }.count }
    public var skippedCount: Int { results.filter { $0.outcome.status == .skipped }.count }

    /// Mục cần chú ý lên trước, ổn định trong cùng nhóm.
    public var sortedForDisplay: [RemovalResult] {
        results.enumerated().sorted {
            ($0.element.outcome.displayRank, $0.offset) < ($1.element.outcome.displayRank, $1.offset)
        }.map(\.element)
    }
}

/// Gỡ các mục người dùng đã chọn. Chạy quyền người dùng (P0); mọi thao tác đều hoàn tác được trừ Purge*.
public struct Remover: Sendable {
    public let env: ScanEnvironment
    public let runner: CommandRunner
    public let trasher: Trasher

    /// `trasher` mặc định là Thùng rác thật; test PHẢI truyền `DirectoryTrasher` trỏ vào thư mục tạm.
    public init(env: ScanEnvironment, runner: CommandRunner, trasher: Trasher? = nil) {
        self.env = env
        self.runner = runner
        self.trasher = trasher ?? SystemTrasher(fallbackTrash: env.userTrash)
    }

    // MARK: Quyền quản trị

    /// `finding_needs_sudo`: không ghi được vào thư mục cha nghĩa là không xóa/sửa được mục đó.
    public func needsAdmin(_ f: Finding) -> Bool {
        Remover.needsAdmin(f, env: env)
    }

    public static func needsAdmin(_ f: Finding, env: ScanEnvironment) -> Bool {
        if env.isRoot { return false }
        var t = f.target
        switch f.action {
        case .pkgReceipt, .firewallApp, .snapshot: return true
        case .reportOnly, .tccReset, .lsRebuild, .simulator: return false
        case .pathEntry(let file, _), .envLine(let file, _): t = file
        default: break
        }
        guard !t.isEmpty else { return false }
        if !env.isWritable(PathResolver.parent(t)) { return true }
        // Chuyển THƯ MỤC sang thư mục cha khác (Thùng rác) phải sửa mục `..` của nó: cần quyền ghi trên chính thư mục
        // (đo thật: `mv` thư mục chmod 555 → Permission denied). App cài bằng pkg/App Store thuộc root -> cần admin.
        if case .trashPath = f.action, env.isRealDirectory(t), !env.isWritable(t) { return true }
        return false
    }

    /// Lệnh tương đương để người dùng tự chạy bằng quyền quản trị (P0 không chạy).
    public func adminCommand(for f: Finding) -> String {
        let q = RestoreScript.quote
        switch f.action {
        case .pkgReceipt(let id): return "sudo pkgutil --forget \(q(id))"
        case .firewallApp(let p): return "sudo \(Tool.socketfilterfw) --remove \(q(p))"
        case .trashPath(let p): return adminTrashCommand(p.isEmpty ? f.target : p)
        case .symlink(let p): return "sudo rm \(q(p.isEmpty ? f.target : p))"
        case .launchdJob(let plist, let label, let domain):
            return "sudo launchctl bootout \(domain)/\(label); " + adminTrashCommand(plist)
        case .pathEntry(let file, let dir):
            let escaped = dir.replacingOccurrences(of: "|", with: "\\|")
            return "sudo sed -i '' \(q("\\|^\(escaped)$|d")) \(q(file))"
        case .envLine(let file, let line):
            return "sudo nano \(q(file))   # \(ConfigFileEditor.disabledMarker)\(line)"
        case .snapshot(let name): return "sudo tmutil deletelocalsnapshots \(q(Remover.snapshotDate(name)))"
        case .purgeAny(let p), .purgeTrash(let p): return "sudo rm -rf \(q(p))"
        case .tccReset(let s, let c): return "tccutil reset \(q(s)) \(q(c))"
        case .lsRebuild: return "\(Tool.lsregister) -kill -r -domain local -domain system -domain user"
        case .simulator: return "xcrun simctl delete unavailable"
        case .reportOnly: return ""
        }
    }

    /// `to_trash` của MacTrash dưới sudo: tên đích CHƯA tồn tại (trùng → thêm ` HHmmss`, rồi `-2`...), `mv -n`
    /// (không bao giờ đè mục đã có trong Thùng rác, vd plist cùng tên vừa gỡ ở ~/Library/LaunchAgents), rồi trả chủ
    /// sở hữu về người dùng để Finder "Put Back"/xóa được.
    func adminTrashCommand(_ path: String) -> String {
        let q = RestoreScript.quote
        let base = PathResolver.tail(path)
        var dest = env.userTrashPath + "/" + base
        if env.lexists(dest) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "HHmmss"
            let stamped = dest + " " + f.string(from: env.now)
            dest = stamped
            var n = 2
            while env.lexists(dest) { dest = "\(stamped)-\(n)"; n += 1 }
        }
        return "sudo mv -n \(q(path)) \(q(dest)) && sudo chown -R \(q(env.userName)) \(q(dest))"
    }

    /// Ngày của snapshot: `com.apple.TimeMachine.2024-01-15-123456.local` → `2024-01-15-123456`.
    /// (Lỗi bản gốc: `${s##*.}` cho ra "local".)
    static func snapshotDate(_ name: String) -> String {
        var s = name
        if s.hasPrefix("com.apple.TimeMachine.") { s.removeFirst("com.apple.TimeMachine.".count) }
        return Names.removingSuffix(s, ".local")
    }

    // MARK: Gỡ một mục

    /// `remove_one`. Không tự xét quyền quản trị chung (như zsh; `removeSelected` xét trước), trừ các kind luôn cần
    /// admin. Mọi thay đổi được ghi vào `session`.
    public func removeOne(_ f: Finding, session: BackupSession) -> RemovalOutcome {
        switch f.action {
        case .reportOnly:
            return .skipped(.reportOnly)
        case .trashPath(let p):
            return trashPath(p.isEmpty ? f.target : p, finding: f, session: session)
        case .symlink(let p):
            return removeSymlink(p.isEmpty ? f.target : p, finding: f, session: session)
        case .pathEntry(let file, let dir):
            let isPathsFile = file == "/etc/paths" || file.hasPrefix("/etc/paths.d/")
            return editConfig(file, kind: .pathEntry, extra: dir, finding: f, session: session,
                              checkShellSyntax: !isPathsFile) { lines in
                isPathsFile ? ConfigFileEditor.removingPathLines(lines, dir: dir)
                    : ConfigFileEditor.disablingPathEntry(dir, in: lines)
            }
        case .envLine(let file, let line):
            return editConfig(file, kind: .envLine, extra: nil, finding: f, session: session,
                              checkShellSyntax: true) { lines in
                if ConfigFileEditor.endsWithContinuation(line) { return nil }
                return ConfigFileEditor.commentingLines(equalTo: line, in: lines)
            }
        case .launchdJob(let plist, let label, let domain):
            return removeLaunchdJob(plist: plist, label: label, domain: domain, finding: f, session: session)
        case .pkgReceipt, .firewallApp, .snapshot:
            // P0: luôn cần quyền quản trị, không thực thi.
            return .needsAdmin(command: adminCommand(for: f))
        case .tccReset(let service, let client):
            let r = runner.run(Tool.tccutil, ["reset", service, client])
            guard r.succeeded else { return .failed(.commandFailed(tool: "tccutil reset")) }
            session.record(ManifestEntry(kind: CleanKind.tccReset.rawValue, original: client, extra: service,
                                         findingID: f.id, at: env.now))
            return .done
        case .lsRebuild:
            let r = runner.run(Tool.lsregister, ["-kill", "-r", "-domain", "local", "-domain", "system", "-domain", "user"],
                               timeout: 300)
            guard r.succeeded else { return .failed(.commandFailed(tool: "lsregister")) }
            session.record(ManifestEntry(kind: CleanKind.lsRebuild.rawValue, original: "LaunchServices",
                                         extra: "đã dựng lại CSDL", findingID: f.id, at: env.now))
            return .done
        case .simulator:
            let r = runner.run(Tool.xcrun, ["simctl", "delete", "unavailable"], timeout: 300)
            guard r.succeeded else { return .failed(.commandFailed(tool: "simctl delete unavailable")) }
            session.record(ManifestEntry(kind: CleanKind.simulator.rawValue, original: "simulators",
                                         findingID: f.id, at: env.now))
            return .done
        case .purgeAny(let p):
            return purgeAny(p.isEmpty ? f.target : p, finding: f, session: session)
        case .purgeTrash(let p):
            return purgeTrash(p.isEmpty ? f.target : p, finding: f, session: session)
        }
    }

    /// `to_trash`: không tồn tại (kể cả không phải symlink) → nil = đã biến mất, coi như xong.
    /// Trả đường dẫn logic trong Thùng rác. Không đi xuyên symlink: trash chính cái link.
    func toTrash(_ logical: String) throws -> String? {
        let phys = env.physicalPath(logical)
        guard FileProbe.lexists(phys) else { return nil }
        let url = try trasher.moveToTrash(URL(fileURLWithPath: phys))
        return env.logicalPath(url.path)
    }

    private func trashPath(_ target: String, finding f: Finding, session: BackupSession) -> RemovalOutcome {
        // Phòng thủ nhiều lớp - nếu có module quét nào lỡ sinh ra một đường dẫn nguy hiểm, nó bị chặn ở đây.
        if let why = env.deletionRefusal(for: target) { return .failed(.refused(why)) }
        let phys = env.physicalPath(target)
        // Không còn gì → xong, và KHÔNG ghi manifest (tránh ghi trùng khi hai mục cùng target).
        guard FileProbe.lexists(phys) else { return .done }
        // Ghi chủ sở hữu TRƯỚC khi chuyển: khôi phục bằng sudo mà không có thông tin này thì file quay về dưới quyền
        // root, và app do người dùng tự kéo vào /Applications sẽ không tự cập nhật được nữa.
        let owner = FileProbe.ownerString(phys)
        let trashed: String?
        do { trashed = try toTrash(target) } catch { return .failed(.trashFailed) }
        if FileProbe.exists(phys) { return .failed(.stillPresent) }
        // định danh của mục trong Thùng rác: khôi phục không kéo nhầm mục KHÁC trùng tên bỏ vào sau này
        let st = trashed.flatMap { FileProbe.lstat(env.physicalPath($0)) }
        session.record(ManifestEntry(kind: CleanKind.trashPath.rawValue, original: target, extra: owner,
                                     owner: owner, trashedPath: trashed, findingID: f.id,
                                     trashedInode: st.map { UInt64($0.st_ino) },
                                     trashedDevice: st.map { Int64($0.st_dev) }, at: env.now))
        return .done
    }

    private func removeSymlink(_ target: String, finding f: Finding, session: BackupSession) -> RemovalOutcome {
        if let why = env.deletionRefusal(for: target) { return .failed(.refused(why)) }
        let phys = env.physicalPath(target)
        guard FileProbe.lexists(phys) else { return .done }
        // zsh `rm -f` không kiểm tra lại: nếu người dùng đã tạo lại một file THẬT sau lần quét thì bị xóa vĩnh viễn.
        // Ở đây chỉ gỡ khi vẫn là symlink và vẫn gãy.
        guard FileProbe.isSymlink(phys), !FileProbe.exists(phys) else { return .failed(.changedSinceScan) }
        let dest = FileProbe.readlink(phys) ?? ""
        // Vào Thùng rác thay cho `rm -f` (hoàn tác được thêm một đường), đích vẫn ghi vào manifest để tạo lại.
        let trashed: String?
        do { trashed = try toTrash(target) } catch { return .failed(.symlinkRemoveFailed) }
        if FileProbe.lexists(phys) { return .failed(.symlinkRemoveFailed) }
        session.record(ManifestEntry(kind: CleanKind.symlink.rawValue, original: target, extra: dest,
                                     trashedPath: trashed, findingID: f.id, at: env.now))
        return .done
    }

    private func editConfig(_ file: String, kind: CleanKind, extra: String?, finding f: Finding,
                            session: BackupSession, checkShellSyntax: Bool,
                            transform: ([String]) -> [String]?) -> RemovalOutcome {
        guard let saved = session.saveFileDetailed(file) else { return .failed(.backupFailed(file: file)) }
        let phys = env.physicalPath(file)
        let validate: ((Data, Data) -> Bool)? = checkShellSyntax ? { old, new in
            self.shellSyntaxAccepts(shell: ConfigFileEditor.syntaxShell(for: file), before: old, after: new,
                                    scratch: session.directory)
        } : nil
        switch ConfigFileEditor.rewrite(phys, transform: transform, validate: validate) {
        case .failed: return .failed(.writeFailed(file: file))
        case .unchanged: return .failed(.lineNotFound(file: file))
        case .needsManualEdit: return .failed(.manualEditRequired(file: file))
        case .rejected: return .failed(.wouldBreakShellSyntax(file: file))
        case .changed:
            let written = FileProbe.isSymlink(phys) ? PathResolver.resolve(phys) : phys
            session.record(ManifestEntry(kind: kind.rawValue, original: file, backupRel: saved.rel, extra: extra,
                                         findingID: f.id, contentHashAfter: ContentHash.ofFile(written),
                                         backupIsSymlinkTarget: saved.isSymlinkTarget ? true : nil, at: env.now))
            return .done
        }
    }

    /// `zsh -n`/`bash -n` qua runner: nội dung cũ qua mà nội dung mới không qua → từ chối. Cũ vốn không qua (hoặc
    /// không chạy được shell) → không phán xét được, chấp nhận như trước.
    func shellSyntaxAccepts(shell: String, before: Data, after: Data, scratch: URL) -> Bool {
        let dir = scratch.appendingPathComponent(".syntax-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return true
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("before"), b = dir.appendingPathComponent("after")
        guard (try? before.write(to: a)) != nil, (try? after.write(to: b)) != nil else { return true }
        guard runner.run(shell, ["-n", a.path], timeout: 10).succeeded else { return true }
        return runner.run(shell, ["-n", b.path], timeout: 10).succeeded
    }

    /// bootout CHỈ khi job đang nạp đúng là từ plist này (`launchctl print` → `path = ...`). Nhãn trùng với một job
    /// khác còn chạy tốt (plist cùng Label ở /Library/LaunchAgents) thì không đụng tới. Trả true nếu đã bootout.
    @discardableResult
    func bootoutIfLoaded(from plist: String, label: String, domain: String) -> Bool {
        let r = runner.run(Tool.launchctl, ["print", "\(domain)/\(label)"], timeout: 10)
        guard r.succeeded else { return false }   // không nạp -> không có gì để dừng
        let candidates: Set<String> = [plist, env.physicalPath(plist), PathResolver.resolve(env.physicalPath(plist))]
        let loadedFromHere = r.lines.contains { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("path = ") else { return false }
            return candidates.contains(String(t.dropFirst("path = ".count)))
        }
        guard loadedFromHere else { return false }
        // bootout hay báo lỗi khi job vốn không được nạp - không coi là lỗi
        _ = runner.run(Tool.launchctl, ["bootout", "\(domain)/\(label)"])
        return true
    }

    private func removeLaunchdJob(plist: String, label: String, domain: String, finding f: Finding,
                                  session: BackupSession) -> RemovalOutcome {
        if let why = env.deletionRefusal(for: plist) { return .failed(.refused(why)) }
        let phys = env.physicalPath(plist)
        guard FileProbe.lexists(phys) else {
            bootoutIfLoaded(from: plist, label: label, domain: domain)
            return .done
        }
        // Khác zsh (bỏ qua lỗi backup): không có backup thì không hoàn tác được -> dừng.
        guard let rel = session.saveFile(plist) else { return .failed(.backupFailed(file: plist)) }
        // Trash TRƯỚC, bootout SAU: trash lỗi thì job vẫn nguyên trạng (không bị dừng mà không có manifest).
        let trashed: String?
        do { trashed = try toTrash(plist) } catch { return .failed(.plistTrashFailed) }
        if FileProbe.lexists(phys) { return .failed(.plistTrashFailed) }
        bootoutIfLoaded(from: plist, label: label, domain: domain)
        session.record(ManifestEntry(kind: CleanKind.launchdJob.rawValue, original: plist, backupRel: rel,
                                     extra: "\(domain)/\(label)", trashedPath: trashed, findingID: f.id, at: env.now))
        return .done
    }

    /// PurgeAny - nguy hiểm nhất vì không bị giới hạn trong Thùng rác. Chốt chặn phải nằm ngay sát lệnh xóa.
    private func purgeAny(_ t: String, finding f: Finding, session: BackupSession) -> RemovalOutcome {
        if let why = env.deletionRefusal(for: t) { return .failed(.refused(why)) }
        let phys = env.physicalPath(t)
        guard FileProbe.lexists(phys) else { return .done }
        Remover.purgeTree(phys)
        if FileProbe.lexists(phys) {
            // /Library/Caches: xóa sạch nội dung nhưng macOS giữ lại thư mục rỗng. Đó là kết quả TỐT NHẤT có thể
            // đạt được - báo "lỗi" là sai sự thật.
            if FileProbe.isRealDirectory(phys), FileProbe.dirIsEmpty(phys) {
                session.record(ManifestEntry(kind: CleanKind.purgeAny.rawValue, original: t,
                                             extra: "đã dọn sạch nội dung, giữ lại thư mục rỗng", findingID: f.id,
                                             at: env.now))
                return .partial(.emptiedKeptFolder)
            }
            return .failed(.stillPresentNeedsAdmin)
        }
        session.record(ManifestEntry(kind: CleanKind.purgeAny.rawValue, original: t,
                                     extra: "xóa vĩnh viễn - không hoàn tác được", findingID: f.id, at: env.now))
        return .done
    }

    /// PurgeTrash - NƠI DUY NHẤT xóa vĩnh viễn trong Thùng rác, thao tác không hoàn tác được.
    private func purgeTrash(_ t: String, finding f: Finding, session: BackupSession) -> RemovalOutcome {
        guard env.isTrashPath(t) else { return .failed(.notInTrash) }
        let phys = env.physicalPath(t)
        guard FileProbe.lexists(phys) else { return .done }
        Remover.purgeTree(phys)
        if FileProbe.lexists(phys) { return .failed(.stillPresent) }
        session.record(ManifestEntry(kind: CleanKind.purgeTrash.rawValue, original: t,
                                     extra: "xóa vĩnh viễn - không hoàn tác được", findingID: f.id, at: env.now))
        return .done
    }

    /// Xóa đệ quy từ dưới lên, KHÔNG theo symlink (xóa link, không đụng đích), bỏ qua lỗi để xóa được hết những gì
    /// xóa được như `rm -rf` (`FileManager.removeItem` dừng ở lỗi đầu tiên).
    /// Đi bằng file descriptor (`openat`/`unlinkat` + `O_NOFOLLOW`): thư mục bị tráo thành symlink giữa chừng không
    /// kéo lệnh xóa sang đích của nó; không vượt điểm mount (`-x`), volume mount bên trong cây được để nguyên.
    static func purgeTree(_ path: String) {
        guard let st = FileProbe.lstat(path) else { return }
        guard FileProbe.isDir(st) else {
            unlink(path)
            return
        }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { return }
        var fst = Darwin.stat()
        guard fstat(fd, &fst) == 0 else { close(fd); return }
        purgeContents(dirFD: fd, device: fst.st_dev)   // đóng fd
        rmdir(path)
    }

    /// Xóa nội dung thư mục `dirFD` (fd bị đóng khi xong). Mục khác `device` (điểm mount) bị bỏ qua.
    private static func purgeContents(dirFD fd: Int32, device: dev_t) {
        guard let dir = fdopendir(fd) else { close(fd); return }
        defer { closedir(dir) }
        var names: [String] = []
        while let ent = readdir(dir) {
            let name = withUnsafePointer(to: ent.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(ent.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        for name in names {
            var st = Darwin.stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            if FileProbe.isDir(st) {
                guard st.st_dev == device else { continue }
                let sub = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard sub >= 0 else { continue }
                var sst = Darwin.stat()
                guard fstat(sub, &sst) == 0, sst.st_dev == device, sst.st_ino == st.st_ino else { close(sub); continue }
                purgeContents(dirFD: sub, device: device)
                unlinkat(fd, name, AT_REMOVEDIR)
            } else {
                unlinkat(fd, name, 0)
            }
        }
    }

    // MARK: Gỡ nhiều mục

    /// Bỏ các TrashPath có target là CON CHÁU (hoặc trùng) một TrashPath khác cũng được chọn. Nếu không, con được
    /// trash trước thì khi khôi phục, cha bị tạo lại rỗng -> cha "BỎ QUA đã có", nội dung kẹt trong Thùng rác.
    /// Trả map vị trí → target bao trùm.
    public static func coveredTrashPaths(_ findings: [Finding]) -> [Int: String] {
        func path(_ f: Finding) -> String? {
            guard case .trashPath(let p) = f.action else { return nil }
            return PathResolver.lexical(p.isEmpty ? f.target : p)
        }
        let paths = findings.map(path)
        var covered: [Int: String] = [:]
        for (i, p) in paths.enumerated() {
            guard let p else { continue }
            for (j, q) in paths.enumerated() where j != i {
                guard let q else { continue }
                if (p == q && j < i) || p.hasPrefix(q == "/" ? "/" : q + "/") {
                    covered[i] = q
                    break
                }
            }
        }
        return covered
    }

    /// `remove_selected`: tạo phiên backup (lỗi → không gỡ gì), gỡ theo đúng thứ tự truyền vào, mục cần admin trả
    /// lệnh tương đương, dừng được giữa chừng; luôn sinh restore.sh ở cuối.
    public func removeSelected(_ findings: [Finding], appVersion: String,
                               cancellation: CancellationToken = CancellationToken(),
                               progress: ((RemovalResult, Int, Int) -> Void)? = nil) -> RemovalReport {
        let macOS = runner.run(Tool.swVers, ["-productVersion"], timeout: 5).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let session: BackupSession
        do {
            session = try BackupSession(env: env, appVersion: appVersion, macOSVersion: macOS)
        } catch {
            return RemovalReport(backupDirectory: nil, results: [], sessionFailed: true, cancelled: false)
        }
        let covered = Remover.coveredTrashPaths(findings)
        var results: [RemovalResult] = []
        var cancelled = false
        // Gỡ ứng dụng: app có gói được chọn mà gói không gỡ được → đường dẫn app → tên (mục SAU của app đó bị bỏ qua).
        var keptApps: [String: String] = [:]
        for (i, f) in findings.enumerated() {
            let outcome: RemovalOutcome
            if cancellation.isCancelled {
                cancelled = true
                outcome = .skipped(.cancelled)
            } else if let q = covered[i] {
                outcome = .skipped(.coveredBy(target: q))
            } else if let kept = f.uninstallOwners.lazy.compactMap({ keptApps[$0.path] }).first {
                outcome = .skipped(.appKept(app: kept))
            } else if needsAdmin(f) {
                outcome = .needsAdmin(command: adminCommand(for: f))
            } else {
                outcome = removeOne(f, session: session)
            }
            if case .appBundle(let ref) = f.reason, outcome.status == .failed || outcome.status == .needsAdmin {
                keptApps[ref.path] = ref.name
            }
            let r = RemovalResult(findingID: f.id, category: f.category, name: f.name, target: f.target, outcome: outcome)
            session.log(Remover.logLine(r))
            results.append(r)
            progress?(r, i + 1, findings.count)
        }
        try? session.writeRestoreScript()
        return RemovalReport(backupDirectory: session.directory, results: results, sessionFailed: false,
                             cancelled: cancelled)
    }

    static func logLine(_ r: RemovalResult) -> String {
        let head = "\(r.category.rawValue) | \(r.name) | \(r.target)"
        switch r.outcome {
        case .done: return "OK    \(head)"
        case .partial(let n): return "PART  \(head) | \(n)"
        case .skipped(let s): return "SKIP  \(head) | \(s)"
        case .needsAdmin: return "SUDO  \(head)"
        case .failed(let e): return "FAIL  \(head) | \(e)"
        }
    }
}

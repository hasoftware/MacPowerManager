import XCTest
@testable import CleanCore

/// Port các section backup/manifest/vòng đời gỡ + khôi phục của tests/mactrash_test.zsh, cộng các vòng
/// gỡ → backup → khôi phục trên cây giả (Thùng rác giả, không bao giờ Thùng rác thật).
final class BackupRestoreTests: XCTestCase {
    private func session(_ env: ScanEnvironment) throws -> BackupSession {
        try BackupSession(env: env, appVersion: "test", macOSVersion: "test")
    }

    // MARK: Backup không ghi đè bản gốc

    func testBackupDoesNotOverwriteOriginal() throws {
        let tree = FakeTree()
        let s = try session(tree.env)
        tree.write("/sb/cfg.txt", "dòng gốc\n")
        let first = s.saveFile("/sb/cfg.txt")
        tree.write("/sb/cfg.txt", "ĐÃ BỊ SỬA\n")
        let second = s.saveFile("/sb/cfg.txt")
        XCTAssertNotNil(first)
        XCTAssertEqual(second, first)   // lần thứ hai dùng lại đúng bản backup đầu
        let content = try String(contentsOf: s.directory.appendingPathComponent(first ?? "?"), encoding: .utf8)
        XCTAssertEqual(content, "dòng gốc\n")   // nội dung backup vẫn là bản GỐC
        XCTAssertEqual(first, "files/001_cfg.txt")
        XCTAssertNil(s.saveFile("/sb/khong-co"))
    }

    // MARK: manifest giữ đúng cột khi có ô trống

    func testManifestKeepsColumnsWithEmptyCells() throws {
        let tree = FakeTree()
        let s = try session(tree.env)
        s.record(ManifestEntry(kind: "Symlink", original: "/tmp/a", backupRel: nil, extra: "/dich/cua/no"))
        let tsv = try String(contentsOf: s.directory.appendingPathComponent("manifest.tsv"), encoding: .utf8)
        let cols = (tsv.components(separatedBy: "\n").first ?? "").components(separatedBy: "\t")
        XCTAssertEqual(cols.count, 4)
        XCTAssertEqual(cols[0], "Symlink")
        XCTAssertEqual(cols[1], "/tmp/a")
        XCTAssertEqual(cols[2], "-")              // ô trống thành "-"
        XCTAssertEqual(cols[3], "/dich/cua/no")   // cột cuối KHÔNG bị dồn lên
        let entries = try XCTUnwrap(Restorer.loadEntries(directory: s.directory))
        XCTAssertNil(entries[0].backupRel)
        XCTAssertEqual(entries[0].extra, "/dich/cua/no")
        // TSV fallback đọc lại đúng
        XCTAssertEqual(ManifestEntry(tsvLine: cols.joined(separator: "\t"))?.extra, "/dich/cua/no")
        XCTAssertNil(ManifestEntry(tsvLine: "a\tb\tc\td").flatMap { $0.backupRel == "c" ? nil : $0 })
    }

    // MARK: Vòng đời gỡ + khôi phục (symlink, kèm chạy restore.sh thật bằng zsh trong thư mục tạm)

    func testSymlinkRemoveAndRestoreLifecycle() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("CleanCoreLife-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let link = tmp.path + "/bin/deadlink"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/khong/co/that")
        // Root thật nhưng mọi thứ nằm trong thư mục tạm; Thùng rác giả.
        let env = ScanEnvironment(homePath: tmp.path, dataDir: tmp.appendingPathComponent("data"))
        let remover = Remover(env: env, runner: StubRunner(), trasher: DirectoryTrasher(trashDir: tmp.appendingPathComponent("trash")))
        let f = Finding(category: .symlink, severity: .high, name: "dead", target: link,
                        reason: .brokenSymlink(destination: "/khong/co/that"), action: .symlink(path: link))
        let report = remover.removeSelected([f], appVersion: "test")
        XCTAssertEqual(report.results.first?.outcome, .done)
        XCTAssertFalse(FileProbe.isSymlink(link))   // symlink đã bị gỡ

        let dir = try XCTUnwrap(report.backupDirectory)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [dir.appendingPathComponent("restore.sh").path]
        p.environment = ["HOME": tmp.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(FileProbe.readlink(link), "/khong/co/that")   // restore.sh tạo lại đúng đích cũ

        // Khôi phục trong app: đã có ở chỗ cũ → làm tay, không ghi đè.
        let again = Restorer(env: env, runner: StubRunner()).restore(backupDirectory: dir)
        XCTAssertEqual(again.results.first?.status, .manual(.alreadyExists))
        try FileManager.default.removeItem(atPath: link)
        let back = Restorer(env: env, runner: StubRunner()).restore(backupDirectory: dir)
        XCTAssertEqual(back.results.first?.status, .restored)
        XCTAssertEqual(FileProbe.readlink(link), "/khong/co/that")
    }

    func testSymlinkChangedSinceScanIsNotTouched() throws {
        let tree = FakeTree()
        tree.write("/usr/local/bin/tool", "real file")
        let f = Finding(category: .symlink, severity: .high, name: "tool", target: "/usr/local/bin/tool",
                        reason: .brokenSymlink(destination: "?"), action: .symlink(path: "/usr/local/bin/tool"))
        let r = Remover(env: tree.env, runner: StubRunner(), trasher: tree.trasher)
        XCTAssertEqual(r.removeOne(f, session: try session(tree.env)), .failed(.changedSinceScan))
        XCTAssertEqual(tree.read("/usr/local/bin/tool"), "real file")
    }

    // MARK: Mục "chỉ báo" không bao giờ bị gỡ

    func testReportOnlyIsNeverRemoved() throws {
        let tree = FakeTree()
        let f = finding(.caches, .info, "note", target: "none")
        let r = Remover(env: tree.env, runner: StubRunner(), trasher: tree.trasher)
        XCTAssertEqual(r.removeOne(f, session: try session(tree.env)), .skipped(.reportOnly))
    }

    // MARK: TrashPath: gỡ → khôi phục

    func testTrashPathRoundTrip() throws {
        let tree = FakeTree()
        let target = "\(tree.homePath)/Library/Caches/com.gone.app"
        tree.write(target + "/data.bin", "cache")
        tree.write(tree.homePath + "/.Trash/com.gone.app", "mục khác trùng tên trong Thùng rác")
        let f = Finding(category: .caches, severity: .high, name: "com.gone.app", target: target,
                        reason: .orphanBundleID("com.gone.app"), action: .trashPath(path: target))
        let r = Remover(env: tree.env, runner: StubRunner(), trasher: tree.trasher)
        let report = r.removeSelected([f], appVersion: "test")
        XCTAssertEqual(report.results.map(\.outcome), [.done])
        XCTAssertFalse(tree.exists(target))
        XCTAssertTrue(FileProbe.isRegularFile(tree.trashDir.path + "/com.gone.app/data.bin"))

        let dir = try XCTUnwrap(report.backupDirectory)
        let entries = try XCTUnwrap(Restorer.loadEntries(directory: dir))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].kind, "TrashPath")
        XCTAssertEqual(entries[0].original, target)
        XCTAssertEqual(entries[0].findingID, f.id)
        XCTAssertNotNil(entries[0].owner)
        XCTAssertEqual(entries[0].trashedPath.map { tree.env.physicalPath($0) }, tree.trashDir.path + "/com.gone.app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("restore.sh").path))

        let res = Restorer(env: tree.env, runner: StubRunner()).restore(backupDirectory: dir)
        XCTAssertEqual(res.okCount, 1)
        XCTAssertEqual(tree.read(target + "/data.bin"), "cache")
        // Dùng trashedPath: không kéo nhầm mục trùng tên trong ~/.Trash
        XCTAssertEqual(tree.read(tree.homePath + "/.Trash/com.gone.app"), "mục khác trùng tên trong Thùng rác")
    }

    func testTrashPathRefusedByGuard() throws {
        let tree = FakeTree()
        tree.mkdir("/Library/Caches")
        let f = Finding(category: .caches, severity: .high, name: "Library", target: "/Library",
                        reason: .helperOrphan, action: .trashPath(path: "/Library"))
        let r = Remover(env: tree.env, runner: StubRunner(), trasher: tree.trasher)
        XCTAssertEqual(r.removeOne(f, session: try session(tree.env)), .failed(.refused(.criticalSystemDir)))
        XCTAssertTrue(tree.env.isDirectory("/Library/Caches"))
    }

    func testTrashPathMissingIsDoneWithoutManifestEntry() throws {
        let tree = FakeTree()
        let s = try session(tree.env)
        let p = "\(tree.homePath)/Library/Caches/gone"
        let f = finding(.caches, .high, "gone", target: p, action: .trashPath(path: p))
        XCTAssertEqual(Remover(env: tree.env, runner: StubRunner(), trasher: tree.trasher).removeOne(f, session: s), .done)
        XCTAssertTrue(s.entries.isEmpty)
    }

    // MARK: PathEntry / EnvLine

    func testPathEntryInPathsDRemovesExactLine() throws {
        let tree = FakeTree()
        tree.write("/etc/paths.d/x", "/opt/dead\n/opt/dead/bin\n/usr/local/x\n")
        let f = Finding(category: .path, severity: .high, name: "PATH #3", target: "/opt/dead",
                        reason: .deadPathDir(source: "/etc/paths.d/x"), action: .pathEntry(file: "/etc/paths.d/x", dir: "/opt/dead"))
        let r = Remover(env: tree.env, runner: StubRunner(), trasher: tree.trasher)
        XCTAssertEqual(r.removeOne(f, session: try session(tree.env)), .done)
        XCTAssertEqual(tree.read("/etc/paths.d/x"), "/opt/dead/bin\n/usr/local/x\n")
    }

    /// `.zshrc` là symlink (dotfiles), không có `\n` cuối, hai finding cùng file → một backup bản gốc.
    func testPathEntryInSymlinkedZshrc() throws {
        let tree = FakeTree()
        let h = tree.homePath
        let original = "# export PATH=/opt/a:$PATH\nexport PATH=/opt/a:$PATH\nexport PATH=/opt/b:$PATH\nalias x=y"
        tree.write("\(h)/dotfiles/zshrc", original)
        chmod(tree.phys("\(h)/dotfiles/zshrc"), 0o640)
        tree.symlink("\(h)/.zshrc", to: tree.phys("\(h)/dotfiles/zshrc"))
        let zshrc = "\(h)/.zshrc"
        let fa = Finding(category: .path, severity: .high, name: "PATH #1", target: "/opt/a",
                         reason: .deadPathDir(source: zshrc), action: .pathEntry(file: zshrc, dir: "/opt/a"))
        let fb = Finding(category: .path, severity: .high, name: "PATH #2", target: "/opt/b",
                         reason: .deadPathDir(source: zshrc), action: .pathEntry(file: zshrc, dir: "/opt/b"))
        let r = Remover(env: tree.env, runner: StubRunner(), trasher: tree.trasher)
        let report = r.removeSelected([fa, fb], appVersion: "test")
        XCTAssertEqual(report.results.map(\.outcome), [.done, .done])
        XCTAssertTrue(FileProbe.isSymlink(tree.phys(zshrc)))   // symlink còn nguyên
        let m = ConfigFileEditor.disabledMarker
        XCTAssertEqual(tree.read("\(h)/dotfiles/zshrc"),
                       "# export PATH=/opt/a:$PATH\n\(m)export PATH=/opt/a:$PATH\n\(m)export PATH=/opt/b:$PATH\nalias x=y")
        XCTAssertEqual(FileProbe.stat(tree.phys("\(h)/dotfiles/zshrc")).map { $0.st_mode & 0o777 }, 0o640)

        let dir = try XCTUnwrap(report.backupDirectory)
        let entries = try XCTUnwrap(Restorer.loadEntries(directory: dir))
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].backupRel, entries[1].backupRel)   // một backup cho cả hai
        XCTAssertEqual(entries[0].extra, "/opt/a")
        let backup = try String(contentsOf: dir.appendingPathComponent(entries[0].backupRel ?? "?"), encoding: .utf8)
        XCTAssertEqual(backup, original)

        let res = Restorer(env: tree.env, runner: StubRunner()).restore(backupDirectory: dir)
        XCTAssertEqual(res.okCount, 2)
        XCTAssertEqual(tree.read("\(h)/dotfiles/zshrc"), original)
        XCTAssertTrue(FileProbe.isSymlink(tree.phys(zshrc)))
    }

    func testEnvLineCommentsOnlyExactLines() throws {
        let tree = FakeTree()
        let rc = "\(tree.homePath)/.zprofile"
        tree.write(rc, "export JAVA_HOME=\"/x\"\n  export JAVA_HOME=\"/x\"\nexport JAVA_HOME=\"/x\" # c\n")
        let line = "export JAVA_HOME=\"/x\""
        let f = Finding(category: .envVar, severity: .high, name: "JAVA_HOME", target: "/x",
                        reason: .envVarDead(name: "JAVA_HOME", file: rc), action: .envLine(file: rc, line: line))
        let r = Remover(env: tree.env, runner: StubRunner(), trasher: tree.trasher)
        let s = try session(tree.env)
        XCTAssertEqual(r.removeOne(f, session: s), .done)
        XCTAssertEqual(tree.read(rc),
                       "\(ConfigFileEditor.disabledMarker)\(line)\n  export JAVA_HOME=\"/x\"\nexport JAVA_HOME=\"/x\" # c\n")
        XCTAssertEqual(s.entries.first?.extra, nil)
        // Chạy lại: không còn dòng nào khớp → báo rõ chứ không giả vờ OK
        XCTAssertEqual(r.removeOne(f, session: s), .failed(.lineNotFound(file: rc)))
    }

    func testRestoreDetectsConfigEditedAfterCleanup() throws {
        let tree = FakeTree()
        let rc = "\(tree.homePath)/.zshrc"
        tree.write(rc, "export X_HOME=/nope\n")
        let f = Finding(category: .envVar, severity: .high, name: "X_HOME", target: "/nope",
                        reason: .envVarDead(name: "X_HOME", file: rc), action: .envLine(file: rc, line: "export X_HOME=/nope"))
        let report = Remover(env: tree.env, runner: StubRunner(), trasher: tree.trasher).removeSelected([f], appVersion: "t")
        let dir = try XCTUnwrap(report.backupDirectory)
        tree.write(rc, "người dùng sửa thêm\n")
        let restorer = Restorer(env: tree.env, runner: StubRunner())
        XCTAssertEqual(restorer.restore(backupDirectory: dir).results.first?.status, .manual(.modifiedSinceCleanup))
        XCTAssertEqual(tree.read(rc), "người dùng sửa thêm\n")
        XCTAssertEqual(restorer.restore(backupDirectory: dir, overwriteModifiedFiles: true).okCount, 1)
        XCTAssertEqual(tree.read(rc), "export X_HOME=/nope\n")
    }

    /// Ghi đè chỉ các entry được chọn: mục đã khôi phục trước đó không bị chạy lại (không mất sửa đổi sau đó).
    func testRestoreOnlySelectedEntries() throws {
        let tree = FakeTree()
        let a = "\(tree.homePath)/.zshrc", b = "\(tree.homePath)/.zprofile"
        tree.write(a, "export A_HOME=/nope\n")
        tree.write(b, "export B_HOME=/nope\n")
        let fa = Finding(category: .envVar, severity: .high, name: "A_HOME", target: "/nope",
                         reason: .envVarDead(name: "A_HOME", file: a), action: .envLine(file: a, line: "export A_HOME=/nope"))
        let fb = Finding(category: .envVar, severity: .high, name: "B_HOME", target: "/nope",
                         reason: .envVarDead(name: "B_HOME", file: b), action: .envLine(file: b, line: "export B_HOME=/nope"))
        let report = Remover(env: tree.env, runner: StubRunner(), trasher: tree.trasher).removeSelected([fa, fb], appVersion: "t")
        let dir = try XCTUnwrap(report.backupDirectory)
        tree.write(b, "người dùng sửa b\n")
        let restorer = Restorer(env: tree.env, runner: StubRunner())
        let first = restorer.restore(backupDirectory: dir)
        XCTAssertEqual(first.results.map(\.index), [0, 1])
        XCTAssertEqual(first.results.map(\.status), [.restored, .manual(.modifiedSinceCleanup)])
        // người dùng sửa a sau khi khôi phục; ghi đè chỉ entry 1 không được đụng tới a
        tree.write(a, "sửa sau khôi phục\n")
        let second = restorer.restore(backupDirectory: dir, overwriteModifiedFiles: true, onlyEntries: [1])
        XCTAssertEqual(second.results.map(\.index), [1])
        XCTAssertEqual(second.results.map(\.status), [.restored])
        XCTAssertEqual(tree.read(a), "sửa sau khôi phục\n")
        XCTAssertEqual(tree.read(b), "export B_HOME=/nope\n")
    }

    // MARK: LaunchdJob

    func testLaunchdJobRoundTrip() throws {
        let tree = FakeTree()
        let plist = "\(tree.homePath)/Library/LaunchAgents/com.gone.agent.plist"
        tree.plist(plist, ["Label": "com.gone.agent", "Program": "/Applications/Gone.app/Contents/MacOS/agent"])
        let runner = StubRunner()
        runner.set("\(Tool.launchctl) print gui/501/com.gone.agent", stdout: "gui/501/com.gone.agent = {\n\tpath = \(tree.phys(plist))\n}\n")
        let f = Finding(category: .launchAgent, severity: .high, name: "com.gone.agent", target: plist,
                        reason: .missingProgram("/Applications/Gone.app/Contents/MacOS/agent"),
                        action: .launchdJob(plist: plist, label: "com.gone.agent", domain: "gui/501"))
        let report = Remover(env: tree.env, runner: runner, trasher: tree.trasher).removeSelected([f], appVersion: "t")
        XCTAssertEqual(report.results.map(\.outcome), [.done])
        XCTAssertTrue(runner.called("\(Tool.launchctl) bootout gui/501/com.gone.agent"))
        XCTAssertFalse(tree.exists(plist))
        XCTAssertTrue(FileProbe.isRegularFile(tree.trashDir.path + "/com.gone.agent.plist"))
        let dir = try XCTUnwrap(report.backupDirectory)
        let e = try XCTUnwrap(Restorer.loadEntries(directory: dir)?.first)
        XCTAssertEqual(e.extra, "gui/501/com.gone.agent")
        XCTAssertNotNil(e.backupRel)

        let res = Restorer(env: tree.env, runner: runner).restore(backupDirectory: dir)
        XCTAssertEqual(res.okCount, 1)
        XCTAssertEqual(tree.env.plistString(plist, "Label"), "com.gone.agent")
        XCTAssertTrue(runner.called("\(Tool.launchctl) bootstrap gui/501 \(tree.phys(plist))"))
    }

    // MARK: needsAdmin

    func testNeedsAdmin() throws {
        try XCTSkipIf(getuid() == 0, "root bỏ qua quyền thư mục")
        let tree = FakeTree()
        tree.write("/Library/Locked/item/f")
        chmod(tree.phys("/Library/Locked"), 0o555)
        defer { chmod(tree.phys("/Library/Locked"), 0o755) }
        let r = Remover(env: tree.env, runner: StubRunner(), trasher: tree.trasher)
        let locked = finding(.appSupport, .high, "item", target: "/Library/Locked/item",
                             action: .trashPath(path: "/Library/Locked/item"))
        XCTAssertTrue(r.needsAdmin(locked))
        XCTAssertEqual(r.adminCommand(for: locked),
                       "sudo mv -n '/Library/Locked/item' '/Users/tester/.Trash/item' && sudo chown -R 'tester' '/Users/tester/.Trash/item'")
        XCTAssertTrue(r.needsAdmin(finding(.receipt, .medium, "p", action: .pkgReceipt(id: "com.x.pkg"))))
        XCTAssertEqual(r.adminCommand(for: finding(.receipt, .medium, "p", action: .pkgReceipt(id: "it's"))),
                       "sudo pkgutil --forget 'it'\\''s'")
        XCTAssertTrue(r.needsAdmin(finding(.firewall, .medium, "f", target: "/x", action: .firewallApp(path: "/x"))))
        XCTAssertFalse(r.needsAdmin(finding(.caches, .info, "n", target: "/Library/Locked/item")))   // ReportOnly
        XCTAssertFalse(r.needsAdmin(finding(.tcc, .medium, "c", target: "Camera", action: .tccReset(service: "Camera", client: "c"))))
        let free = "\(tree.homePath)/Library/Caches/x"
        tree.mkdir(free)
        XCTAssertFalse(r.needsAdmin(finding(.caches, .high, "x", target: free, action: .trashPath(path: free))))

        // removeSelected không chạy mục cần admin; PkgReceipt không bao giờ thực thi ở P0
        let report = r.removeSelected([locked, finding(.receipt, .medium, "p", action: .pkgReceipt(id: "com.x.pkg"))],
                                      appVersion: "t")
        XCTAssertEqual(report.needsAdminCount, 2)
        XCTAssertTrue(tree.exists("/Library/Locked/item/f"))
    }

    // MARK: removeSelected

    func testRemoveSelectedPrunesDescendantsAndCounts() throws {
        let tree = FakeTree()
        let h = tree.homePath
        let parent = "\(h)/Library/Containers/com.docker.docker"
        let child = parent + "/Data"
        tree.write(child + "/f")
        let other = "\(h)/Library/Caches/com.gone"
        tree.mkdir(other)
        let fs = [
            finding(.containers, .high, "child", target: child, action: .trashPath(path: child)),
            finding(.docker, .high, "com.docker.docker", target: parent, action: .trashPath(path: parent)),
            finding(.containers, .high, "com.docker.docker", target: parent, action: .trashPath(path: parent)),
            finding(.caches, .info, "note", target: "x"),
            finding(.caches, .high, "com.gone", target: other, action: .trashPath(path: other)),
            finding(.caches, .high, "lib", target: "/Library", action: .trashPath(path: "/Library")),
        ]
        let report = Remover(env: tree.env, runner: StubRunner(), trasher: tree.trasher).removeSelected(fs, appVersion: "t")
        XCTAssertEqual(report.results.map(\.outcome), [
            .skipped(.coveredBy(target: parent)), .done, .skipped(.coveredBy(target: parent)),
            .skipped(.reportOnly), .done, .failed(.refused(.criticalSystemDir)),
        ])
        XCTAssertEqual(report.okCount, 2)
        XCTAssertEqual(report.failCount, 1)
        XCTAssertEqual(report.skippedCount, 3)
        XCTAssertEqual(report.sortedForDisplay.first?.name, "lib")
        XCTAssertTrue(FileProbe.isRegularFile(tree.trashDir.path + "/com.docker.docker/Data/f"))
        let dir = try XCTUnwrap(report.backupDirectory)
        XCTAssertEqual(Restorer.loadEntries(directory: dir)?.count, 2)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: dir.appendingPathComponent("restore.sh").path))
    }

    func testRemoveSelectedAlwaysWritesRestoreScriptAndStopsOnCancel() throws {
        let tree = FakeTree()
        let token = CancellationToken()
        token.cancel()
        let p = "\(tree.homePath)/Library/Caches/x"
        tree.mkdir(p)
        let report = Remover(env: tree.env, runner: StubRunner(), trasher: tree.trasher)
            .removeSelected([finding(.caches, .high, "x", target: p, action: .trashPath(path: p))],
                            appVersion: "t", cancellation: token)
        XCTAssertTrue(report.cancelled)
        XCTAssertEqual(report.results.first?.outcome, .skipped(.cancelled))
        XCTAssertTrue(tree.exists(p))
        let dir = try XCTUnwrap(report.backupDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("restore.sh").path))
    }

    /// Bảng kết quả xếp mục cần chú ý lên trước (fail, sudo, part, skip, ok), ổn định trong nhóm.
    func testResultsDisplayOrder() {
        func r(_ name: String, _ o: RemovalOutcome) -> RemovalResult {
            RemovalResult(findingID: name, category: .disk, name: name, target: "/tmp/\(name)", outcome: o)
        }
        let report = RemovalReport(backupDirectory: nil, results: [
            r("xong1", .done), r("hongA", .failed(.writeFailed(file: "f"))), r("xong2", .done),
            r("motphan", .partial(.emptiedKeptFolder)), r("sudo", .needsAdmin(command: "x")), r("skip", .skipped(.reportOnly)),
        ], sessionFailed: false, cancelled: false)
        XCTAssertEqual(report.sortedForDisplay.map(\.name), ["hongA", "sudo", "motphan", "skip", "xong1", "xong2"])
        XCTAssertEqual(report.okCount, 3)   // gồm cả partial
    }

    // MARK: Backup trùng giây, restore các nhánh làm tay

    func testBackupDirectoryCollisionGetsSuffix() throws {
        let tree = FakeTree()
        let a = try session(tree.env)
        a.record(ManifestEntry(kind: "Symlink", original: "/a", extra: "/b"))
        let b = try session(tree.env)
        XCTAssertNotEqual(a.directory, b.directory)
        XCTAssertEqual(b.directory.lastPathComponent, a.directory.lastPathComponent + "_2")
        XCTAssertEqual(Restorer.loadEntries(directory: a.directory)?.count, 1)   // manifest đầu còn nguyên
        let list = Restorer.listBackups(env: tree.env)
        XCTAssertEqual(list.map(\.name), [b.directory.lastPathComponent, a.directory.lastPathComponent])
        XCTAssertEqual(list.last?.entryCount, 1)
    }

    func testRestoreManualBranches() throws {
        let tree = FakeTree()
        let s = try session(tree.env)
        tree.mkdir("/exists")
        tree.write(tree.homePath + "/.Trash/old")
        s.record(ManifestEntry(kind: "TrashPath", original: "/exists", trashedPath: "/nowhere"))
        s.record(ManifestEntry(kind: "TrashPath", original: "/gone/item", trashedPath: "/nowhere/item"))
        s.record(ManifestEntry(kind: "TrashPath", original: "/legacy/old"))   // manifest cũ: tra theo tên
        s.record(ManifestEntry(kind: "PurgeAny", original: "/x", extra: "xóa vĩnh viễn"))
        s.record(ManifestEntry(kind: "PurgeTrash", original: "/y"))
        s.record(ManifestEntry(kind: "Symlink", original: "/exists", extra: "/d"))
        s.record(ManifestEntry(kind: "PkgReceipt", original: "com.x.pkg"))
        s.record(ManifestEntry(kind: "TccReset", original: "com.x", extra: "Camera"))
        s.record(ManifestEntry(kind: "LsRebuild", original: "LaunchServices"))
        let res = Restorer(env: tree.env, runner: StubRunner()).restore(backupDirectory: s.directory)
        XCTAssertEqual(res.results.map(\.status), [
            .manual(.alreadyExists), .manual(.notFoundInTrash), .restored, .manual(.permanentlyDeleted),
            .manual(.permanentlyDeleted), .manual(.alreadyExists), .manual(.receiptNotReloadable(id: "com.x.pkg")),
            .manual(.permissionAskedAgain(service: "Camera")), .manual(.notRestorable(kind: "LsRebuild")),
        ])
        XCTAssertTrue(tree.exists("/legacy/old"))
        XCTAssertEqual(res.okCount, 1)
        XCTAssertEqual(res.manualCount, 8)
    }

    func testRestoreFallsBackToTSVManifest() throws {
        let tree = FakeTree()
        let s = try session(tree.env)
        s.record(ManifestEntry(kind: "Symlink", original: "/sb/l", extra: "/khong/co"))
        try FileManager.default.removeItem(at: s.directory.appendingPathComponent("manifest.json"))
        tree.mkdir("/sb")
        let res = Restorer(env: tree.env, runner: StubRunner()).restore(backupDirectory: s.directory)
        XCTAssertTrue(res.manifestFound)
        XCTAssertEqual(res.okCount, 1)
        XCTAssertEqual(FileProbe.readlink(tree.phys("/sb/l")), "/khong/co")
        XCTAssertFalse(Restorer(env: tree.env, runner: StubRunner())
            .restore(backupDirectory: tree.root.appendingPathComponent("none")).manifestFound)
    }

    func testRestoreScriptEmbedsTrashedPaths() {
        let script = RestoreScript.render(entries: [
            ManifestEntry(kind: "TrashPath", original: "/a/it's", trashedPath: "/Users/x/.Trash/it's 2"),
        ])
        XCTAssertTrue(script.contains("TRASHED+=( '/a/it'\\''s' '/Users/x/.Trash/it'\\''s 2' )"))
        XCTAssertTrue(script.hasPrefix("#!/bin/zsh\n"))
        XCTAssertTrue(script.contains("while IFS=$'\\t' read -r kind orig rel extra; do"))
    }
}

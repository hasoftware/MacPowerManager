import Foundation
import XCTest
@testable import CleanCore

/// Runner giả theo hàm: quyết định kết quả từ lệnh + đối số (vd đọc file `zsh -n` được truyền vào).
final class ClosureRunner: CommandRunner, @unchecked Sendable {
    private let handler: @Sendable (String, [String]) -> CommandResult
    init(_ handler: @escaping @Sendable (String, [String]) -> CommandResult) { self.handler = handler }
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
        handler(executable, arguments)
    }
}

/// Đọc chữ ký giả theo đường dẫn vật lý.
struct FakeSigning: SigningInfoReader {
    let byPathSuffix: [String: SigningInfo]
    func signingInfo(atPath path: String) -> SigningInfo? {
        byPathSuffix.first { path.hasSuffix($0.key) }?.value
    }
}

/// Trasher luôn lỗi.
struct FailingTrasher: Trasher {
    struct Failure: Error {}
    func moveToTrash(_ item: URL) throws -> URL { throw Failure() }
}

/// Kiểm tra cú pháp bằng zsh thật (chỉ `-n`: phân tích, không chạy gì).
private func zshParses(_ text: String) throws -> Bool {
    let f = FileManager.default.temporaryDirectory.appendingPathComponent("zshn-\(UUID().uuidString)")
    try Data(text.utf8).write(to: f)
    defer { try? FileManager.default.removeItem(at: f) }
    return ProcessCommandRunner().run("/bin/zsh", ["-n", f.path], timeout: 10).succeeded
}

/// Hồi quy cho các phát hiện của vòng review P0.
final class ReviewRegressionTests: XCTestCase {
    private let home = "/Users/tester"

    private func pathFinding(_ rc: String, _ dir: String) -> Finding {
        Finding(category: .path, severity: .high, name: "PATH #1", target: dir, reason: .deadPathDir(source: rc),
                action: .pathEntry(file: rc, dir: dir))
    }

    private func removeOne(_ tree: FakeTree, _ f: Finding, runner: CommandRunner = StubRunner(),
                           trasher: Trasher? = nil) throws -> RemovalOutcome {
        let r = Remover(env: tree.env, runner: runner, trasher: trasher ?? tree.trasher)
        let s = try BackupSession(env: tree.env, appVersion: "t", macOSVersion: "15")
        return r.removeOne(f, session: s)
    }

    // MARK: 1. Sửa PATH trong file shell không được làm hỏng cú pháp

    func testPathEntryInsideIfBlockNeedsManualEditAndLeavesFileIntact() throws {
        let tree = FakeTree()
        let rc = "\(home)/.zshrc"
        let text = "if [[ -d /opt/dead/bin ]]; then\n  export PATH=/opt/dead/bin:$PATH\nfi\nalias ll='ls -l'\n"
        tree.write(rc, text)
        // Xác nhận lỗi: cách của MacTrash (comment mọi dòng chứa chuỗi con) làm zsh báo parse error
        let naive = TextLines(text).lines.map { $0.contains("/opt/dead/bin") ? ConfigFileEditor.disabledMarker + $0 : $0 }
        XCTAssertTrue(try zshParses(text))
        XCTAssertFalse(try zshParses(naive.joined(separator: "\n") + "\n"))

        XCTAssertEqual(try removeOne(tree, pathFinding(rc, "/opt/dead/bin")),
                       .failed(.manualEditRequired(file: rc)))
        XCTAssertEqual(tree.read(rc), text)
    }

    func testPathEntryContinuationAndMultiElementLinesNeedManualEdit() throws {
        let tree = FakeTree()
        let rc = "\(home)/.zshrc"
        let cont = "export PATH=\"/opt/dead/bin:\\\n/opt/homebrew/bin:$PATH\"\n"
        tree.write(rc, cont)
        XCTAssertEqual(try removeOne(tree, pathFinding(rc, "/opt/dead/bin")), .failed(.manualEditRequired(file: rc)))
        XCTAssertEqual(tree.read(rc), cont)

        let multi = "export PATH=/opt/dead/bin:/opt/homebrew/bin:$PATH\n"
        tree.write(rc, multi)
        XCTAssertEqual(try removeOne(tree, pathFinding(rc, "/opt/dead/bin")), .failed(.manualEditRequired(file: rc)))
        XCTAssertEqual(tree.read(rc), multi)
    }

    func testPathEntryCommentsOnlyWholeElementLines() throws {
        let tree = FakeTree()
        let rc = "\(home)/.zshrc"
        tree.write(rc, "source /opt/dead/bin2/init.sh\nexport PATH=\"/opt/dead/bin:$PATH\"\npath+=(/opt/dead/bin/)\n")
        XCTAssertEqual(try removeOne(tree, pathFinding(rc, "/opt/dead/bin")), .done)
        let m = ConfigFileEditor.disabledMarker
        XCTAssertEqual(tree.read(rc), "source /opt/dead/bin2/init.sh\n\(m)export PATH=\"/opt/dead/bin:$PATH\"\n"
                       + "\(m)path+=(/opt/dead/bin/)\n")
        XCTAssertTrue(try zshParses(tree.read(rc) ?? ""))
    }

    func testShellSyntaxCheckRejectsEditThatBreaksParsing() throws {
        let tree = FakeTree()
        let rc = "\(home)/.zshrc"
        let text = "export PATH=/opt/dead/bin:$PATH\n"
        tree.write(rc, text)
        // "zsh -n": nội dung cũ qua, nội dung mới (có dấu comment) không qua
        let runner = ClosureRunner { exe, args in
            guard exe == "/bin/zsh", args.first == "-n", let p = args.last,
                  let s = try? String(contentsOfFile: p, encoding: .utf8) else { return CommandResult(status: 1) }
            return CommandResult(status: s.contains(ConfigFileEditor.disabledMarker) ? 1 : 0)
        }
        XCTAssertEqual(try removeOne(tree, pathFinding(rc, "/opt/dead/bin"), runner: runner),
                       .failed(.wouldBreakShellSyntax(file: rc)))
        XCTAssertEqual(tree.read(rc), text)
        XCTAssertEqual(ConfigFileEditor.syntaxShell(for: "\(home)/.bash_profile"), "/bin/bash")
        XCTAssertEqual(ConfigFileEditor.syntaxShell(for: "\(home)/.zprofile"), "/bin/zsh")
    }

    // MARK: 2. Không xem được / ổ chưa mount ≠ không tồn tại

    func testExistenceDistinguishesPermissionDenied() throws {
        try XCTSkipIf(getuid() == 0, "root đọc được mọi thư mục")
        let tree = FakeTree()
        tree.write("/locked/inner/prog")
        chmod(tree.phys("/locked"), 0o000)
        defer { chmod(tree.phys("/locked"), 0o755) }
        XCTAssertEqual(tree.env.existence("/locked/inner/prog"), .unknown)
        XCTAssertFalse(tree.env.exists("/locked/inner/prog"))   // `-e` cũ: nói "không có"
        XCTAssertEqual(tree.env.existence("/nope/prog"), .missing)
        XCTAssertEqual(tree.env.existence("/Volumes/Backup/bin/sync.sh"), .unknown)
        tree.mkdir("/Volumes/Data")
        XCTAssertEqual(tree.env.existence("/Volumes/Data/gone"), .missing)
    }

    func testLiveTargetsOnUnreadableOrUnmountedPathsAreNotFlagged() throws {
        try XCTSkipIf(getuid() == 0, "root đọc được mọi thư mục")
        let tree = FakeTree()
        let la = "\(home)/Library/LaunchAgents"
        tree.plist("\(la)/com.me.backup.plist", ["Label": "com.me.backup", "Program": "/Volumes/Backup/bin/sync.sh"])
        tree.write("\(home)/Documents/scripts/run.sh")
        tree.plist("\(la)/com.me.docs.plist", ["Label": "com.me.docs", "Program": "\(home)/Documents/scripts/run.sh"])
        tree.plist("\(la)/com.gone.plist", ["Label": "com.gone", "Program": "/opt/gone/agent"])
        chmod(tree.phys("\(home)/Documents"), 0o000)
        defer { chmod(tree.phys("\(home)/Documents"), 0o755) }
        let ctx = ScannersAFixture.context(tree)
        XCTAssertEqual(try LaunchdScanner().scan(ctx).map(\.name), ["com.gone"])

        // symlink trỏ sang ổ ngoài đang rút / thư mục không xem được
        tree.symlink("\(home)/bin/ext", to: "/Volumes/Backup/bin/tool")
        tree.symlink("\(home)/bin/doc", to: tree.phys("\(home)/Documents/scripts/run.sh"))
        tree.symlink("\(home)/bin/dead", to: tree.phys("/opt/gone/tool"))
        XCTAssertEqual(try SymlinkScanner().scan(ctx).map(\.name), ["dead"])

        // khai báo biến trỏ vào ổ chưa mount
        XCTAssertNil(EnvironmentScanner.deadDeclaration("export ANDROID_HOME=/Volumes/SDK/android", known: [],
                                                        env: tree.env))
        XCTAssertNotNil(EnvironmentScanner.deadDeclaration("export ANDROID_HOME=/opt/android", known: [], env: tree.env))
    }

    // MARK: 3. App Group / Team ID của app đang cài (Office)

    func testOfficeGroupContainersStayAliveViaEntitlements() throws {
        let tree = FakeTree()
        tree.makeApp("/Applications/Microsoft Word.app", bundleID: "com.microsoft.Word")
        let signing = FakeSigning(byPathSuffix: ["/Microsoft Word.app": SigningInfo(
            teamID: "UBF8T346G9", appGroups: ["UBF8T346G9.Office", "UBF8T346G9.OfficeOsfWebHost"])])
        let gc = "\(home)/Library/Group Containers"
        tree.writeBytes("\(gc)/UBF8T346G9.Office/x", count: 2_000_000)
        tree.mkdir("\(gc)/UBF8T346G9.OfficeOneDriveSyncIntegration")
        tree.mkdir("\(gc)/UBF8T346G9.com.microsoft.teams")

        // Xác nhận lỗi: không có thông tin chữ ký → Office bị báo mồ côi
        let bare = try AppIndex.build(env: tree.env, runner: StubRunner(), signing: NoSigningInfoReader())
        XCTAssertTrue(bare.orphanCheck(name: "UBF8T346G9.Office", path: "\(gc)/UBF8T346G9.Office").isOrphan)

        let idx = try AppIndex.build(env: tree.env, runner: StubRunner(), signing: signing)
        XCTAssertEqual(idx.orphanCheck(name: "UBF8T346G9.Office", path: "\(gc)/UBF8T346G9.Office"), .alive)
        XCTAssertEqual(idx.orphanCheck(name: "group.UBF8T346G9.OfficeOsfWebHost", path: "x"), .alive)
        // cùng Team ID, phần còn lại không phải bundle id → sống
        XCTAssertEqual(idx.orphanCheck(name: "UBF8T346G9.OfficeOneDriveSyncIntegration", path: "x"), .alive)
        // cùng Team ID nhưng là bundle id của app khác đã gỡ → vẫn xét bundle id
        XCTAssertTrue(idx.orphanCheck(name: "UBF8T346G9.com.vendorx.gone", path: "x").isOrphan)
        XCTAssertEqual(Names.teamIdentifier("group.UBF8T346G9.Office"), "UBF8T346G9")
        XCTAssertNil(Names.teamIdentifier("com.foo.bar"))
    }

    // MARK: 4. App ngoài thư mục tìm (Spotlight)

    func testAppOutsideSearchDirsFoundViaSpotlight() throws {
        let tree = FakeTree()
        tree.makeApp("/Volumes/Work/Apps/Affinity Photo 2.app", bundleID: "com.seriflabs.affinityphoto2")
        tree.makeApp("\(home)/.Trash/Trashed.app", bundleID: "com.trashed.app")
        let c = "\(home)/Library/Containers"
        tree.writeBytes("\(c)/com.seriflabs.affinityphoto2/Data/presets", count: 2_000_000)
        tree.writeBytes("\(c)/com.trashed.app/Data/x", count: 2_000_000)
        let idx = AppIndex(env: tree.env)

        // Xác nhận lỗi: không có Spotlight → container High
        let plain = ScannersAFixture.context(tree, index: idx)
        XCTAssertEqual(plain.reportOrphan(name: "com.seriflabs.affinityphoto2", path: "\(c)/com.seriflabs.affinityphoto2",
                                          category: .containers)?.severity, .high)

        let runner = StubRunner()
        runner.set("\(Tool.mdfind) -attr kMDItemCFBundleIdentifier \(BundleLocator.query)", stdout: """
            /Volumes/Work/Apps/Affinity Photo 2.app   kMDItemCFBundleIdentifier = com.seriflabs.affinityphoto2
            \(home)/.Trash/Trashed.app   kMDItemCFBundleIdentifier = com.trashed.app
            /Applications/Null.app   kMDItemCFBundleIdentifier = (null)

            """)
        let ctx = ScannersAFixture.context(tree, index: idx, runner: runner)
        XCTAssertNil(ctx.reportOrphan(name: "com.seriflabs.affinityphoto2", path: "\(c)/com.seriflabs.affinityphoto2",
                                      category: .containers))
        // app nằm trong Thùng rác không tính là đang cài
        XCTAssertNotNil(ctx.reportOrphan(name: "com.trashed.app", path: "\(c)/com.trashed.app", category: .containers))
        // mdfind chỉ chạy một lần mỗi lượt quét
        XCTAssertEqual(runner.calls.filter { $0.first == Tool.mdfind }.count, 1)
    }

    func testBareNameOfAppOutsideSearchDirsFoundViaSpotlight() throws {
        let tree = FakeTree()
        tree.makeApp("\(home)/Code/iBack/build/iBack.app", bundleID: "com.example.iback")
        let dir = "\(home)/Library/Application Support/iBack"
        tree.writeBytes("\(dir)/state.json", count: 10)
        let idx = AppIndex(env: tree.env)
        XCTAssertNotNil(ScannersAFixture.context(tree, index: idx)
            .reportOrphan(name: "iBack", path: dir, category: .appSupport))

        let runner = StubRunner()
        runner.set("\(Tool.mdfind) -attr kMDItemCFBundleIdentifier \(BundleLocator.query)", stdout: """
            \(home)/Code/iBack/build/iBack.app   kMDItemCFBundleIdentifier = com.example.iback

            """)
        let ctx = ScannersAFixture.context(tree, index: idx, runner: runner)
        XCTAssertNil(ctx.reportOrphan(name: "iBack", path: dir, category: .appSupport))
    }

    func testLiveFSFolderIsSystemKeep() {
        XCTAssertTrue(Names.systemKeep.contains(Names.norm("livefsd")))
    }

    // MARK: 5. Dữ liệu của chính app

    func testOwnDataFolderAndPrefsAreNeverReportedOrTrashed() throws {
        let tree = FakeTree()
        let asup = "\(home)/Library/Application Support"
        let own = "\(asup)/MacPowerManager"
        tree.write("\(own)/Cleanup/20260101_000000/manifest.json", "{}")
        tree.write("\(own)/Cleanup/ignore.txt", "")
        tree.mkdir("\(asup)/GoneVendorThing")
        tree.write("\(home)/Library/Preferences/com.hasoftware.MacPowerManager.plist", "x")
        XCTAssertEqual(tree.env.dataDirPath, "\(own)/Cleanup")

        // Xác nhận lỗi: chỉ mục không biết app (không nằm trong /Applications) → tên trần "mồ côi"
        XCTAssertTrue(AppIndex(env: tree.env).orphanCheck(name: "MacPowerManager", path: own).isOrphan)

        let idx = try AppIndex.build(env: tree.env, runner: StubRunner(), signing: NoSigningInfoReader())
        let ctx = ScannersAFixture.context(tree, index: idx)
        XCTAssertEqual(try AppSupportScanner().scan(ctx).map(\.name), ["GoneVendorThing"])
        XCTAssertEqual(try PreferencesScanner().scan(ctx), [])

        // chốt cuối ở Remover: kể cả finding do nơi khác tạo ra
        for p in [own, "\(own)/Cleanup", "\(own)/Cleanup/20260101_000000"] {
            XCTAssertEqual(tree.env.deletionRefusal(for: p), .ownAppData)
            let f = finding(.appSupport, .info, "x", target: p, action: .trashPath(path: p))
            XCTAssertEqual(try removeOne(tree, f), .failed(.refused(.ownAppData)))
        }
        XCTAssertTrue(tree.exists("\(own)/Cleanup/20260101_000000/manifest.json"))
        XCTAssertNil(tree.env.deletionRefusal(for: "\(asup)/GoneVendorThing"))
    }

    // MARK: 6. Quick Action của người dùng

    func testUserWorkflowsAreNotPluginOrphans() throws {
        let tree = FakeTree()
        let svc = "\(home)/Library/Services"
        tree.plist("\(svc)/Resize Images.workflow/Contents/Info.plist", ["NSServices": [["NSMenuItem": ["default": "Resize"]]]])
        tree.plist("\(svc)/Gone.service/Contents/Info.plist", ["CFBundleIdentifier": "com.vendorgone.service"])
        let fs = try PluginScanner().scan(ScannersAFixture.context(tree))
        XCTAssertEqual(fs.map(\.name), ["Gone.service"])
    }

    // MARK: 7. restore.sh không ghi đè thứ đã đổi sau lần dọn

    func testRestoreScriptSkipsModifiedRcFilesAndReinstalledPlists() throws {
        let tmp = PathResolver.resolve(FileManager.default.temporaryDirectory
            .appendingPathComponent("CleanCoreRestoreSh-\(UUID().uuidString)").path)
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let h = tmp + "/home"
        // root "/" + home trong thư mục tạm: đường dẫn logic = vật lý, restore.sh chạy thật được mà chỉ chạm thư mục tạm
        let env = ScanEnvironment(homePath: h, uid: getuid(), userName: NSUserName(), searchPath: [],
                                  dataDir: URL(fileURLWithPath: tmp + "/data"))
        let fm = FileManager.default
        try fm.createDirectory(atPath: h + "/Library/LaunchAgents", withIntermediateDirectories: true)
        try Data("export X_HOME=/nope\n".utf8).write(to: URL(fileURLWithPath: h + "/.zshrc"))
        try Data("export Y_HOME=/nope\n".utf8).write(to: URL(fileURLWithPath: h + "/.zprofile"))
        let plist = h + "/Library/LaunchAgents/com.gone.agent.plist"
        try Data("old".utf8).write(to: URL(fileURLWithPath: plist))
        let fs = [
            Finding(category: .envVar, severity: .high, name: "X_HOME", target: "/nope",
                    reason: .envVarDead(name: "X_HOME", file: h + "/.zshrc"),
                    action: .envLine(file: h + "/.zshrc", line: "export X_HOME=/nope")),
            Finding(category: .envVar, severity: .high, name: "Y_HOME", target: "/nope",
                    reason: .envVarDead(name: "Y_HOME", file: h + "/.zprofile"),
                    action: .envLine(file: h + "/.zprofile", line: "export Y_HOME=/nope")),
            Finding(category: .launchAgent, severity: .high, name: "com.gone.agent", target: plist,
                    reason: .missingProgram("/x"), action: .launchdJob(plist: plist, label: "com.gone.agent", domain: "gui/1")),
        ]
        let report = Remover(env: env, runner: StubRunner(), trasher: DirectoryTrasher(trashDir: URL(fileURLWithPath: tmp + "/trash")))
            .removeSelected(fs, appVersion: "t")
        XCTAssertEqual(report.results.map(\.outcome), [.done, .done, .done])
        let dir = try XCTUnwrap(report.backupDirectory)
        // sau lần dọn: người dùng sửa .zshrc, nhà cung cấp cài lại plist
        try Data("người dùng sửa thêm\n".utf8).write(to: URL(fileURLWithPath: h + "/.zshrc"))
        try Data("reinstalled".utf8).write(to: URL(fileURLWithPath: plist))

        let r = ProcessCommandRunner(environment: ["HOME": h, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
            .run("/bin/zsh", [dir.appendingPathComponent(BackupSession.restoreScriptName).path], timeout: 30)
        XCTAssertTrue(r.succeeded, r.stdout + r.stderr)
        XCTAssertEqual(try String(contentsOfFile: h + "/.zshrc", encoding: .utf8), "người dùng sửa thêm\n")
        XCTAssertEqual(try String(contentsOfFile: plist, encoding: .utf8), "reinstalled")
        // file không bị sửa thêm thì vẫn khôi phục
        XCTAssertEqual(try String(contentsOfFile: h + "/.zprofile", encoding: .utf8), "export Y_HOME=/nope\n")
        XCTAssertTrue(r.stdout.contains("Xong: 1 khôi phục, 0 lỗi, 2 cần làm tay."), r.stdout)
    }

    // MARK: 8. Khôi phục từ Thùng rác: tên bị dùng lại

    func testRestoreRefusesTrashNameReusedByAnotherItem() throws {
        let tree = FakeTree()
        let p = "\(home)/Library/Preferences/com.foo.plist"
        tree.write(p, "của app")
        let f = finding(.prefs, .high, "com.foo", target: p, action: .trashPath(path: p))
        let report = Remover(env: tree.env, runner: StubRunner(), trasher: tree.trasher).removeSelected([f], appVersion: "t")
        let dir = try XCTUnwrap(report.backupDirectory)
        let e = try XCTUnwrap(Restorer.loadEntries(directory: dir)?.first)
        XCTAssertNotNil(e.trashedInode)
        // đổ Thùng rác rồi bỏ vào một file KHÁC cùng tên
        let trashed = tree.trashDir.path + "/com.foo.plist"
        try FileManager.default.removeItem(atPath: trashed)
        FileManager.default.createFile(atPath: trashed, contents: Data("file khác".utf8))
        let res = Restorer(env: tree.env, runner: StubRunner()).restore(backupDirectory: dir)
        XCTAssertEqual(res.results.first?.status, .manual(.trashItemReplaced))
        XCTAssertFalse(tree.exists(p))
        XCTAssertTrue(FileProbe.lexists(trashed))
    }

    // MARK: 9. Ghi file cấu hình giữ hardlink và xattr

    func testConfigRewriteKeepsHardLinkAndXattrs() throws {
        let tree = FakeTree()
        let rc = tree.write("\(home)/.zshrc", "export X_HOME=/nope\n")
        let repo = tree.phys("\(home)/dotfiles/zshrc")
        tree.mkdir("\(home)/dotfiles")
        XCTAssertEqual(link(tree.phys(rc), repo), 0)
        let f = Finding(category: .envVar, severity: .high, name: "X_HOME", target: "/nope",
                        reason: .envVarDead(name: "X_HOME", file: rc), action: .envLine(file: rc, line: "export X_HOME=/nope"))
        XCTAssertEqual(try removeOne(tree, f), .done)
        XCTAssertEqual(try String(contentsOfFile: repo, encoding: .utf8),
                       ConfigFileEditor.disabledMarker + "export X_HOME=/nope\n")

        let single = tree.write("\(home)/.zprofile", "a\n")
        let attr = "com.example.tag"
        XCTAssertEqual(setxattr(tree.phys(single), attr, "v", 1, 0, 0), 0)
        XCTAssertEqual(ConfigFileEditor.rewrite(tree.phys(single), transform: { _ in ["b"] }), .changed)
        XCTAssertEqual(tree.read(single), "b\n")
        XCTAssertEqual(getxattr(tree.phys(single), attr, nil, 0, 0, 0), 1)
    }

    // MARK: 10. LaunchdJob: trash trước, bootout chỉ khi job nạp từ đúng plist

    func testLaunchdJobBootoutOnlyWhenLoadedFromThisPlistAndAfterTrash() throws {
        let tree = FakeTree()
        let plist = "\(home)/Library/LaunchAgents/com.foo.agent.plist"
        tree.plist(plist, ["Label": "com.foo.agent", "Program": "/gone"])
        let f = Finding(category: .launchAgent, severity: .high, name: "com.foo.agent", target: plist,
                        reason: .missingProgram("/gone"),
                        action: .launchdJob(plist: plist, label: "com.foo.agent", domain: "gui/501"))
        let runner = StubRunner()
        // nhãn đang nạp từ plist KHÁC (cùng Label ở /Library) → không bootout
        runner.set("\(Tool.launchctl) print gui/501/com.foo.agent",
                   stdout: "gui/501/com.foo.agent = {\n\tpath = /Library/LaunchAgents/com.foo.agent.plist\n}\n")
        // trash lỗi → không bootout, không gì thay đổi
        XCTAssertEqual(try removeOne(tree, f, runner: runner, trasher: FailingTrasher()), .failed(.plistTrashFailed))
        XCTAssertFalse(runner.calls.contains { $0.count > 1 && $0[1] == "bootout" })
        XCTAssertTrue(tree.exists(plist))

        XCTAssertEqual(try removeOne(tree, f, runner: runner), .done)
        XCTAssertFalse(tree.exists(plist))
        XCTAssertFalse(runner.calls.contains { $0.count > 1 && $0[1] == "bootout" })
    }

    // MARK: 11-12. purgeTree, lệnh quản trị

    func testPurgeTreeDoesNotFollowSymlinks() throws {
        let tree = FakeTree()
        tree.write("/outside/keep.txt", "giữ")
        tree.write("/victim/a/b/file", "x")
        tree.symlink("/victim/a/link", to: tree.phys("/outside"))
        Remover.purgeTree(tree.phys("/victim"))
        XCTAssertFalse(tree.exists("/victim"))
        XCTAssertEqual(tree.read("/outside/keep.txt"), "giữ")
    }

    func testAdminTrashCommandNeverOverwritesTrashedItem() throws {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let tree = FakeTree(now: try XCTUnwrap(f.date(from: "2026-10-16 14:05:09")))
        tree.write("\(home)/.Trash/com.google.keystone.agent.plist", "bản user đã gỡ")
        let plist = "/Library/LaunchAgents/com.google.keystone.agent.plist"
        let r = Remover(env: tree.env, runner: StubRunner(), trasher: tree.trasher)
        let cmd = r.adminCommand(for: Finding(category: .launchAgent, severity: .high, name: "k", target: plist,
                                              reason: .missingProgram("/x"),
                                              action: .launchdJob(plist: plist, label: "k", domain: "gui/501")))
        XCTAssertEqual(cmd, "sudo launchctl bootout gui/501/k; sudo mv -n '\(plist)' "
                       + "'\(home)/.Trash/com.google.keystone.agent.plist 140509' && sudo chown -R 'tester' "
                       + "'\(home)/.Trash/com.google.keystone.agent.plist 140509'")
    }

    // MARK: 13. Biên nhận chết không che tàn dư cùng vendor

    func testStaleReceiptDoesNotKeepVendorDataAlive() throws {
        let tree = FakeTree()
        tree.mkdir("\(home)/Library/Application Scripts/com.v.app")
        tree.mkdir("\(home)/Library/Application Scripts/4788TTJ39Y.com.v.app-group")
        let runner = StubRunner()
        runner.set("\(Tool.pkgutil) --pkgs", stdout: "com.v.app\n")
        runner.set("\(Tool.pkgutil) --files com.v.app", stdout: "Applications/V.app/Contents/Info.plist\n")
        let idx = try AppIndex.build(env: tree.env, runner: runner, signing: NoSigningInfoReader())
        let ctx = ScannersAFixture.context(tree, index: idx, runner: runner)
        XCTAssertEqual(try ReceiptsScanner().scan(ctx).map(\.id), ["Receipt|com.v.app|/var/db/receipts/com.v.app"])
        XCTAssertEqual(try LibraryMiscScanner().scan(ctx).map(\.name), ["4788TTJ39Y.com.v.app-group", "com.v.app"])
    }

    // MARK: 15. Kext do macOS cài

    func testAppleShippedKextIsNotReported() throws {
        let tree = FakeTree()
        for k in ["HighPointIOP", "GoneVendor"] {
            let p = "/Library/Extensions/\(k).kext"
            tree.plist("\(p)/Contents/Info.plist", ["CFBundleIdentifier": "com.\(k.lowercased())-tech.kext.\(k)"])
            tree.write("\(p)/Contents/MacOS/\(k)", "bin")
        }
        let runner = StubRunner()
        runner.set("\(Tool.pkgutil) --file-info /Library/Extensions/HighPointIOP.kext",
                   stdout: "volume: /\npath: /Library/Extensions/HighPointIOP.kext\n\npkgid: com.apple.files.data-template\n")
        let fs = try SystemExtensionScanner().scan(ScannersAFixture.context(tree, runner: runner))
        XCTAssertEqual(fs.map(\.name), ["GoneVendor.kext"])
    }

    // MARK: 16-17. Đọc output theo dòng, dừng sớm, hủy được

    func testRunHeadStopsProcessAfterMaxLines() {
        let start = Date()
        let r = ProcessCommandRunner().runHead("/usr/bin/yes", [], maxLines: 40, timeout: 10)
        XCTAssertTrue(r.succeeded)
        XCTAssertEqual(r.lines.count, 40)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        // runner giả: cắt từ output đầy đủ
        let stub = StubRunner()
        stub.set("/x a", stdout: (1...50).map(String.init).joined(separator: "\n") + "\n")
        XCTAssertEqual(stub.runHead("/x", ["a"], maxLines: 3).lines, ["1", "2", "3"])
    }

    func testStreamLinesCancellationTerminatesProcess() {
        let token = CancellationToken()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { token.cancel() }
        let start = Date()
        let r = ProcessCommandRunner().streamLines("/bin/sleep", ["20"], timeout: 60, cancellation: token) { _ in true }
        XCTAssertTrue(r.cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertTrue(LaunchServicesScanner.isPathLine(ArraySlice(Array("\t  path:   /x (0x1)".utf8))))
        XCTAssertFalse(LaunchServicesScanner.isPathLine(ArraySlice(Array("name: path: /x".utf8))))
    }
}

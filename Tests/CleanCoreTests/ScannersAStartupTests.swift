import XCTest
@testable import CleanCore

/// Bộ quét khởi động / quyền root / gói / Docker: Launchd, LoginItems, Helpers, Receipts, Docker (spec A §3.8-3.13).
final class ScannersAStartupTests: XCTestCase {
    private typealias F = ScannersAFixture

    // MARK: Launchd

    func testLaunchdMissingProgramPerDirectoryAndDomain() throws {
        let tree = FakeTree()
        let ha = "\(tree.homePath)/Library/LaunchAgents"
        tree.plist("\(ha)/com.gone.agent.plist", ["Label": "com.gone.agent", "Program": "/Applications/Gone.app/run"])
        tree.plist("/Library/LaunchAgents/com.gone.sysagent.plist",
                   ["Label": "com.gone.sysagent", "ProgramArguments": ["/opt/gone/bin/agent", "--x"]])
        tree.plist("/Library/LaunchDaemons/com.gone.daemon.plist",
                   ["Label": "com.gone.daemon", "Program": "/Library/PrivilegedHelperTools/com.gone.daemon"])
        tree.plist("/Library/LaunchDaemons/com.alive.daemon.plist",
                   ["Label": "com.alive.daemon", "Program": "/usr/local/libexec/alive"])
        tree.write("/usr/local/libexec/alive")

        let fs = try LaunchdScanner().scan(F.context(tree))
        XCTAssertEqual(fs.map(\.name), ["com.gone.agent", "com.gone.sysagent", "com.gone.daemon"])
        XCTAssertTrue(fs.allSatisfy { $0.category == .launchAgent && $0.severity == .high && $0.sizeBytes == 0 })
        XCTAssertEqual(fs[0].action, .launchdJob(plist: "\(ha)/com.gone.agent.plist", label: "com.gone.agent", domain: "gui/501"))
        XCTAssertEqual(fs[1].action, .launchdJob(plist: "/Library/LaunchAgents/com.gone.sysagent.plist",
                                                 label: "com.gone.sysagent", domain: "gui/501"))
        XCTAssertEqual(fs[2].action, .launchdJob(plist: "/Library/LaunchDaemons/com.gone.daemon.plist",
                                                 label: "com.gone.daemon", domain: "system"))
        XCTAssertEqual(fs[1].reason, .missingProgram("/opt/gone/bin/agent"))
        XCTAssertEqual(fs[0].id, "LaunchAgent|com.gone.agent|/Users/tester/Library/LaunchAgents/com.gone.agent.plist")
    }

    func testLaunchdBareCommandsUseUserSearchPath() throws {
        let tree = FakeTree()
        tree.env.searchPath = ["/opt/homebrew/bin"]
        F.executable(tree, "/opt/homebrew/bin/redis-server")
        let ha = "\(tree.homePath)/Library/LaunchAgents"
        tree.plist("\(ha)/a.redis.plist", ["Label": "a.redis", "ProgramArguments": ["redis-server"]])
        tree.plist("\(ha)/b.gone.plist", ["Label": "b.gone", "ProgramArguments": ["gonetool", "run"]])
        tree.plist("\(ha)/c.builtin.plist", ["Label": "c.builtin", "Program": "echo"])
        tree.plist("\(ha)/d.tilde.plist", ["Label": "d.tilde", "Program": "~/bin/tool"])   // launchd không mở rộng ~

        let fs = try LaunchdScanner().scan(F.context(tree))
        XCTAssertEqual(fs.map(\.name), ["b.gone", "d.tilde"])
        XCTAssertEqual(fs.map(\.reason), [.missingProgram("gonetool"), .missingProgram("~/bin/tool")])
    }

    func testLaunchdRelativeProgramResolvesAgainstWorkingDirectory() throws {
        let tree = FakeTree()
        let ha = "\(tree.homePath)/Library/LaunchAgents"
        tree.write("/usr/libexec/tool")
        tree.write("/opt/app/bin/run")
        // Mặc định launchd chạy từ `/`, không phụ thuộc cwd của tiến trình quét
        tree.plist("\(ha)/r1.plist", ["Label": "r1", "Program": "usr/libexec/tool"])
        tree.plist("\(ha)/r2.plist", ["Label": "r2", "Program": "bin/run", "WorkingDirectory": "/opt/app"])
        tree.plist("\(ha)/r3.plist", ["Label": "r3", "Program": "bin/gone", "WorkingDirectory": "/opt/app"])

        let fs = try LaunchdScanner().scan(F.context(tree))
        XCTAssertEqual(fs.map(\.name), ["r3"])
    }

    func testLaunchdProgramPrecedenceLabelFallbackAndSkips() throws {
        let tree = FakeTree()
        let ha = "\(tree.homePath)/Library/LaunchAgents"
        tree.write("/bin/real")
        // Program thắng ProgramArguments[0], cả hai chiều
        tree.plist("\(ha)/p1.plist", ["Label": "p1", "Program": "/missing/prog", "ProgramArguments": ["/bin/real"]])
        tree.plist("\(ha)/p2.plist", ["Label": "p2", "Program": "/bin/real", "ProgramArguments": ["/missing/arg"]])
        // Program rỗng → dùng ProgramArguments[0]
        tree.plist("\(ha)/p3.plist", ["Label": "p3", "Program": "", "ProgramArguments": ["/missing/p3"]])
        // Không có Label → tên file
        tree.plist("\(ha)/com.nolabel.job.plist", ["Program": "/missing/nolabel"])
        tree.plist("\(ha)/emptylabel.plist", ["Label": "", "Program": "/missing/emptylabel"])
        // Không có chương trình (chỉ BundleProgram) → bỏ qua
        tree.plist("\(ha)/bundleprog.plist", ["Label": "bundleprog", "BundleProgram": "Contents/MacOS/x"])
        // plist hỏng → bỏ qua
        tree.write("\(ha)/broken.plist", "not a plist {")
        // symlink plist và file ẩn → bỏ qua
        tree.plist("/elsewhere/linked.plist", ["Label": "linked", "Program": "/missing/linked"])
        tree.symlink("\(ha)/linked.plist", to: tree.phys("/elsewhere/linked.plist"))
        tree.plist("\(ha)/.hidden.plist", ["Label": "hidden", "Program": "/missing/hidden"])
        // Sai đuôi → bỏ qua
        tree.plist("\(ha)/notplist.txt", ["Label": "txt", "Program": "/missing/txt"])
        // Chương trình là symlink gãy → coi như không tồn tại
        tree.symlink("/bin/dangling", to: tree.phys("/nowhere/target"))
        tree.plist("\(ha)/zz.dangling.plist", ["Label": "zz.dangling", "Program": "/bin/dangling"])

        let fs = try LaunchdScanner().scan(F.context(tree))
        XCTAssertEqual(fs.map(\.name), ["com.nolabel.job", "emptylabel", "p1", "p3", "zz.dangling"])
        XCTAssertEqual(fs.map(\.reason), [.missingProgram("/missing/nolabel"), .missingProgram("/missing/emptylabel"),
                                          .missingProgram("/missing/prog"), .missingProgram("/missing/p3"),
                                          .missingProgram("/bin/dangling")])
        XCTAssertEqual(fs[0].action, .launchdJob(plist: "\(ha)/com.nolabel.job.plist", label: "com.nolabel.job",
                                                 domain: "gui/501"))
    }

    func testLaunchdCancellation() {
        let tree = FakeTree()
        tree.plist("\(tree.homePath)/Library/LaunchAgents/a.plist", ["Program": "/missing"])
        let token = CancellationToken()
        token.cancel()
        XCTAssertThrowsError(try LaunchdScanner().scan(F.context(tree, cancellation: token))) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    // MARK: LoginItems

    func testLoginItemsNonRootReportsSingleInfo() throws {
        let tree = FakeTree()
        let runner = StubRunner()
        let fs = try LoginItemsScanner().scan(F.context(tree, runner: runner))
        XCTAssertEqual(fs.count, 1)
        XCTAssertEqual(fs[0].id, "LoginItem|Background Task Management|(sfltool dumpbtm)")
        XCTAssertEqual(fs[0].severity, .info)
        XCTAssertEqual(fs[0].reason, .needRootForBackgroundTasks)
        XCTAssertEqual(fs[0].action, .reportOnly)
        XCTAssertTrue(runner.calls.isEmpty)   // không gọi sfltool khi không phải root
    }

    /// Nhánh root (P5): `Developer Name:` không được ghi đè tên mục (sửa lỗi bản gốc).
    func testLoginItemsRootParsesDump() throws {
        let tree = FakeTree()
        tree.env.isRoot = true
        tree.write("/Applications/Alive.app/Contents/MacOS/Alive")
        let runner = StubRunner()
        runner.set("\(Tool.sfltool) dumpbtm", stdout: """
         #1:
                         UUID: 1234
                         Name: Gone Helper
               Developer Name: Gone Corp
              Executable Path: /Applications/Gone.app/Contents/MacOS/Gone
         #2:
                         Name: Alive
              Executable Path: /Applications/Alive.app/Contents/MacOS/Alive
         #3:
              Executable Path: /Library/Gone/noname
         #4:
                         Name: Relative
              Executable Path: relative/path
         #5:
                         Name: Empty
              Executable Path:\u{20}

        """)
        let fs = try LoginItemsScanner().scan(F.context(tree, runner: runner))
        XCTAssertEqual(fs.map(\.name), ["Gone Helper", "/Library/Gone/noname"])
        XCTAssertEqual(fs.map(\.target), ["/Applications/Gone.app/Contents/MacOS/Gone", "/Library/Gone/noname"])
        XCTAssertTrue(fs.allSatisfy { $0.severity == .medium && $0.reason == .loginItemDead && $0.action == .reportOnly })

        runner.set("\(Tool.sfltool) dumpbtm", CommandResult(status: 1))
        XCTAssertEqual(try LoginItemsScanner().scan(F.context(tree, runner: runner)), [])
    }

    // MARK: Helpers

    func testHelpersOrphanNoJobAndAlive() throws {
        let tree = FakeTree()
        let dir = "/Library/PrivilegedHelperTools"
        tree.writeBytes("\(dir)/com.gone.helper", count: 2 * F.mib)
        tree.write("\(dir)/com.tiny.gone.helper")                    // orphan rỗng vẫn High (không hạ mức)
        tree.write("\(dir)/com.alive.app.helper")                    // còn app, không có daemon plist
        tree.write("\(dir)/com.alive.app.daemon")                    // còn app, có daemon plist
        tree.write("/Library/LaunchDaemons/com.alive.app.daemon.plist")
        tree.write("\(dir)/com.gone.withjob")                        // mồ côi dù có plist → High
        tree.write("/Library/LaunchDaemons/com.gone.withjob.plist")
        tree.write("\(dir)/.hidden.gone")
        tree.mkdir("\(dir)/com.dirgone.tool")                        // mọi loại mục đều được xét
        var idx = AppIndex(env: tree.env)
        idx.registerBundle("com.alive.app", path: "/Applications/Alive.app")

        let fs = try HelpersScanner().scan(F.context(tree, index: idx))
        XCTAssertEqual(fs.map(\.name), ["com.alive.app.helper", "com.dirgone.tool", "com.gone.helper",
                                        "com.gone.withjob", "com.tiny.gone.helper"])
        XCTAssertEqual(fs.map(\.severity), [.medium, .high, .high, .high, .high])
        XCTAssertEqual(fs.map(\.reason), [.helperNoJob, .helperOrphan, .helperOrphan, .helperOrphan, .helperOrphan])
        XCTAssertGreaterThanOrEqual(fs[2].sizeMB, 2)
        XCTAssertEqual(fs[2].id, "Helper|com.gone.helper|/Library/PrivilegedHelperTools/com.gone.helper")
        XCTAssertEqual(fs[2].action, .trashPath(path: "\(dir)/com.gone.helper"))
        XCTAssertTrue(fs.allSatisfy { $0.category == .helper })
    }

    /// Thư mục helper thuộc root (giả lập bằng chmod 555) → cần quyền quản trị.
    func testHelperNeedsAdminWhenDirectoryNotWritable() throws {
        let tree = FakeTree()
        tree.write("/Library/PrivilegedHelperTools/com.gone.helper")
        _ = chmod(tree.phys("/Library/PrivilegedHelperTools"), 0o555)
        let fs = try HelpersScanner().scan(F.context(tree))
        XCTAssertEqual(fs.count, 1)
        XCTAssertTrue(Remover.needsAdmin(fs[0], env: tree.env))
    }

    // MARK: Receipts

    private func receiptsContext(_ tree: FakeTree, pkgs: [String], runner: StubRunner) throws -> ScanContext {
        runner.set("\(Tool.pkgutil) --pkgs", stdout: pkgs.joined(separator: "\n") + "\n")
        runner.set("\(Tool.launchctl) list", stdout: "")
        let idx = try AppIndex.build(env: tree.env, runner: runner)
        return F.context(tree, index: idx, runner: runner)
    }

    func testReceiptsFlagOnlyWhenNoFileRemains() throws {
        let tree = FakeTree()
        tree.makeApp("/Applications/Alive.app", bundleID: "com.alive.app")
        tree.write("/usr/local/bin/stillhere")
        tree.write("/Volumes/Data/opt/vol/tool")
        let runner = StubRunner()
        // Gói hết file: location rỗng, volume mặc định
        runner.set("\(Tool.pkgutil) --pkg-info com.gone.tool", stdout: "package-id: com.gone.tool\nvolume: /\nlocation: \n")
        runner.set("\(Tool.pkgutil) --files com.gone.tool", stdout: "usr/local/bin/gonetool\nusr/local/share/gone\n")
        // Gói còn file
        runner.set("\(Tool.pkgutil) --pkg-info com.still.here", stdout: "volume: /\nlocation: usr/local\n")
        runner.set("\(Tool.pkgutil) --files com.still.here", stdout: "\nbin/missing\nbin/stillhere\n")
        // volume khác `/` + location
        runner.set("\(Tool.pkgutil) --pkg-info com.vol.pkg", stdout: "volume: /Volumes/Data/\nlocation: opt\n")
        runner.set("\(Tool.pkgutil) --files com.vol.pkg", stdout: "vol/tool\n")
        let ctx = try receiptsContext(tree, pkgs: ["com.apple.pkg.Core", "com.gone.tool", "com.still.here",
                                                   "com.vol.pkg", "com.alive.app.helperpkg", ""], runner: runner)

        let fs = try ReceiptsScanner().scan(ctx)
        XCTAssertEqual(fs.map(\.name), ["com.gone.tool"])
        XCTAssertEqual(fs[0].id, "Receipt|com.gone.tool|/var/db/receipts/com.gone.tool")
        XCTAssertEqual(fs[0].severity, .medium)
        XCTAssertEqual(fs[0].reason, .receiptOrphan)
        XCTAssertEqual(fs[0].action, .pkgReceipt(id: "com.gone.tool"))
        XCTAssertTrue(Remover.needsAdmin(fs[0], env: tree.env))
        XCTAssertFalse(runner.called("\(Tool.pkgutil) --pkg-info com.apple.pkg.Core"))
        XCTAssertFalse(runner.called("\(Tool.pkgutil) --pkg-info com.alive.app.helperpkg"))   // còn app → không tra file
    }

    /// R2: id biên nhận không được tự làm mình "còn sống", và chỉ 40 dòng đầu của --files được xét.
    func testReceiptsIgnoreTheirOwnRegistrationAndProbeFirst40Files() throws {
        let tree = FakeTree()
        let runner = StubRunner()
        var many = (1...40).map { "missing/file\($0)" }
        many.append("usr/existing")                       // dòng 41: không xét
        tree.write("/usr/existing")
        runner.set("\(Tool.pkgutil) --files com.vendor.pkg.core", stdout: many.joined(separator: "\n") + "\n")
        // --files lỗi → coi như không còn file
        runner.set("\(Tool.pkgutil) --files gonepackage", CommandResult(status: 1))
        let ctx = try receiptsContext(tree, pkgs: ["com.vendor.pkg.core", "com.vendor.pkg.extra", "gonepackage"],
                                      runner: runner)
        // biên nhận chết KHÔNG được đăng ký làm bằng chứng (MacTrash coi là còn sống)
        XCTAssertFalse(ctx.index.bundleIDAlive("com.vendor.pkg.core"))
        XCTAssertEqual(ctx.index.staleReceiptIDs, ["com.vendor.pkg.core", "com.vendor.pkg.extra", "gonepackage"])

        let fs = try ReceiptsScanner().scan(ctx)
        XCTAssertEqual(fs.map(\.name), ["com.vendor.pkg.core", "com.vendor.pkg.extra", "gonepackage"])
    }

    func testReceiptsNameShapedIDUsesNameAliveness() throws {
        let tree = FakeTree()
        tree.makeApp("/Applications/Keeper.app", bundleID: "com.keeper.app")
        let runner = StubRunner()
        let ctx = try receiptsContext(tree, pkgs: ["Keeper", "Logic", "AppleSomething"], runner: runner)
        XCTAssertEqual(try ReceiptsScanner().scan(ctx), [])
    }

    // MARK: Docker

    private func dockerTree() -> FakeTree {
        let tree = FakeTree()
        let h = tree.homePath
        tree.writeBytes("\(h)/Library/Containers/com.docker.docker/Data/vms/disk.raw", count: 2 * F.mib)
        tree.mkdir("\(h)/Library/Group Containers/group.com.docker")
        tree.mkdir("\(h)/.docker")
        tree.write("/Library/PrivilegedHelperTools/com.docker.vmnetd")
        tree.write("/Library/LaunchDaemons/com.docker.vmnetd.plist")
        tree.symlink("\(h)/Library/Caches/com.docker.docker", to: tree.phys("/nowhere"))   // symlink gãy: bỏ
        return tree
    }

    func testDockerLeftoversWhenDesktopGone() throws {
        let tree = dockerTree()
        let fs = try DockerScanner().scan(F.context(tree))
        let h = tree.homePath
        XCTAssertEqual(fs.map(\.target), ["\(h)/Library/Containers/com.docker.docker",
                                          "\(h)/Library/Group Containers/group.com.docker",
                                          "\(h)/.docker",
                                          "/Library/PrivilegedHelperTools/com.docker.vmnetd",
                                          "/Library/LaunchDaemons/com.docker.vmnetd.plist"])
        XCTAssertEqual(fs.map(\.name), ["com.docker.docker", "group.com.docker", ".docker", "com.docker.vmnetd",
                                        "com.docker.vmnetd.plist"])
        XCTAssertTrue(fs.allSatisfy { $0.category == .docker && $0.severity == .high && $0.reason == .dockerGone })
        XCTAssertGreaterThanOrEqual(fs[0].sizeMB, 2)
        XCTAssertEqual(fs[2].id, "Docker|.docker|/Users/tester/.docker")
        XCTAssertEqual(fs[2].action, .trashPath(path: "\(h)/.docker"))
    }

    func testDockerSilentWhileDesktopOrCLIPresent() throws {
        let withApp = dockerTree()
        withApp.mkdir("/Applications/Docker.app")   // parity R9: mọi thư mục, kể cả vỏ rỗng
        XCTAssertEqual(try DockerScanner().scan(F.context(withApp)), [])

        let withCLI = dockerTree()
        withCLI.env.searchPath = ["/opt/homebrew/bin"]
        F.executable(withCLI, "/opt/homebrew/bin/docker")
        XCTAssertEqual(try DockerScanner().scan(F.context(withCLI)), [])
    }
}

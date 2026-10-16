import XCTest
@testable import CleanCore

/// Sắp xếp, danh sách bỏ qua, lịch sử quét, ScanEngine, dựng chỉ mục, orphan dùng chung.
final class EngineAndListsTests: XCTestCase {
    // MARK: Sắp xếp kết quả (port zsh)

    func testSortFindings() {
        let sorted = [
            finding(.caches, .info, "nho", mb: 5),
            finding(.caches, .high, "to", mb: 100),
            finding(.caches, .high, "rat_to", mb: 900),
            finding(.caches, .medium, "giua", mb: 50),
        ].sortedForReport()
        XCTAssertEqual(sorted.map(\.name), ["rat_to", "to", "giua", "nho"])
        // Cùng mức, cùng MB → giữ thứ tự chèn
        XCTAssertEqual([finding(.caches, .high, "a"), finding(.caches, .high, "b")].sortedForReport().map(\.name), ["a", "b"])
    }

    // MARK: Danh sách bỏ qua (port zsh)

    func testIgnoreList() throws {
        let tree = FakeTree()
        let list = IgnoreList(env: tree.env)
        let fs = [finding(.caches, .high, "giu"), finding(.caches, .high, "bo_di")]
        try list.add([fs[1].id])
        let (kept, n) = IgnoreList.apply(fs, ignoring: Set(list.load()))
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.name, "giu")
        XCTAssertEqual(n, 1)
        XCTAssertEqual(fs[1].id, "Caches|bo_di|t")
    }

    /// File ignore do MacTrash ghi (header tiếng Việt, dòng rỗng, CRLF) đọc được; ID trùng không ghi 2 lần.
    func testIgnoreListCompatibilityAndDedup() throws {
        let tree = FakeTree()
        let url = tree.root.appendingPathComponent("ignore.txt")
        try Data("# MacTrash - các mục đã ẩn vĩnh viễn (xóa dòng để hiện lại)\n\nCaches|a|/x\r\nPrefs|b|/y\n".utf8).write(to: url)
        let list = IgnoreList(url: url)
        XCTAssertEqual(list.load(), ["Caches|a|/x", "Prefs|b|/y"])
        try list.add(["Prefs|b|/y", "Path|PATH #3|/opt/x", "bad\nid"])
        XCTAssertEqual(list.load(), ["Caches|a|/x", "Prefs|b|/y", "Path|PATH #3|/opt/x"])
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix(IgnoreList.header + "\n"))
        try list.remove(["Caches|a|/x"])
        XCTAssertEqual(list.load(), ["Prefs|b|/y", "Path|PATH #3|/opt/x"])
        XCTAssertEqual(IgnoreList(url: tree.root.appendingPathComponent("none.txt")).load(), [])
    }

    // MARK: Lịch sử quét

    func testScanHistory() {
        let tree = FakeTree()
        let h = ScanHistory(env: tree.env)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(h.saveAndDiff(ids: ["A|a|1", "B|b|2"], now: t0), .firstScan)
        let d = h.saveAndDiff(ids: ["B|b|2", "C|c|3", "A|z|0"], now: t0)   // cùng giây → hậu tố, vẫn so với lần trước
        guard case .compared(let prevDate, let newCount, let goneCount, let newIDs)? = d else {
            return XCTFail("phải so được với lần trước")
        }
        XCTAssertFalse(prevDate.isEmpty)
        XCTAssertEqual(newCount, 2)
        XCTAssertEqual(goneCount, 1)
        XCTAssertEqual(newIDs, ["A|z|0", "C|c|3"])
        for i in 1...15 { h.saveAndDiff(ids: [], now: t0.addingTimeInterval(Double(i) * 60)) }
        XCTAssertEqual(h.files().count, ScanHistory.keep)
    }

    // MARK: ScanEngine

    func testEngineAppliesIgnoreSortsAndMarksAdmin() throws {
        let tree = FakeTree()
        try IgnoreList(env: tree.env).add(["Caches|an|t"])
        let scanners: [CleanScanner] = [
            StaticScanner(id: "A", findings: [finding(.caches, .info, "nho", mb: 1), finding(.caches, .high, "an")]),
            StaticScanner(id: "B", findings: [finding(.receipt, .medium, "pkg", target: "/var/db/receipts/x",
                                                      action: .pkgReceipt(id: "x")),
                                              finding(.caches, .high, "to", mb: 3)]),
        ]
        var phases: [ScanProgress.Phase] = []
        let engine = ScanEngine(env: tree.env, runner: StubRunner(), scanners: scanners)
        let result = try engine.run(progress: { phases.append($0.phase) })
        XCTAssertEqual(result.findings.map(\.name), ["to", "pkg", "nho"])
        XCTAssertEqual(result.ignoredCount, 1)
        XCTAssertEqual(result.findings.first { $0.name == "pkg" }?.needsAdmin, true)
        XCTAssertEqual(result.findings.first { $0.name == "nho" }?.needsAdmin, false)
        XCTAssertFalse(result.hasFullDiskAccess)
        XCTAssertEqual(phases, [.indexing, .scanning(scannerID: "A"), .scanning(scannerID: "B"), .finishing])
    }

    func testEngineCancellation() {
        let tree = FakeTree()
        let token = CancellationToken()
        let engine = ScanEngine(env: tree.env, runner: StubRunner(), scanners: [
            StaticScanner(id: "A", findings: [], cancelAfter: token),
            StaticScanner(id: "B", findings: []),
        ])
        XCTAssertThrowsError(try engine.run(cancellation: token)) { XCTAssertTrue($0 is CancellationError) }
    }

    func testDefaultScannersRegistered() {
        XCTAssertEqual(ScanEngine.defaultScanners.count, 22)
        XCTAssertEqual(Set(ScanEngine.defaultScanners.map(\.id)).count, 22)
    }

    func testFullDiskAccessProbe() {
        let tree = FakeTree()
        XCTAssertFalse(tree.env.hasFullDiskAccess())
        tree.write("\(tree.homePath)/Library/Application Support/com.apple.TCC/TCC.db", "SQLite format 3")
        XCTAssertTrue(tree.env.hasFullDiskAccess())
    }

    // MARK: Dựng chỉ mục

    func testBuildAppIndexSources() throws {
        let tree = FakeTree()
        tree.makeApp("/Users/Shared/Game.app", bundleID: "com.games.Game")
        tree.symlink("/Applications/Game.app", to: tree.phys("/Users/Shared/Game.app"))   // symlink .app được nhận
        tree.symlink("/Applications/Broken.app", to: tree.phys("/nowhere/Broken.app"))   // gãy → bỏ hẳn
        tree.makeApp("/Applications/Outer.app", bundleID: "com.x.Outer")
        tree.makeApp("/Applications/Outer.app/Contents/Helpers/Inner.app", bundleID: "com.y.Inner")   // không đi vào .app
        tree.makeApp("/Applications/a/b/c/Deep4.app", bundleID: "com.deep.Four")
        tree.makeApp("/Applications/a/b/c/d/Deep5.app", bundleID: "com.fifth.Five")   // độ sâu 5 → bỏ
        tree.makeApp("\(tree.homePath)/Applications/Mine.app", bundleID: "com.me.Mine")
        tree.mkdir("/opt/homebrew/Cellar/ripgrep")
        tree.plist("/Library/PreferencePanes/Foo.prefPane/Contents/Info.plist", ["CFBundleIdentifier": "com.foo.pane"])
        tree.write("/usr/libexec/stickersd", "bin")
        tree.write("/System/Library/LaunchDaemons/com.apple.wifid.plist", "x")
        tree.write("/bin/cargo", "#!/bin/sh")
        chmod(tree.phys("/bin/cargo"), 0o755)
        var env = tree.env
        env.searchPath = ["/bin"]
        let runner = StubRunner()
        runner.set("\(Tool.pkgutil) --pkgs", stdout: "com.vendor.pkg.core\n")
        // gói còn file → biên nhận còn sống, được đăng ký làm bằng chứng
        tree.write("/usr/local/vendor/core.dylib")
        runner.set("\(Tool.pkgutil) --files com.vendor.pkg.core", stdout: "usr/local/vendor/core.dylib\n")
        runner.set("\(Tool.launchctl) list", stdout: "PID\tStatus\tLabel\n-\t0\tcom.example.syncd\n")
        let idx = try AppIndex.build(env: env, runner: runner)

        XCTAssertTrue(idx.bundleIDAlive("com.games.Game"))
        XCTAssertTrue(idx.validApps.contains("/Applications/Game.app"))
        XCTAssertFalse(idx.validApps.contains("/Applications/Broken.app"))
        XCTAssertFalse(idx.deadApps.contains("/Applications/Broken.app"))
        XCTAssertTrue(idx.bundleIDAlive("com.x.Outer"))
        XCTAssertFalse(idx.bundleIDAlive("com.y.Inner"))
        XCTAssertTrue(idx.bundleIDAlive("com.deep.Four"))
        XCTAssertFalse(idx.bundleIDAlive("com.fifth.Five"))
        XCTAssertTrue(idx.bundleIDAlive("com.me.Mine"))
        XCTAssertTrue(idx.tokens.contains("ripgrep"))
        XCTAssertTrue(idx.bundleIDAlive("com.foo.pane"))
        XCTAssertTrue(idx.tokens.contains("foo"))
        XCTAssertTrue(idx.sysTokens.contains("stickersd"))
        XCTAssertTrue(idx.sysTokens.contains("wifid"))
        XCTAssertTrue(idx.sysTokens.contains("syncd"))
        XCTAssertTrue(idx.sysTokens.contains("label"))   // parity: dòng tiêu đề launchctl list
        // TOOLCHAIN: cargo có trong searchPath giả → org.rust sống; node không có → org.nodejs không
        XCTAssertTrue(idx.bundleIDAlive("org.rust.rustup"))
        XCTAssertFalse(idx.bundleIDAlive("org.nodejs.node"))
        // Nguồn pkgutil: sống theo mặc định, KHÔNG sống khi bỏ biên nhận (bộ quét Receipt, rủi ro R2)
        XCTAssertEqual(idx.packageReceiptIDs, ["com.vendor.pkg.core"])
        XCTAssertTrue(idx.bundleIDAlive("com.vendor.pkg.core"))
        XCTAssertFalse(idx.bundleIDAlive("com.vendor.pkg.core", includePackageReceipts: false))
        XCTAssertTrue(idx.commandExists("cargo"))
        XCTAssertTrue(idx.commandExists("echo"))     // builtin zsh
        XCTAssertFalse(idx.commandExists("node"))
    }

    // MARK: orphan dùng chung

    func testOrphanCheckVerdicts() {
        let tree = FakeTree()
        var idx = AppIndex(env: tree.env)
        idx.registerBundle("com.alive.app", path: "/Applications/Alive.app")
        let old = tree.mkdir("/sb/OldThing")
        tree.setModified(old, daysAgo: 100)
        let fresh = tree.mkdir("/sb/FreshThing")
        tree.setModified(fresh, daysAgo: 10)
        XCTAssertEqual(idx.orphanCheck(name: "com.gone.app", path: "/sb"), .orphan(.high, .orphanBundleID("com.gone.app")))
        XCTAssertEqual(idx.orphanCheck(name: "YHUG37CKN8.com.gone.app", path: "/sb"), .orphan(.high, .orphanBundleID("com.gone.app")))
        XCTAssertEqual(idx.orphanCheck(name: "OldThing", path: old), .orphan(.medium, .orphanName("OldThing", days: 100)))
        XCTAssertEqual(idx.orphanCheck(name: "FreshThing", path: fresh), .orphan(.info, .orphanName("FreshThing", days: 10)))
        XCTAssertEqual(idx.orphanCheck(name: "0A2F4E1B-363A-41F8-BFA9-7706E6A02950", path: "/sb"), .alive)
        XCTAssertEqual(idx.orphanCheck(name: ".foo", path: "/sb"), .alive)
        XCTAssertEqual(idx.orphanCheck(name: "YHUG37CKN8.com.apple.x", path: "/sb"), .alive)
        XCTAssertEqual(idx.orphanCheck(name: "com.alive.app.helper", path: "/sb"), .alive)
        XCTAssertEqual(idx.orphanCheck(name: "", path: "/sb"), .alive)
    }

    func testScanContainerAndReportOrphan() throws {
        let tree = FakeTree()
        let dir = "\(tree.homePath)/Library/Saved Application State"
        tree.writeBytes("\(dir)/com.big.gone.savedState/blob", count: 2 * 1_048_576 + 10)
        tree.mkdir("\(dir)/com.small.gone.savedState")
        tree.mkdir("\(dir)/com.apple.Safari.savedState")
        tree.mkdir("\(dir)/0A2F4E1B-363A-41F8-BFA9-7706E6A02950")
        tree.mkdir("\(dir)/.hidden.gone.app")
        tree.write("\(dir)/com.loose.file.json")
        tree.mkdir("/elsewhere/com.linked.gone")
        tree.symlink("\(dir)/com.linked.gone", to: tree.phys("/elsewhere/com.linked.gone"))
        let ctx = ScanContext(env: tree.env, index: AppIndex(env: tree.env), runner: StubRunner(), hasFullDiskAccess: false)
        let fs = try ctx.scanContainer(dir, category: .savedState, stripSuffix: ".savedState")
        XCTAssertEqual(fs.map(\.name), ["com.big.gone", "com.small.gone"])
        XCTAssertEqual(fs[0].severity, .high)
        XCTAssertGreaterThanOrEqual(fs[0].sizeMB, 2)
        XCTAssertEqual(fs[0].target, "\(dir)/com.big.gone.savedState")   // target logic, không mang root giả
        XCTAssertEqual(fs[0].id, "SavedState|com.big.gone|/Users/tester/Library/Saved Application State/com.big.gone.savedState")
        XCTAssertEqual(fs[0].action, .trashPath(path: "\(dir)/com.big.gone.savedState"))
        XCTAssertEqual(fs[1].severity, .medium)   // High dưới 1 MiB → Medium
        XCTAssertEqual(try ctx.scanContainer("/missing", category: .caches), [])
    }

    func testListingSemantics() {
        let tree = FakeTree()
        tree.mkdir("/d/realdir")
        tree.write("/d/b.plist")
        tree.write("/d/.hidden.plist")
        tree.symlink("/d/linkdir", to: tree.phys("/d/realdir"))
        tree.symlink("/d/a.plist", to: tree.phys("/d/b.plist"))
        tree.symlink("/d/dangling", to: "/nowhere")
        let env = tree.env
        XCTAssertEqual(env.list("/d"), ["/d/a.plist", "/d/b.plist", "/d/dangling", "/d/linkdir", "/d/realdir"])
        XCTAssertEqual(env.list("/d", .realDirectories), ["/d/realdir"])
        XCTAssertEqual(env.list("/d", .directories), ["/d/linkdir", "/d/realdir"])
        XCTAssertEqual(env.list("/d", .regularFiles, suffix: ".plist"), ["/d/b.plist"])
        XCTAssertEqual(env.list("/d", .symlinks), ["/d/a.plist", "/d/dangling", "/d/linkdir"])
        XCTAssertEqual(env.list("/d", .any, suffix: ".plist", includeHidden: true), ["/d/.hidden.plist", "/d/a.plist", "/d/b.plist"])
        XCTAssertFalse(env.exists("/d/dangling"))
        XCTAssertTrue(env.lexists("/d/dangling"))
        XCTAssertEqual(env.readlink("/d/dangling"), "/nowhere")
        XCTAssertEqual(env.list("/missing"), [])
    }

    func testLaunchdHelpers() {
        let tree = FakeTree()
        let a = tree.plist("/la/a.plist", ["Label": "com.a", "Program": "/p", "ProgramArguments": ["/q", "-x"]])
        let b = tree.plist("/la/com.b.plist", ["ProgramArguments": ["/q", "-x"]])
        let c = tree.plist("/la/c.plist", ["BundleProgram": "Contents/MacOS/x"])
        let env = tree.env
        XCTAssertEqual(env.launchdProgram(plist: a), "/p")           // Program thắng
        XCTAssertEqual(env.launchdProgram(plist: b), "/q")
        XCTAssertNil(env.launchdProgram(plist: c))                   // BundleProgram không được xét
        XCTAssertEqual(env.launchdLabel(plist: a), "com.a")
        XCTAssertEqual(env.launchdLabel(plist: b), "com.b")          // thiếu Label → tên file
        XCTAssertEqual(env.launchdDomain(forPlistIn: "/Library/LaunchDaemons"), "system")
        XCTAssertEqual(env.launchdDomain(forPlistIn: "/Library/LaunchAgents"), "gui/501")
        XCTAssertEqual(env.plistString(a, "ProgramArguments"), "2")  // raw: mảng → số phần tử
        XCTAssertEqual(env.plistString(a, "ProgramArguments.1"), "-x")
    }

    func testBundleBrokenExecutable() {
        let tree = FakeTree()
        tree.makeApp("/p/Ok.qlgenerator", bundleID: "com.ok", executable: "ok")
        tree.plist("/p/Rel.bundle/Contents/Info.plist", ["CFBundleExecutable": "Game/run"])
        tree.write("/p/Rel.bundle/Contents/Game/run")
        tree.makeApp("/p/Bad.plugin", bundleID: "com.bad", executable: "bad", withExecutable: false)
        tree.mkdir("/p/NoPlist.bundle/Contents")
        let env = tree.env
        XCTAssertNil(env.bundleBrokenExecutable("/p/Ok.qlgenerator"))
        XCTAssertNil(env.bundleBrokenExecutable("/p/Rel.bundle"))   // exe tương đối từ Contents/
        XCTAssertEqual(env.bundleBrokenExecutable("/p/Bad.plugin"), "bad")
        XCTAssertNil(env.bundleBrokenExecutable("/p/NoPlist.bundle"))
    }

    func testPathHelpersAndSourceFile() {
        let tree = FakeTree()
        tree.write("/etc/paths", "/usr/bin\n/bin\n")
        tree.write("/etc/paths.d/b", "/opt/dead\n")
        tree.write("/etc/paths.d/a", "/opt/dead\n")
        tree.write("\(tree.homePath)/.zshrc", "export PATH=/opt/other:$PATH\n")
        let env = tree.env
        XCTAssertEqual(ScanEnvironment.splitPATH("a::b:"), ["a", "", "b", ""])
        XCTAssertEqual(env.pathSourceFile(for: "/opt/dead"), "/etc/paths.d/a")   // thứ tự tên
        XCTAssertEqual(env.pathSourceFile(for: "/opt/other"), "\(tree.homePath)/.zshrc")
        XCTAssertEqual(env.pathSourceFile(for: "/usr/bin"), "/etc/paths")
        XCTAssertNil(env.pathSourceFile(for: "/nowhere"))
        XCTAssertEqual(env.userPATH, "/usr/bin:/bin:/opt/dead:/opt/dead")   // dự phòng /etc/paths*
        XCTAssertTrue(env.isUsingFallbackPATH)
        var e2 = env
        e2.shellEnvironment = ["PATH": ":/a::/b/"]
        XCTAssertEqual(e2.userPATH, ":/a::/b/")
        XCTAssertEqual(env.rcFiles.first, "/Users/tester/.zshrc")
        XCTAssertEqual(env.rcFiles.count, 12)
    }

    func testShellEnvironmentParse() {
        let out = "Welcome banner\n\n__MPM_ENV__\nPATH=/a:/b\0JAVA_HOME=/x=y\0EMPTY=\0junk\0"
        let env = ShellEnvironmentLoader.parse(out)
        XCTAssertEqual(env?["PATH"], "/a:/b")
        XCTAssertEqual(env?["JAVA_HOME"], "/x=y")
        XCTAssertEqual(env?["EMPTY"], "")
        XCTAssertNil(ShellEnvironmentLoader.parse("no marker"))

        let runner = StubRunner()
        runner.set("\(Tool.dscl) . -read /Users/tester UserShell", stdout: "UserShell: /bin/zsh\n")
        runner.set("/bin/zsh -i -l -c printf '\\n__MPM_ENV__\\n'; /usr/bin/env -0", stdout: out)
        XCTAssertEqual(ShellEnvironmentLoader.load(runner: runner, userName: "tester")?["PATH"], "/a:/b")
    }

    func testShellFreshEnvironmentDropsInheritedPATH() {
        let base = ["PATH": "/x/bin:/usr/bin", "LANG": "vi_VN.UTF-8", "XCODE_VERSION": "16", "HOME": "/wrong"]
        let env = ShellEnvironmentLoader.freshEnvironment(home: "/Users/tester", userName: "tester", base: base)
        XCTAssertEqual(env["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(env["HOME"], "/Users/tester")
        XCTAssertEqual(env["LOGNAME"], "tester")
        XCTAssertEqual(env["LANG"], "vi_VN.UTF-8")
        XCTAssertNil(env["XCODE_VERSION"])
    }

    func testSizeAndDays() {
        let tree = FakeTree()
        tree.writeBytes("/s/a", count: 3 * 1_048_576)
        tree.symlink("/s/link", to: tree.phys("/s/a"))
        let env = tree.env
        XCTAssertGreaterThanOrEqual(env.sizeBytes("/s"), 3 * 1_048_576)
        XCTAssertEqual(env.sizeBytes("/missing"), 0)
        XCTAssertLessThan(env.sizeBytes("/s/link"), 1_048_576)   // symlink: kích thước của link, không theo đích
        tree.setModified("/s/a", daysAgo: 30)
        XCTAssertEqual(env.daysSinceModified("/s/a"), 30)
        XCTAssertEqual(env.daysSinceModified("/missing"), 0)
    }

    func testTextLinesPreserveTrailingNewline() {
        XCTAssertEqual(TextLines("a\nb").lines, ["a", "b"])
        XCTAssertEqual(TextLines("a\nb").text, "a\nb")
        XCTAssertEqual(TextLines("a\nb\n").text, "a\nb\n")
        XCTAssertEqual(TextLines("a\r\nb\n").lines, ["a\r", "b"])
        XCTAssertEqual(TextLines("").lines, [])
    }

    func testFindingIDAndPayload() {
        let f = Finding(category: .launchAgent, severity: .high, name: "com.x", target: "/p.plist",
                        reason: .missingProgram("/x"), action: .launchdJob(plist: "/p.plist", label: "com.x", domain: "gui/501"))
        XCTAssertEqual(f.id, "LaunchAgent|com.x|/p.plist")
        XCTAssertEqual(f.kind, .launchdJob)
        XCTAssertEqual(f.action.zshData, "/p.plist\u{1f}com.x\u{1f}gui/501")
        XCTAssertEqual(Finding.makeID(category: .path, name: FindingLiteral.pathEntryName(3),
                                      target: FindingLiteral.emptyPathTarget), "Path|PATH #3|<rỗng>")
        XCTAssertEqual(CleanCategory.tcc.rawValue, "TCC")
        XCTAssertEqual(Remover.snapshotDate("com.apple.TimeMachine.2024-01-15-123456.local"), "2024-01-15-123456")
    }
}

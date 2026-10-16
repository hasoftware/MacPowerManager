import XCTest
@testable import CleanCore

/// Bộ quét nhóm B, phần hệ thống/shell/plugin: system extension + kext, symlink gãy, LaunchServices, native
/// messaging, plugin, vỏ `.app` rỗng. Cây giả + CommandRunner giả, không chạm hệ thống.
final class ScannersBSystemTests: XCTestCase {
    private func context(_ tree: FakeTree, index: AppIndex? = nil, runner: StubRunner = StubRunner(),
                         token: CancellationToken = CancellationToken()) -> ScanContext {
        ScanContext(env: tree.env, index: index ?? AppIndex(env: tree.env), runner: runner,
                    hasFullDiskAccess: false, cancellation: token)
    }

    private var home: String { "/Users/tester" }

    /// Chỉ mục có một vendor còn sống: com.alive.*
    private func aliveIndex(_ tree: FakeTree) -> AppIndex {
        var idx = AppIndex(env: tree.env)
        idx.registerBundle("com.alive.app", path: "/Applications/Alive.app")
        return idx
    }

    /// Bundle plugin/kext: `Contents/Info.plist` (nếu `bundleID` hoặc `executable` khác nil) + file thực thi.
    private func bundle(_ tree: FakeTree, _ path: String, bundleID: String?, executable: String? = "run",
                        createExecutable: Bool = true) {
        tree.mkdir(path + "/Contents/MacOS")
        var d: [String: Any] = [:]
        if let bundleID { d["CFBundleIdentifier"] = bundleID }
        if let executable { d["CFBundleExecutable"] = executable }
        if !d.isEmpty { tree.plist(path + "/Contents/Info.plist", d) }
        if createExecutable, let executable { tree.write(path + "/Contents/MacOS/" + executable, "bin") }
    }

    // MARK: scan_sysext

    func testStaleSystemExtensions() throws {
        let tree = FakeTree()
        let runner = StubRunner()
        let dead = "\t\tABCDE12345\tcom.dead.ext (2.0/3)\tDead Ext\t[terminated waiting to uninstall on reboot]"
        runner.set("\(Tool.systemextensionsctl) list", stdout: [
            "3 extension(s)",
            "--- com.apple.system_extension.network_extension",
            "enabled\tactive\tteamID\tbundleID (version)\tname\t[state]",
            "*\t*\tABCDE12345\tcom.good.ext (1.0/1)\tGood\t[activated enabled]",
            dead,
            "*\t\tXYZ\tcom.wait.ext (1.0/1)\tWait\t[activated waiting for user]",
            "short line [terminated]",
        ].joined(separator: "\n") + "\n")
        let fs = try SystemExtensionScanner().scan(context(tree, runner: runner))
        XCTAssertEqual(fs.map(\.name), ["com.dead.ext", "?"])
        // target là NGUYÊN dòng (gồm TAB và version)
        XCTAssertEqual(fs[0].target, dead)
        XCTAssertEqual(fs[0].reason, .sysExtStale(state: "terminated waiting to uninstall on reboot"))
        XCTAssertEqual(fs[0].severity, .medium)
        XCTAssertEqual(fs[0].kind, .reportOnly)
        XCTAssertEqual(fs[1].reason, .sysExtStale(state: "terminated"))
    }

    func testStateParsingUsesLastBrackets() {
        XCTAssertEqual(SystemExtensionScanner.state(ofLine: "a [x] b [terminated]"), "terminated")
        XCTAssertEqual(SystemExtensionScanner.state(ofLine: "a [x] b [y"), "y")
        XCTAssertNil(SystemExtensionScanner.state(ofLine: "a ] b ["))
        XCTAssertNil(SystemExtensionScanner.state(ofLine: "no brackets"))
    }

    func testOrphanKexts() throws {
        let tree = FakeTree()
        bundle(tree, "/Library/Extensions/Dead.kext", bundleID: "com.deadvendor.driver")       // mồ côi
        bundle(tree, "/Library/Extensions/Alive.kext", bundleID: "com.alive.driver")           // vendor còn sống
        bundle(tree, "/Library/Extensions/AppleThing.kext", bundleID: "com.apple.driver.X")    // Apple
        bundle(tree, "/Library/Extensions/EmptyBid.kext", bundleID: "")                        // bid rỗng → sống
        tree.mkdir("/Library/Extensions/NoPlistKext.kext/Contents/MacOS")                      // tên file làm bid
        tree.plist("/Library/Extensions/HighPointRR.kext/Contents/Info.plist",                 // kext rỗng của macOS
                   ["CFBundleIdentifier": "com.highpoint.rr"])
        tree.mkdir("/Library/Extensions/NotAKext")
        let fs = try SystemExtensionScanner().scan(context(tree, index: aliveIndex(tree)))
        XCTAssertEqual(fs.map(\.id), ["SysExt|Dead.kext|/Library/Extensions/Dead.kext",
                                      "SysExt|NoPlistKext.kext|/Library/Extensions/NoPlistKext.kext"])
        // mức cố định Medium, bỏ severity của classifier (bid rõ ràng → High ở orphan_check)
        XCTAssertTrue(fs.allSatisfy { $0.severity == .medium && $0.reason == .kextOrphan && $0.kind == .reportOnly })
        XCTAssertGreaterThan(fs[0].sizeBytes, 0)
    }

    // MARK: scan_symlinks

    func testBrokenSymlinks() throws {
        let tree = FakeTree()
        let bin = "\(home)/.local/bin"
        tree.write("\(bin)/real", "bin")
        tree.symlink("\(bin)/good", to: "real")
        tree.symlink("\(bin)/broken", to: "/khong/co/that")
        tree.symlink("\(bin)/chain", to: "broken")             // gãy ở giữa chuỗi
        tree.symlink("\(bin)/loopA", to: "loopB")              // vòng lặp
        tree.symlink("\(bin)/loopB", to: "loopA")
        tree.symlink("\(bin)/.hidden", to: "/khong/co/that")   // ẩn: bỏ
        tree.write("\(bin)/plain", "x")
        tree.symlink("\(bin)/sub/deep", to: "/khong/co/that")  // không đệ quy
        tree.symlink("/usr/local/bin/brewlink", to: "../Cellar/gone/bin/x")
        let fs = try SymlinkScanner().scan(context(tree))
        XCTAssertEqual(fs.map(\.id), [
            "Symlink|brewlink|/usr/local/bin/brewlink",
            "Symlink|broken|\(bin)/broken", "Symlink|chain|\(bin)/chain",
            "Symlink|loopA|\(bin)/loopA", "Symlink|loopB|\(bin)/loopB",
        ])
        XCTAssertEqual(fs[0].reason, .brokenSymlink(destination: "../Cellar/gone/bin/x"))
        XCTAssertEqual(fs[1].reason, .brokenSymlink(destination: "/khong/co/that"))
        XCTAssertEqual(fs[1].severity, .high)
        XCTAssertEqual(fs[1].action, .symlink(path: "\(bin)/broken"))
    }

    // MARK: scan_lsregister

    func testGhostLaunchServicesRecords() throws {
        let tree = FakeTree()
        tree.write(Tool.lsregister, "bin")
        _ = chmod(tree.phys(Tool.lsregister), 0o755)
        tree.mkdir("/Applications/Alive.app")
        let runner = StubRunner()
        runner.set("\(Tool.lsregister) -dump", stdout: [
            "--------------------------------------------------------------------------------",
            "bundle id:                  com.x (0x1234)",
            "path:                       /Applications/Alive.app (0x1a2b)",
            "    path:   /Applications/Gone.app (0x39b0)",
            "path: /Applications/Gone.app (0x39b0)",
            "\tpath:\t/Volumes/Ext/Old (beta).app (0x80f8)",
            "name: path: /Nope.app",
            "path: relative/x.app (0x1)",
        ].joined(separator: "\n") + "\n")
        let fs = try LaunchServicesScanner().scan(context(tree, runner: runner))
        XCTAssertEqual(fs.count, 1)
        // n = số dòng (không khử trùng), target = ma đầu tiên. /Volumes/Ext chưa mount: không phải bản ghi ma.
        XCTAssertEqual(fs[0].id, "LaunchServices|2 bản ghi ma|/Applications/Gone.app")
        XCTAssertEqual(fs[0].severity, .info)
        XCTAssertEqual(fs[0].reason, .ghostLaunchServices(count: 2))
        XCTAssertEqual(fs[0].action, .lsRebuild)
        XCTAssertFalse(Remover.needsAdmin(fs[0], env: tree.env))
    }

    func testLaunchServicesNoGhostsOrNoTool() throws {
        let tree = FakeTree()
        let runner = StubRunner()
        runner.set("\(Tool.lsregister) -dump", stdout: "path: /Applications/Gone.app (0x1)\n")
        // không có lsregister thực thi được → không chạy lệnh
        XCTAssertEqual(try LaunchServicesScanner().scan(context(tree, runner: runner)), [])
        XCTAssertTrue(runner.calls.isEmpty)

        tree.write(Tool.lsregister, "bin")
        _ = chmod(tree.phys(Tool.lsregister), 0o755)
        tree.mkdir("/Applications/Gone.app")
        XCTAssertEqual(try LaunchServicesScanner().scan(context(tree, runner: runner)), [])
    }

    func testLaunchServicesPathParsing() {
        XCTAssertEqual(LaunchServicesScanner.path(fromLine: "path:   /A b.app (0x39b0)"), "/A b.app")
        XCTAssertEqual(LaunchServicesScanner.path(fromLine: "path: /X (0x1) (0x2)"), "/X (0x1)")
        XCTAssertEqual(LaunchServicesScanner.path(fromLine: "path: /NoSuffix.app"), "/NoSuffix.app")
        XCTAssertNil(LaunchServicesScanner.path(fromLine: "bundle path: /x"))
    }

    func testLaunchServicesHonoursCancellation() {
        let tree = FakeTree()
        tree.write(Tool.lsregister, "bin")
        _ = chmod(tree.phys(Tool.lsregister), 0o755)
        let runner = StubRunner()
        runner.set("\(Tool.lsregister) -dump", stdout: "path: /Gone.app (0x1)\n")
        let token = CancellationToken()
        token.cancel()
        XCTAssertThrowsError(try LaunchServicesScanner().scan(context(tree, runner: runner, token: token))) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    // MARK: scan_nativemsg

    func testDeadNativeMessagingHosts() throws {
        let tree = FakeTree()
        let d = "\(home)/Library/Application Support/Google/Chrome/NativeMessagingHosts"
        tree.write("\(d)/com.dead.host.json", #"{"name": "com.dead.host", "path": "/opt/gone/host", "type": "stdio"}"#)
        tree.write("\(d)/rel_dead.json", #"{"path": "bin/host"}"#)
        tree.write("\(d)/host_alive", "bin")
        tree.write("\(d)/rel_alive.json", #"{"path": "host_alive"}"#)
        tree.write("/opt/alive/host", "bin")
        tree.write("\(d)/escaped.json", #"{"path": "\/opt\/alive\/host"}"#)   // escape JSON giải đúng
        tree.write("\(d)/broken.json", "{ \"name\": \"x\",\n  \"path\" :  \"/opt/gone2\" ,,,")   // JSON hỏng → regex
        tree.write("\(d)/nopath.json", #"{"name": "x"}"#)
        tree.write("\(d)/empty.json", #"{"path": ""}"#)
        tree.write("\(d)/notjson.txt", #"{"path": "/opt/gone3"}"#)
        tree.symlink("\(d)/link.json", to: tree.phys("\(d)/com.dead.host.json"))
        tree.write("/Library/Google/Chrome/NativeMessagingHosts/sys.json", #"{"path": "/opt/gone4"}"#)

        let fs = try NativeMessagingScanner().scan(context(tree))
        XCTAssertEqual(fs.map(\.id), [
            "NativeMsg|broken|\(d)/broken.json",
            "NativeMsg|com.dead.host|\(d)/com.dead.host.json",
            "NativeMsg|rel_dead|\(d)/rel_dead.json",
            "NativeMsg|sys|/Library/Google/Chrome/NativeMessagingHosts/sys.json",
        ])
        XCTAssertEqual(fs[0].reason, .nativeHostDead(executable: "/opt/gone2"))
        XCTAssertEqual(fs[1].reason, .nativeHostDead(executable: "/opt/gone/host"))
        XCTAssertEqual(fs[1].severity, .high)
        XCTAssertEqual(fs[1].action, .trashPath(path: "\(d)/com.dead.host.json"))
        // tương đối: ghép theo thư mục chứa manifest
        XCTAssertEqual(fs[2].reason, .nativeHostDead(executable: "\(d)/bin/host"))
    }

    func testNativeHostRegexFallback() {
        XCTAssertEqual(NativeMessagingScanner.firstPathMatch("  \"path\"\t:\t\"/a/b\" , \"path\": \"/c\""), "/a/b")
        XCTAssertEqual(NativeMessagingScanner.firstPathMatch(#""path" = "/x", "path":"/y""#), "/y")
        XCTAssertNil(NativeMessagingScanner.firstPathMatch(#""path": 5"#))
    }

    // MARK: scan_plugins

    func testPluginsBrokenAndOrphan() throws {
        let tree = FakeTree()
        let ql = "\(home)/Library/QuickLook"
        bundle(tree, "\(ql)/Good.qlgenerator", bundleID: "com.alive.ql")
        bundle(tree, "\(ql)/Broken.qlgenerator", bundleID: "com.alive.broken", createExecutable: false)
        // League of Legends: exe tương đối tính từ Contents/
        bundle(tree, "\(ql)/League.qlgenerator", bundleID: "com.alive.league", executable: "Game/run", createExecutable: false)
        tree.write("\(ql)/League.qlgenerator/Contents/Game/run", "bin")
        bundle(tree, "\(ql)/Orphan.qlgenerator", bundleID: "com.vendorgone.ql")
        tree.mkdir("\(ql)/Foo.bar.qlgenerator/Contents")                  // không Info.plist: không hỏng, không bid → bỏ
        tree.mkdir("\(ql)/nodot")                                         // không có đuôi: bỏ
        bundle(tree, "\(ql)/EmptyBid.qlgenerator", bundleID: "")          // bid rỗng → sống
        tree.symlink("\(ql)/Linked.qlgenerator", to: tree.phys("\(ql)/Orphan.qlgenerator"))   // symlink: bỏ
        let vst = "\(home)/Library/Audio/Plug-Ins/VST"
        bundle(tree, "\(vst)/Broken.vst", bundleID: "com.gone.vst", createExecutable: false)   // nhóm độc lập: chỉ xét hỏng
        bundle(tree, "\(vst)/Orphan.vst", bundleID: "com.vendorgone.vst")
        // /Library/Screen Savers: zsh bỏ sót do thiếu ngoặc kép, Swift quét đúng
        bundle(tree, "/Library/Screen Savers/Gone.saver", bundleID: "com.vendorgone.saver")

        let fs = try PluginScanner().scan(context(tree, index: aliveIndex(tree)))
        XCTAssertEqual(fs.map(\.id), [
            "Plugin|Broken.qlgenerator|\(ql)/Broken.qlgenerator",
            "Plugin|Orphan.qlgenerator|\(ql)/Orphan.qlgenerator",
            "Plugin|Gone.saver|/Library/Screen Savers/Gone.saver",
            "Plugin|Broken.vst|\(vst)/Broken.vst",
        ])
        XCTAssertEqual(fs[0].severity, .high)
        XCTAssertEqual(fs[0].reason, .bundleBroken(executable: "run"))
        XCTAssertEqual(fs[0].action, .trashPath(path: "\(ql)/Broken.qlgenerator"))
        XCTAssertGreaterThan(fs[0].sizeBytes, 0)
        // mức cố định Medium dù classifier nói High (bid rõ ràng)
        XCTAssertEqual(fs[1].severity, .medium)
        XCTAssertEqual(fs[1].reason, .pluginOrphan(owner: "com.vendorgone.ql"))
        XCTAssertEqual(fs[3].reason, .bundleBroken(executable: "run"))
    }

    // MARK: scan_brokenapps

    func testBrokenAppsFromIndex() throws {
        let tree = FakeTree()
        tree.makeApp("/Applications/Good.app", bundleID: "com.test.Good")
        tree.write("/Applications/Hollow.app/Contents/Resources/icon", "x")
        tree.makeApp("/Applications/NoExe.app", bundleID: "com.test.NoExe", withExecutable: false)
        tree.mkdir("/System/Applications/SysHollow.app")
        let runner = StubRunner()
        let idx = try AppIndex.build(env: tree.env, runner: runner)
        XCTAssertEqual(Set(idx.deadApps), ["/Applications/Hollow.app", "/Applications/NoExe.app",
                                           "/System/Applications/SysHollow.app"])
        let fs = try BrokenAppScanner().scan(context(tree, index: idx))
        XCTAssertEqual(fs.map(\.id), ["App|Hollow.app|/Applications/Hollow.app", "App|NoExe.app|/Applications/NoExe.app"])
        XCTAssertEqual(fs[0].reason, .hollowApp)
        XCTAssertEqual(fs[1].reason, .brokenApp(executable: "run"))
        XCTAssertTrue(fs.allSatisfy { $0.severity == .high })
        XCTAssertEqual(fs[0].action, .trashPath(path: "/Applications/Hollow.app"))
        XCTAssertGreaterThan(fs[0].sizeBytes, 0)
    }

    // MARK: Chung

    /// Cây trống, mọi lệnh lỗi → không bộ quét nhóm B nào báo gì hay ném lỗi.
    func testAllGroupBScannersQuietOnEmptySystem() throws {
        let tree = FakeTree()
        let scanners: [CleanScanner] = [EnvironmentScanner(), DyldScanner(), CertificatesScanner(), FirewallScanner(),
                                        TCCScanner(), SystemExtensionScanner(), SymlinkScanner(),
                                        LaunchServicesScanner(), NativeMessagingScanner(), PluginScanner(),
                                        BrokenAppScanner()]
        let ctx = ScanContext(env: tree.env, index: AppIndex(env: tree.env), runner: StubRunner(), hasFullDiskAccess: true)
        for s in scanners {
            XCTAssertEqual(try s.scan(ctx), [], s.id)
        }
    }
}

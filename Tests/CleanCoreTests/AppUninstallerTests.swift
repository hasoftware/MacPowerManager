import XCTest
@testable import CleanCore

/// Ngày dùng gần nhất giả theo hậu tố đường dẫn vật lý.
private struct FakeUsage: AppUsageReader {
    let byPathSuffix: [String: Date]
    func lastUsedDate(atPath path: String) -> Date? { byPathSuffix.first { path.hasSuffix($0.key) }?.value }
}

/// Bảng tiến trình giả.
private struct FakeProcesses: RunningProcessLister {
    let table: [RunningProcess]
    func runningProcesses() -> [RunningProcess] { table }
}

/// Luồng gỡ ứng dụng (P1): AppCatalog + AppUninstaller trên cây giả. Không bao giờ chạm hệ thống thật.
final class AppUninstallerTests: XCTestCase {
    private let lib = "/Users/tester/Library"

    // MARK: Dựng

    private func catalog(_ tree: FakeTree, signing: [String: SigningInfo] = [:], usage: [String: Date] = [:],
                         processes: [RunningProcess] = []) -> AppCatalog {
        AppCatalog(env: tree.env, signing: FakeSigning(byPathSuffix: signing), usage: FakeUsage(byPathSuffix: usage),
                   processes: FakeProcesses(table: processes))
    }

    private func app(_ tree: FakeTree, _ path: String, _ bid: String, extra: [String: Any] = [:]) {
        tree.makeApp(path, bundleID: bid)
        var d: [String: Any] = ["CFBundleIdentifier": bid, "CFBundleExecutable": "run"]
        for (k, v) in extra { d[k] = v }
        tree.plist(path + "/Contents/Info.plist", d)
    }

    /// Gom cho các app (theo tên) đã liệt kê; trả finding.
    private func collect(_ tree: FakeTree, _ names: [String], signing: [String: SigningInfo] = [:],
                         runner: StubRunner = StubRunner(), sizes: Bool = false) throws -> [Finding] {
        let listing = try catalog(tree, signing: signing).load()
        let apps = names.map { n in listing.apps.first { $0.name == n }! }
        return try AppUninstaller(env: tree.env, runner: runner, signing: FakeSigning(byPathSuffix: signing))
            .collect(apps, listing: listing, computeSizes: sizes)
    }

    private func targets(_ fs: [Finding]) -> Set<String> { Set(fs.map(\.target)) }

    private func match(_ fs: [Finding], _ target: String) -> AppFileMatch? {
        switch fs.first(where: { $0.target == target })?.reason {
        case .appRelated(_, let m)?, .appRelatedShared(_, let m, _)?: return m
        default: return nil
        }
    }

    // MARK: AppCatalog

    func testCatalogListsTopLevelAndOneSubfolderWithMetadata() throws {
        let tree = FakeTree()
        let used = Date(timeIntervalSince1970: 1_700_000_000)
        app(tree, "/Applications/Beta.app", "com.demo.Beta",
            extra: ["CFBundleShortVersionString": "2.1", "CFBundleName": "Beta Pro", "CFBundleDisplayName": "Beta",
                    "SMPrivilegedExecutables": ["com.demo.Beta.helper": "anchor apple"]])
        app(tree, "/Applications/Utilities/Alpha.app", "com.demo.Alpha", extra: ["CFBundleVersion": "77"])
        app(tree, "/Applications/Vendor/Deep/TooDeep.app", "com.demo.Deep")   // cấp 3: không đưa ra gỡ
        app(tree, "\(tree.homePath)/Applications/Home.app", "com.demo.Home")
        tree.mkdir("/Applications/Hollow.app/Contents")                      // vỏ rỗng: không liệt kê
        app(tree, "/Applications/Beta.app/Contents/Library/LoginItems/Inner.app", "com.demo.Inner")

        let listing = try catalog(tree, signing: ["/Beta.app": SigningInfo(teamID: "ABCDE12345", appGroups: ["ABCDE12345.shared"])],
                                  usage: ["/Beta.app": used]).load()
        XCTAssertEqual(listing.apps.map(\.name), ["Alpha", "Beta", "Home"])
        let beta = listing.apps[1]
        XCTAssertEqual(beta.bundleID, "com.demo.Beta")
        XCTAssertEqual(beta.version, "2.1")
        XCTAssertEqual(beta.bundleNames, ["Beta Pro"])          // "Beta" trùng tên file → bỏ
        XCTAssertEqual(beta.teamID, "ABCDE12345")
        XCTAssertEqual(beta.appGroups, ["ABCDE12345.shared"])
        XCTAssertEqual(beta.privilegedHelpers, ["com.demo.Beta.helper"])
        XCTAssertEqual(beta.lastUsed, used)
        XCTAssertEqual(listing.apps[0].version, "77")
        XCTAssertNil(listing.apps[0].lastUsed)
        XCTAssertTrue(listing.references.contains { $0.name == "TooDeep" }, "cấp sâu vẫn là app đang cài (tham chiếu)")
        XCTAssertFalse(listing.allInstalled.contains { $0.name == "Inner" }, "không đi vào trong .app")
        XCTAssertEqual(listing.find("beta.app").map(\.name), ["Beta"])
        XCTAssertEqual(listing.find("/Applications/Utilities/Alpha.app").map(\.name), ["Alpha"])
        XCTAssertEqual(listing.find("com.demo.home").map(\.name), ["Home"])
    }

    func testCatalogNeverOffersSystemSelfNestedOrTrashedApps() throws {
        let tree = FakeTree()
        app(tree, "/System/Applications/Mail.app", "com.apple.mail")
        app(tree, "/System/Cryptexes/App/System/Applications/Safari.app", "com.apple.Safari")
        tree.symlink("/Applications/Safari.app", to: tree.phys("/System/Cryptexes/App/System/Applications/Safari.app"))
        app(tree, "/Applications/MacPowerManager.app", ScanEnvironment.appBundleID)
        app(tree, "/Applications/Host.app", "com.demo.Host")
        app(tree, "/Applications/Host.app/Contents/Library/LoginItems/Inner.app", "com.demo.Inner")
        tree.symlink("/Applications/Inner.app", to: tree.phys("/Applications/Host.app/Contents/Library/LoginItems/Inner.app"))
        app(tree, "\(tree.homePath)/.Trash/Old.app", "com.demo.Old")
        tree.symlink("/Applications/Old.app", to: tree.phys("\(tree.homePath)/.Trash/Old.app"))

        let listing = try catalog(tree).load()
        XCTAssertEqual(listing.apps.map(\.name), ["Host"])
        let ex = Dictionary(uniqueKeysWithValues: listing.excluded.map { ($0.app.name, $0.reason) })
        XCTAssertEqual(ex, ["Safari": .system, "MacPowerManager": .ownApp, "Inner": .nestedInBundle, "Old": .inTrash])
        XCTAssertTrue(listing.references.contains { $0.name == "Mail" })
        XCTAssertTrue(listing.find("Safari").isEmpty)
        XCTAssertEqual(listing.findExcluded("Safari").first?.reason, .system)
        // truyền nhầm app bị loại vào collect: không gom gì
        let fs = try AppUninstaller(env: tree.env, runner: StubRunner(), signing: NoSigningInfoReader())
            .collect(listing.excluded.map(\.app), listing: listing, computeSizes: false)
        XCTAssertTrue(fs.isEmpty)
    }

    func testCatalogSizeIsSeparateAndCancellable() throws {
        let tree = FakeTree()
        app(tree, "/Applications/Big.app", "com.demo.Big")
        tree.writeBytes("/Applications/Big.app/Contents/Resources/blob", count: 3 * 1_048_576)
        let cat = catalog(tree)
        let big = try cat.load().apps[0]
        XCTAssertGreaterThanOrEqual(cat.size(of: big) ?? 0, 3 * 1_048_576)
        XCTAssertNil(cat.size(of: big, isCancelled: { true }))
        XCTAssertThrowsError(try cat.load(isCancelled: { true })) { XCTAssertTrue($0 is CancellationError) }
    }

    func testSymlinkedAppCollectsRealBundleAndTheLink() throws {
        let tree = FakeTree()
        app(tree, "/Users/Shared/Game.app", "com.demo.Game")
        tree.symlink("/Applications/Game.app", to: tree.phys("/Users/Shared/Game.app"))
        let listing = try catalog(tree).load()
        let game = try XCTUnwrap(listing.apps.first)
        XCTAssertEqual(game.path, "/Applications/Game.app")
        XCTAssertEqual(game.bundlePath, "/Users/Shared/Game.app")
        XCTAssertTrue(listing.references.isEmpty, "bundle thật không bị tính là app KHÁC")
        let fs = try collect(tree, ["Game"])
        XCTAssertEqual(fs.map(\.target), ["/Users/Shared/Game.app", "/Applications/Game.app"])
        XCTAssertEqual(fs[0].category, .app)
        XCTAssertEqual(match(fs, "/Applications/Game.app"), .appSymlink)
        XCTAssertTrue(fs.allSatisfy { $0.uninstallOwner?.path == "/Applications/Game.app" })
    }

    // MARK: Đang chạy

    func testRunningAppBlocksItsBundleAndFilesOnly() throws {
        let tree = FakeTree()
        app(tree, "/Applications/Foo.app", "com.demo.Foo")
        app(tree, "/Applications/Foo Helper.app", "com.demo.FooHelper")
        app(tree, "/Applications/Bar.app", "com.demo.Bar")
        tree.mkdir("\(lib)/Caches/com.demo.Foo")
        tree.mkdir("\(lib)/Caches/com.demo.Bar")
        let fooExe = tree.phys("/Applications/Foo.app/Contents/Library/LoginItems/Agent.app/Contents/MacOS/Agent")
        let table = [RunningProcess(pid: 42, executablePath: fooExe),
                     RunningProcess(pid: 43, executablePath: tree.phys("/Applications/Foo Helper.app/Contents/MacOS/run"))]
        let cat = catalog(tree, processes: table)
        let listing = try cat.load()
        let foo = listing.apps.first { $0.name == "Foo" }!
        let bar = listing.apps.first { $0.name == "Bar" }!
        XCTAssertEqual(cat.runningProcesses(of: foo).map(\.pid), [42], "tiền tố là `<bundle>/`, không ăn sang Foo Helper.app")
        XCTAssertTrue(cat.runningProcesses(of: bar).isEmpty)

        let fs = try AppUninstaller(env: tree.env, runner: StubRunner(), signing: NoSigningInfoReader())
            .collect([foo, bar], listing: listing, computeSizes: false)
        let states = AppUninstaller.runStates(apps: [foo, bar], findings: fs, table: table, env: tree.env)
        XCTAssertEqual(states[foo.path]?.appProcesses.map(\.pid), [42], "login item .app: thoát được")
        XCTAssertNil(states[bar.path])
        let pre = AppUninstaller.preflight(fs, states: states)
        XCTAssertEqual(targets(pre.blocked.map(\.finding)), ["/Applications/Foo.app", "\(lib)/Caches/com.demo.Foo"])
        XCTAssertTrue(pre.blocked.allSatisfy { $0.reason == .running })
        XCTAssertEqual(targets(pre.allowed), ["/Applications/Bar.app", "\(lib)/Caches/com.demo.Bar"])
        // thoát rồi: kiểm tra lại cho phép tất cả
        let after = AppUninstaller.runStates(apps: [foo, bar], findings: fs, table: [], env: tree.env)
        XCTAssertTrue(AppUninstaller.preflight(fs, states: after).blocked.isEmpty)
    }

    /// WARP: LaunchDaemon root (KeepAlive) chạy chương trình trong gói; Sideloadly: agent người dùng chạy từ gói;
    /// Xcode: sourcekit-lsp do công cụ khác chạy.
    func testServicesAndHelpersRunningFromTheBundle() throws {
        try XCTSkipIf(getuid() == 0, "root bỏ qua quyền thư mục")
        let tree = FakeTree()
        app(tree, "/Applications/Warp.app", "com.demo.warp")
        app(tree, "/Applications/Side.app", "io.side.app")
        app(tree, "/Applications/Tool.app", "com.demo.tool")
        tree.write("/Applications/Warp.app/Contents/Resources/warpd", "bin")
        tree.write("/Applications/Side.app/Contents/Resources/side-daemon", "bin")
        tree.write("/Applications/Tool.app/Contents/Developer/usr/bin/lsp", "bin")
        tree.plist("/Library/LaunchDaemons/com.demo.warp.daemon.plist",
                   ["Label": "com.demo.warp.daemon", "Program": "/Applications/Warp.app/Contents/Resources/warpd", "KeepAlive": true])
        _ = chmod(tree.phys("/Library/LaunchDaemons"), 0o555)
        tree.plist("\(lib)/LaunchAgents/io.side.daemon.plist",
                   ["Label": "io.side.daemon", "ProgramArguments": ["/Applications/Side.app/Contents/Resources/side-daemon", "-d"]])
        tree.write("\(lib)/Preferences/com.demo.warp.plist")
        tree.write("\(lib)/Preferences/io.side.app.plist")
        tree.write("\(lib)/Preferences/com.demo.tool.plist")
        let table = [
            RunningProcess(pid: 778, executablePath: tree.phys("/Applications/Warp.app/Contents/Resources/warpd"), ppid: 1),
            RunningProcess(pid: 779, executablePath: tree.phys("/Applications/Warp.app/Contents/Resources/warpd"), ppid: 778),
            RunningProcess(pid: 900, executablePath: tree.phys("/Applications/Side.app/Contents/Resources/side-daemon"), ppid: 1),
            RunningProcess(pid: 500, executablePath: "/usr/local/bin/claude", ppid: 1),
            RunningProcess(pid: 501, executablePath: tree.phys("/Applications/Tool.app/Contents/Developer/usr/bin/lsp"), ppid: 500),
        ]
        let listing = try catalog(tree).load()
        let apps = listing.apps
        let fs = try AppUninstaller(env: tree.env, runner: StubRunner(), signing: NoSigningInfoReader())
            .collect(apps, listing: listing, computeSizes: false)
        let states = AppUninstaller.runStates(apps: apps, findings: fs, table: table, env: tree.env)
        func f(_ t: String) -> Finding { fs.first { $0.target == t }! }

        // WARP: daemon root (cả tiến trình con) = dịch vụ; gói bị khóa, dữ liệu người dùng thì không
        let warp = try XCTUnwrap(states["/Applications/Warp.app"])
        XCTAssertFalse(warp.blocksEverything)
        XCTAssertEqual(warp.services.map(\.label), ["com.demo.warp.daemon"])
        XCTAssertEqual(warp.services.first?.isSystem, true)
        XCTAssertEqual(warp.services.first?.isSelectable, false)
        XCTAssertEqual(warp.processes.count, 2)
        XCTAssertEqual(AppUninstaller.block(f("/Applications/Warp.app"), states: states, selected: nil),
                       .serviceNeedsAdmin(label: "com.demo.warp.daemon", domain: "system"))
        XCTAssertNil(AppUninstaller.block(f("\(lib)/Preferences/com.demo.warp.plist"), states: states, selected: nil))

        // Sideloadly: agent người dùng - chọn được; gỡ chỉ khi job cùng được chọn (dừng trước)
        let side = try XCTUnwrap(states["/Applications/Side.app"])
        XCTAssertEqual(side.services.map(\.label), ["io.side.daemon"])
        XCTAssertEqual(side.services.first?.isSelectable, true)
        let sideBundle = f("/Applications/Side.app"), sideJob = f("\(lib)/LaunchAgents/io.side.daemon.plist")
        XCTAssertNil(AppUninstaller.block(sideBundle, states: states, selected: nil), "đang chọn: chưa khóa")
        let without = AppUninstaller.preflight([sideBundle], states: states)
        XCTAssertEqual(without.blocked.map(\.reason), [.serviceNotSelected(label: "io.side.daemon")])
        let with = AppUninstaller.preflight([sideBundle, sideJob], states: states)
        XCTAssertTrue(with.blocked.isEmpty)

        // Tool: helper do tiến trình khác chạy - khóa mọi mục, nói rõ ai chạy
        let tool = try XCTUnwrap(states["/Applications/Tool.app"])
        XCTAssertTrue(tool.blocksEverything)
        XCTAssertTrue(tool.appProcesses.isEmpty, "không có app nào để Thoát")
        XCTAssertEqual(tool.helpers.map(\.process.name), ["lsp"])
        XCTAssertEqual(tool.helpers.first?.parentName, "claude")
        XCTAssertEqual(AppUninstaller.block(f("\(lib)/Preferences/com.demo.tool.plist"), states: states, selected: nil), .running)
    }

    // MARK: collect_app_files (parity)

    /// Test zsh 12.19: gom đúng 3 mục (theo bid, id con, theo tên), không gom KhongLienQuan.
    func testParityCollectAppFiles() throws {
        let tree = FakeTree()
        app(tree, "/Applications/DemoApp.app", "com.demo.App")
        tree.mkdir("\(lib)/Caches/com.demo.App")
        tree.mkdir("\(lib)/Application Support/DemoApp")
        tree.mkdir("\(lib)/Caches/com.khac.KhongLienQuan")
        tree.write("\(lib)/Preferences/com.demo.App.helper.plist")
        let fs = try collect(tree, ["DemoApp"])
        XCTAssertEqual(fs.filter { $0.category == .appFiles }.count, 3)
        XCTAssertEqual(targets(fs), ["/Applications/DemoApp.app", "\(lib)/Caches/com.demo.App",
                                     "\(lib)/Application Support/DemoApp", "\(lib)/Preferences/com.demo.App.helper.plist"])
        XCTAssertEqual(fs.first?.reason, .appBundle(AppRef(name: "DemoApp", path: "/Applications/DemoApp.app")))
        XCTAssertTrue(fs.allSatisfy { $0.severity == .high && $0.kind == .trashPath })
    }

    func testEveryRootAndSuffixRule() throws {
        let tree = FakeTree()
        app(tree, "/Applications/Demo App.app", "com.demo.App")
        let roots = AppUninstaller.roots(homePath: tree.homePath).filter { !$0.hasSuffix("/ByHost") }
        var expected: Set<String> = ["/Applications/Demo App.app"]
        for (i, r) in roots.enumerated() {
            // mỗi gốc một kiểu tên khác nhau, vòng qua các đuôi bị cắt
            let names = ["com.demo.App", "com.demo.App.plist", "com.demo.App.savedState", "com.demo.App.binarycookies",
                         "com.demo.App.json", "COM.DEMO.APP.child", "Demo App", "demo-app.plist"]
            let n = names[i % names.count]
            if n.hasSuffix(".plist") || n.hasSuffix(".json") || n.hasSuffix(".binarycookies") {
                tree.write("\(r)/\(n)")
            } else {
                tree.mkdir("\(r)/\(n)")
            }
            expected.insert("\(r)/\(n)")
            // không liên quan / gần giống
            tree.mkdir("\(r)/com.demo.Apple")
            tree.mkdir("\(r)/com.demo.AppX.json")
            tree.mkdir("\(r)/Demo App Pro")
            tree.mkdir("\(r)/.com.demo.App.hidden")
        }
        let fs = try collect(tree, ["Demo App"])
        XCTAssertEqual(targets(fs), expected)
        XCTAssertEqual(fs.count, expected.count)
        XCTAssertEqual(match(fs, "\(lib)/Caches/com.demo.App.plist"), .bundleID)
        XCTAssertEqual(match(fs, "\(lib)/Preferences/com.demo.App.savedState"), .bundleID)
        // gốc thứ 7 (i=6): tên chuẩn hóa
        XCTAssertEqual(match(fs, "\(roots[6])/Demo App"), .name)
        XCTAssertEqual(match(fs, "\(roots[7])/demo-app.plist"), .name)
        // LaunchAgents/LaunchDaemons: job launchd, domain theo thư mục
        let daemons = fs.filter { $0.target.hasPrefix("/Library/LaunchDaemons/") }
        XCTAssertEqual(daemons.count, 1)
        if case .launchdJob(_, _, let domain) = daemons[0].action { XCTAssertEqual(domain, "system") } else { XCTFail() }
    }

    func testByHostStripsHexHostSuffix() throws {
        let tree = FakeTree()
        app(tree, "/Applications/Demo.app", "com.demo.App")
        let bh = "\(lib)/Preferences/ByHost"
        tree.write("\(bh)/com.demo.App.0A2F4E1B-363A-41F8-BFA9-7706E6A02950.plist")
        tree.write("\(bh)/com.demo.App.ShipIt.73E41DA7-4DDC-56C4-A198-20B40B01B074.plist")
        tree.write("\(bh)/com.demo.Apple.0A2F4E1B-363A-41F8-BFA9-7706E6A02950.plist")
        tree.write("\(bh)/com.demo.App.notahex.plist")   // "notahex" có ký tự ngoài hex: không cắt, nhưng vẫn là bid.*
        tree.write("\(bh)/com.other.0A2F4E1B.plist")
        let fs = try collect(tree, ["Demo"])
        XCTAssertEqual(targets(fs.filter { $0.target.hasPrefix(bh) }),
                       ["\(bh)/com.demo.App.0A2F4E1B-363A-41F8-BFA9-7706E6A02950.plist",
                        "\(bh)/com.demo.App.ShipIt.73E41DA7-4DDC-56C4-A198-20B40B01B074.plist",
                        "\(bh)/com.demo.App.notahex.plist"])
        XCTAssertEqual(AppUninstaller.strippingByHostSuffix("com.x.App.0A2F-4E"), "com.x.App")
        XCTAssertEqual(AppUninstaller.strippingByHostSuffix("com.x.App.zz"), "com.x.App.zz")
        XCTAssertEqual(AppUninstaller.strippingByHostSuffix("noDot"), "noDot")
    }

    // MARK: Cải tiến

    func testTeamPrefixAndAppGroupContainers() throws {
        let tree = FakeTree()
        app(tree, "/Applications/Demo.app", "com.demo.App")
        let gc = "\(lib)/Group Containers"
        tree.mkdir("\(gc)/ABCDE12345.com.demo.App")
        tree.mkdir("\(gc)/group.com.demo.App.shared")
        tree.mkdir("\(gc)/ABCDE12345.DemoShared")
        tree.mkdir("\(gc)/ABCDE12345.Other")
        tree.mkdir("\(gc)/abcde12345.com.demo.App")      // team id thường: không cắt (parity strip_team_prefix)
        let fs = try collect(tree, ["Demo"], signing: ["/Demo.app": SigningInfo(teamID: "ABCDE12345",
                                                                               appGroups: ["ABCDE12345.DemoShared"])])
        XCTAssertEqual(targets(fs.filter { $0.target.hasPrefix(gc) }),
                       ["\(gc)/ABCDE12345.com.demo.App", "\(gc)/group.com.demo.App.shared", "\(gc)/ABCDE12345.DemoShared"])
        XCTAssertEqual(match(fs, "\(gc)/ABCDE12345.com.demo.App"), .teamPrefixedBundleID)
        XCTAssertEqual(match(fs, "\(gc)/group.com.demo.App.shared"), .bundleID)
        XCTAssertEqual(match(fs, "\(gc)/ABCDE12345.DemoShared"), .appGroup)
    }

    func testContainerMetadataAndEmbeddedComponents() throws {
        let tree = FakeTree()
        app(tree, "/Applications/Demo.app", "com.demo.App")
        app(tree, "/Applications/Demo.app/Contents/PlugIns/Share.appex", "com.demo.ShareKit")
        app(tree, "/Applications/Demo.app/Contents/Library/LoginItems/Launcher.app", "com.demo.Launcher")
        app(tree, "/Applications/Demo.app/Contents/PlugIns/Third.appex", "org.sparkle-project.Downloader")
        let c = "\(lib)/Containers"
        tree.mkdir("\(c)/7F3D2C1A-AAAA-BBBB-CCCC-123456789ABC")
        tree.plist("\(c)/7F3D2C1A-AAAA-BBBB-CCCC-123456789ABC/.com.apple.containermanagerd.metadata.plist",
                   ["MCMMetadataIdentifier": "com.demo.App.Widget"])
        // tên cũ (không "d") vẫn đọc
        tree.plist("\(c)/1111AAAA-AAAA-BBBB-CCCC-123456789ABC/.com.apple.containermanager.metadata.plist",
                   ["MCMMetadataIdentifier": "com.demo.App"])
        tree.mkdir("\(c)/0000AAAA-AAAA-BBBB-CCCC-123456789ABC")
        tree.plist("\(c)/0000AAAA-AAAA-BBBB-CCCC-123456789ABC/.com.apple.containermanagerd.metadata.plist",
                   ["MCMMetadataIdentifier": "com.other.Widget"])
        tree.mkdir("\(c)/com.demo.ShareKit")
        tree.mkdir("\(c)/com.demo.Launcher")
        tree.mkdir("\(c)/org.sparkle-project.Downloader")
        tree.mkdir("\(lib)/Group Containers/ABCDE12345.share-group")
        let fs = try collect(tree, ["Demo"], signing: ["/Share.appex": SigningInfo(appGroups: ["ABCDE12345.share-group"])])
        XCTAssertEqual(match(fs, "\(c)/7F3D2C1A-AAAA-BBBB-CCCC-123456789ABC"), .containerMetadata)
        XCTAssertEqual(match(fs, "\(c)/1111AAAA-AAAA-BBBB-CCCC-123456789ABC"), .containerMetadata)
        XCTAssertEqual(match(fs, "\(c)/com.demo.ShareKit"), .embeddedBundleID)
        XCTAssertEqual(match(fs, "\(c)/com.demo.Launcher"), .embeddedBundleID)
        XCTAssertEqual(match(fs, "\(lib)/Group Containers/ABCDE12345.share-group"), .appGroup)
        XCTAssertNil(match(fs, "\(c)/org.sparkle-project.Downloader"), "thành phần bên thứ ba nhúng sẵn không phải bằng chứng")
        XCTAssertNil(match(fs, "\(c)/0000AAAA-AAAA-BBBB-CCCC-123456789ABC"))
    }

    func testLaunchdJobsByLabelAssociatedBundleAndProgramInsideBundle() throws {
        let tree = FakeTree()
        app(tree, "/Applications/Demo.app", "com.demo.App")
        let ua = "\(lib)/LaunchAgents"
        tree.plist("\(ua)/zzz-label.plist", ["Label": "com.demo.App.agent", "Program": "/usr/bin/true"])
        tree.plist("\(ua)/assoc.plist", ["Label": "x.assoc", "AssociatedBundleIdentifiers": ["com.demo.App"],
                                         "Program": "/opt/x"])
        tree.plist("\(ua)/assoc-string.plist", ["Label": "x.assoc2", "AssociatedBundleIdentifiers": "com.demo.App"])
        tree.plist("\(ua)/com.vendor.mini.plist", ["Label": "com.vendor.mini",
                                                   "ProgramArguments": ["/Applications/Demo.app/Contents/MacOS/Mini.app/Contents/MacOS/Mini", "-x"]])
        tree.plist("/Library/LaunchDaemons/com.vendor.daemon.plist",
                   ["Label": "com.vendor.daemon", "Program": "/Applications/Demo.app/Contents/Resources/daemon"])
        // không liên quan: chương trình ở app khác có tên bắt đầu giống, updater của vendor
        tree.plist("\(ua)/com.vendor.other.plist", ["Label": "com.vendor.other",
                                                    "Program": "/Applications/Demo.app2/Contents/MacOS/x"])
        tree.plist("\(ua)/com.vendor.updater.plist", ["Label": "com.vendor.updater",
                                                      "Program": "\(tree.homePath)/Library/Application Support/Vendor/Updater"])
        let fs = try collect(tree, ["Demo"])
        XCTAssertEqual(match(fs, "\(ua)/zzz-label.plist"), .launchdLabel)
        XCTAssertEqual(match(fs, "\(ua)/assoc.plist"), .launchdAssociatedBundle)
        XCTAssertEqual(match(fs, "\(ua)/assoc-string.plist"), .launchdAssociatedBundle)
        XCTAssertEqual(match(fs, "\(ua)/com.vendor.mini.plist"), .launchdProgramInBundle)
        XCTAssertEqual(match(fs, "/Library/LaunchDaemons/com.vendor.daemon.plist"), .launchdProgramInBundle)
        XCTAssertNil(match(fs, "\(ua)/com.vendor.other.plist"))
        XCTAssertNil(match(fs, "\(ua)/com.vendor.updater.plist"))
        let mini = try XCTUnwrap(fs.first { $0.target == "\(ua)/com.vendor.mini.plist" })
        XCTAssertEqual(mini.action, .launchdJob(plist: "\(ua)/com.vendor.mini.plist", label: "com.vendor.mini", domain: "gui/501"))
        let daemon = try XCTUnwrap(fs.first { $0.target == "/Library/LaunchDaemons/com.vendor.daemon.plist" })
        XCTAssertEqual(daemon.action, .launchdJob(plist: "/Library/LaunchDaemons/com.vendor.daemon.plist",
                                                  label: "com.vendor.daemon", domain: "system"))
    }

    func testPrivilegedHelperDeclaredByAppNeedsAdmin() throws {
        let tree = FakeTree()
        app(tree, "/Applications/Demo.app", "com.demo.App",
            extra: ["SMPrivilegedExecutables": ["com.vendor.helper": "identifier \"com.vendor.helper\""]])
        tree.write("/Library/PrivilegedHelperTools/com.vendor.helper", "bin")
        tree.plist("/Library/LaunchDaemons/com.vendor.helper.plist",
                   ["Label": "com.vendor.helper", "Program": "/Library/PrivilegedHelperTools/com.vendor.helper"])
        tree.write("/Library/PrivilegedHelperTools/com.vendor.otherhelper", "bin")
        // /Library/* thuộc root trên máy thật: không ghi được
        _ = chmod(tree.phys("/Library/PrivilegedHelperTools"), 0o555)
        _ = chmod(tree.phys("/Library/LaunchDaemons"), 0o555)
        let fs = try collect(tree, ["Demo"])
        XCTAssertEqual(match(fs, "/Library/PrivilegedHelperTools/com.vendor.helper"), .privilegedHelper)
        XCTAssertEqual(match(fs, "/Library/LaunchDaemons/com.vendor.helper.plist"), .privilegedHelper)
        XCTAssertNil(match(fs, "/Library/PrivilegedHelperTools/com.vendor.otherhelper"))
        if getuid() != 0 {
            XCTAssertTrue(fs.filter { $0.target.hasPrefix("/Library/") }.allSatisfy(\.needsAdmin))
        }
    }

    func testPackageReceiptsMatchBundleIDOrChildrenAndAlwaysNeedAdmin() throws {
        let tree = FakeTree()
        app(tree, "/Applications/Demo.app", "com.demo.App")
        app(tree, "/Applications/Demo Pro.app", "com.demo.App.Pro")
        let runner = StubRunner()
        runner.set("\(Tool.pkgutil) --pkgs", stdout: "com.demo.App\ncom.demo.app.core\ncom.demo.Apple\ncom.other\ncom.demo.App.Pro.pkg\n")
        let fs = try collect(tree, ["Demo"], runner: runner)
        let receipts = fs.filter { $0.category == .receipt }
        XCTAssertEqual(receipts.map(\.name), ["com.demo.App", "com.demo.app.core"],
                       "biên nhận của Demo Pro (bundle id cụ thể hơn) không thuộc Demo")
        XCTAssertEqual(receipts.map(\.target), ["/var/db/receipts/com.demo.App", "/var/db/receipts/com.demo.app.core"])
        XCTAssertTrue(receipts.allSatisfy { $0.needsAdmin && $0.severity == .medium })
        XCTAssertEqual(receipts.first?.action, .pkgReceipt(id: "com.demo.App"))
        XCTAssertEqual(match(fs, "/var/db/receipts/com.demo.App"), .packageReceipt)
        XCTAssertEqual(runner.calls.filter { $0 == [Tool.pkgutil, "--pkgs"] }.count, 1)
    }

    func testRootOwnedBundleNeedsAdmin() throws {
        try XCTSkipIf(getuid() == 0, "root bỏ qua quyền thư mục")
        let tree = FakeTree()
        app(tree, "/Applications/Locked.app", "com.demo.Locked")
        app(tree, "/Applications/Open.app", "com.demo.Open")
        _ = chmod(tree.phys("/Applications/Locked.app"), 0o555)    // như bundle thuộc root (drwxr-xr-x root)
        let fs = try collect(tree, ["Locked", "Open"])
        XCTAssertEqual(fs.first { $0.name == "Locked" }?.needsAdmin, true)
        XCTAssertEqual(fs.first { $0.name == "Open" }?.needsAdmin, false)
    }

    // MARK: Dùng chung

    func testSharedVendorFolderIsReportOnlyUnlessBothAppsAreRemoved() throws {
        let tree = FakeTree()
        app(tree, "/Applications/Messenger.app", "com.vendor.messenger")
        app(tree, "/Applications/Chat.app", "net.vendor.chat")
        let gc = "\(lib)/Group Containers"
        tree.mkdir("\(gc)/group.com.vendor.family")
        tree.mkdir("\(gc)/group.com.vendor.messenger.only")
        let signing = ["/Messenger.app": SigningInfo(appGroups: ["group.com.vendor.family", "group.com.vendor.messenger.only"]),
                       "/Chat.app": SigningInfo(appGroups: ["group.com.vendor.family"])]
        let one = try collect(tree, ["Messenger"], signing: signing)
        let fam = try XCTUnwrap(one.first { $0.target == "\(gc)/group.com.vendor.family" })
        XCTAssertEqual(fam.reason, .appRelatedShared(AppRef(name: "Messenger", path: "/Applications/Messenger.app"),
                                                     match: .appGroup, sharedWith: ["Chat"]))
        XCTAssertEqual(fam.action, .reportOnly)
        XCTAssertEqual(fam.severity, .info)
        XCTAssertTrue(fam.isSharedAppFile)
        XCTAssertEqual(match(one, "\(gc)/group.com.vendor.messenger.only"), .bundleID, "bỏ `group.` → com.vendor.messenger.*")
        XCTAssertFalse(one.first { $0.target == "\(gc)/group.com.vendor.messenger.only" }!.isSharedAppFile)

        // xem lại cả hai: mục chung của hai app đang xem, chỉ xuất hiện một lần, ghi rõ app kia; gỡ được chỉ khi gói
        // của CẢ HAI cùng được gỡ
        let both = try collect(tree, ["Messenger", "Chat"], signing: signing)
        let famBoth = both.filter { $0.target == "\(gc)/group.com.vendor.family" }
        XCTAssertEqual(famBoth.count, 1)
        let joint = try XCTUnwrap(famBoth.first)
        XCTAssertEqual(joint.kind, .trashPath)
        XCTAssertEqual(joint.reason, .appRelatedJoint(AppRef(name: "Messenger", path: "/Applications/Messenger.app"),
                                                      match: .appGroup,
                                                      coOwners: [AppRef(name: "Chat", path: "/Applications/Chat.app")]))
        XCTAssertEqual(joint.uninstallOwners.map(\.name), ["Messenger", "Chat"])
        let chatBundle = both.first { $0.target == "/Applications/Chat.app" }!
        let messengerBundle = both.first { $0.target == "/Applications/Messenger.app" }!
        // chỉ gỡ Messenger (Chat ở lại): mục chung bị giữ
        let onlyOne = AppUninstaller.preflight([messengerBundle, joint], states: [:])
        XCTAssertEqual(onlyOne.blocked.map(\.reason), [.sharedWithKeptApp(app: "Chat")])
        XCTAssertEqual(onlyOne.allowed.map(\.target), [messengerBundle.target])
        XCTAssertTrue(AppUninstaller.preflight([messengerBundle, chatBundle, joint], states: [:]).blocked.isEmpty)
        // gói Chat đã không còn (gỡ bằng Finder): coi như đã gỡ
        XCTAssertTrue(AppUninstaller.preflight([messengerBundle, joint], states: [:],
                                               missingApps: ["/Applications/Chat.app"]).blocked.isEmpty)
        // app đồng chủ đang chạy: giữ lại
        let running = AppRunState(processes: [.init(process: RunningProcess(pid: 9, executablePath: "/x"), kind: .app)])
        let pre = AppUninstaller.preflight([messengerBundle, chatBundle, joint], states: ["/Applications/Chat.app": running])
        XCTAssertEqual(Set(pre.blocked.map(\.finding.target)), [chatBundle.target, joint.target])

        // tham chiếu ngoài danh sách gỡ (/System, cấp sâu) cũng tính
        app(tree, "/Applications/Suite/Tools/Other.app", "com.vendor.other")
        tree.mkdir("\(lib)/Application Support/Other")
        app(tree, "/Applications/Other.app", "com.thirdparty.other")
        let other = try collect(tree, ["Other"])
        XCTAssertEqual(other.first { $0.target == "\(lib)/Application Support/Other" }?.reason,
                       .appRelatedShared(AppRef(name: "Other", path: "/Applications/Other.app"), match: .name,
                                         sharedWith: ["Other"]))
    }

    func testMoreSpecificBundleIDOwnsTheItem() throws {
        let tree = FakeTree()
        app(tree, "/Applications/Demo.app", "com.demo.App")
        app(tree, "/Applications/Demo Pro.app", "com.demo.App.Pro")
        tree.write("\(lib)/Preferences/com.demo.App.plist")
        tree.write("\(lib)/Preferences/com.demo.App.Pro.plist")
        let demo = try collect(tree, ["Demo"])
        XCTAssertEqual(demo.first { $0.target == "\(lib)/Preferences/com.demo.App.plist" }?.kind, .trashPath)
        let pro = try XCTUnwrap(demo.first { $0.target == "\(lib)/Preferences/com.demo.App.Pro.plist" })
        XCTAssertEqual(pro.action, .reportOnly, "file của Demo Pro, không gỡ cùng Demo")
        // gỡ Demo Pro: chỉ lấy file của chính nó, file com.demo.App không khớp (bid ngắn hơn)
        let fsPro = try collect(tree, ["Demo Pro"])
        XCTAssertEqual(targets(fsPro.filter { $0.category == .appFiles }), ["\(lib)/Preferences/com.demo.App.Pro.plist"])
        XCTAssertEqual(fsPro.first { $0.category == .appFiles }?.kind, .trashPath)
    }

    func testSameBundleIDCopiesAreShared() throws {
        let tree = FakeTree()
        app(tree, "/Applications/Xcode.app", "com.apple.dt.Xcode")
        app(tree, "/Applications/Xcode-beta.app", "com.apple.dt.Xcode")
        tree.write("\(lib)/Preferences/com.apple.dt.Xcode.plist")
        let fs = try collect(tree, ["Xcode-beta"])
        XCTAssertEqual(fs.first { $0.target == "\(lib)/Preferences/com.apple.dt.Xcode.plist" }?.reason,
                       .appRelatedShared(AppRef(name: "Xcode-beta", path: "/Applications/Xcode-beta.app"),
                                         match: .bundleID, sharedWith: ["Xcode"]))
    }

    // MARK: Không khớp nhầm

    /// Quyết định: tên chỉ khớp khi tên CHUẨN HÓA BẰNG NHAU, không bao giờ "chứa nhau".
    func testNoFalseMatchesForSimilarNames() throws {
        let tree = FakeTree()
        app(tree, "/Applications/Notion.app", "notion.id")
        app(tree, "/Applications/Notion Calendar.app", "com.cron.electron")
        app(tree, "/Applications/Visual Studio Code.app", "com.microsoft.VSCode", extra: ["CFBundleName": "Code"])
        let a = "\(lib)/Application Support"
        for n in ["Notion", "Notion Calendar", "Code", "Visual Studio Code", "Code - Insiders"] { tree.mkdir("\(a)/\(n)") }
        tree.write("\(lib)/Preferences/notion.id.plist")
        tree.write("\(lib)/Preferences/com.cron.electron.plist")
        tree.write("\(lib)/Preferences/com.cron.electron.helper.plist")

        let notion = try collect(tree, ["Notion"])
        XCTAssertEqual(targets(notion.filter { $0.category == .appFiles }), ["\(a)/Notion", "\(lib)/Preferences/notion.id.plist"])
        let cal = try collect(tree, ["Notion Calendar"])
        XCTAssertEqual(targets(cal.filter { $0.category == .appFiles }),
                       ["\(a)/Notion Calendar", "\(lib)/Preferences/com.cron.electron.plist",
                        "\(lib)/Preferences/com.cron.electron.helper.plist"])
        let code = try collect(tree, ["Visual Studio Code"])
        XCTAssertEqual(targets(code.filter { $0.category == .appFiles }), ["\(a)/Code", "\(a)/Visual Studio Code"])
        XCTAssertEqual(match(code, "\(a)/Code"), .bundleName)
        XCTAssertEqual(match(code, "\(a)/Visual Studio Code"), .name)
    }

    func testShortUnicodeAndSystemNamesNeverMatchByName() throws {
        let tree = FakeTree()
        app(tree, "/Applications/微信.app", "com.tencent.wechat.cn")         // norm rỗng
        app(tree, "/Applications/Mail.app", "com.thirdparty.mailer")          // tên trùng SYS_KEEP
        app(tree, "/Applications/X.app", "com.single.x")                      // tên 1 ký tự: quá ngắn để khớp theo tên
        let a = "\(lib)/Application Support"
        for n in ["日本語", "Mail", "X", "x.child"] { tree.mkdir("\(a)/\(n)") }
        let listing = try catalog(tree).load()
        let un = AppUninstaller(env: tree.env, runner: StubRunner(), signing: NoSigningInfoReader())
        for app in listing.apps {
            let fs = try un.collect([app], listing: listing, computeSizes: false)
            XCTAssertEqual(fs.filter { $0.category == .appFiles }.map(\.target), [], app.name)
        }
        XCTAssertTrue(AppUninstaller.idMatches("x", "x"))
        XCTAssertFalse(AppUninstaller.idMatches("x.child", "x"), "bundle id không có dấu chấm chỉ khớp chính xác")
    }

    func testVendorSubfolder() throws {
        let tree = FakeTree()
        app(tree, "/Applications/Google Chrome.app", "com.google.Chrome")
        app(tree, "/Applications/Acme Tool.app", "com.other.tool")             // vendor không khớp bundle id
        let a = "\(lib)/Application Support"
        tree.mkdir("\(a)/Google/Chrome/Default")
        tree.mkdir("\(a)/Google/GoogleUpdater")
        tree.mkdir("\(a)/Google/Chrome Canary")
        tree.mkdir("\(lib)/Caches/Google/Chrome")
        tree.mkdir("\(a)/Acme/Tool")
        // job launchd còn chạy chương trình trong thư mục hãng: thư mục hãng không được đưa ra (gần đúng)
        tree.plist("\(lib)/LaunchAgents/com.google.GoogleUpdater.wake.plist",
                   ["Label": "com.google.GoogleUpdater.wake",
                    "ProgramArguments": ["\(a)/Google/GoogleUpdater/Current/GoogleUpdater.app/Contents/MacOS/GoogleUpdater"]])
        let fs = try collect(tree, ["Google Chrome"])
        XCTAssertEqual(targets(fs.filter { $0.category == .appFiles }),
                       ["\(a)/Google/Chrome", "\(lib)/Caches/Google/Chrome", "\(lib)/Caches/Google"])
        XCTAssertEqual(match(fs, "\(a)/Google/Chrome"), .vendorSubfolder)
        XCTAssertEqual(match(fs, "\(lib)/Caches/Google"), .vendorFolder, "chỉ Chrome mang hãng Google: gần đúng")
        let acme = try collect(tree, ["Acme Tool"])
        XCTAssertTrue(acme.filter { $0.category == .appFiles }.isEmpty)
    }

    func testCancellation() throws {
        let tree = FakeTree()
        app(tree, "/Applications/Demo.app", "com.demo.App")
        let listing = try catalog(tree).load()
        XCTAssertThrowsError(try AppUninstaller(env: tree.env, runner: StubRunner(), signing: NoSigningInfoReader())
            .collect(listing.apps, listing: listing, isCancelled: { true })) { XCTAssertTrue($0 is CancellationError) }
    }

    // MARK: Rà soát P1

    /// Xcode và Xcode-beta cùng nhúng một appex (id + App Group chỉ khai trong appex): gỡ một bản thì các mục đó
    /// dùng chung với bản kia, không được đưa ra gỡ.
    func testSiblingAppexIDsAndAppexOnlyGroupsAreShared() throws {
        let tree = FakeTree()
        for name in ["Xcode", "Xcode-beta"] {
            app(tree, "/Applications/\(name).app", "com.apple.dt.Xcode")
            app(tree, "/Applications/\(name).app/Contents/PlugIns/XCC.appex", "com.apple.dt.DVTFeedbackReporting.XCC")
        }
        let gc = "\(lib)/Group Containers", c = "\(lib)/Containers"
        tree.mkdir("\(gc)/59GAB85EFG.com.apple.dt.XcodeCloud")
        tree.mkdir("\(c)/com.apple.dt.DVTFeedbackReporting.XCC")
        tree.mkdir("\(lib)/Application Scripts/59GAB85EFG.com.apple.dt.XcodeCloud")
        let signing = ["/XCC.appex": SigningInfo(teamID: "59GAB85EFG", appGroups: ["59GAB85EFG.com.apple.dt.XcodeCloud"]),
                       "/Xcode.app": SigningInfo(teamID: "59GAB85EFG"), "/Xcode-beta.app": SigningInfo(teamID: "59GAB85EFG")]
        let fs = try collect(tree, ["Xcode"], signing: signing)
        for t in ["\(gc)/59GAB85EFG.com.apple.dt.XcodeCloud", "\(c)/com.apple.dt.DVTFeedbackReporting.XCC",
                  "\(lib)/Application Scripts/59GAB85EFG.com.apple.dt.XcodeCloud"] {
            let f = try XCTUnwrap(fs.first { $0.target == t }, t)
            XCTAssertTrue(f.isSharedAppFile, t)
            XCTAssertEqual(f.action, .reportOnly, t)
        }
        // chỉ một bản: của riêng nó
        let solo = FakeTree()
        app(solo, "/Applications/Xcode.app", "com.apple.dt.Xcode")
        app(solo, "/Applications/Xcode.app/Contents/PlugIns/XCC.appex", "com.apple.dt.DVTFeedbackReporting.XCC")
        solo.mkdir("\(gc)/59GAB85EFG.com.apple.dt.XcodeCloud")
        solo.mkdir("\(lib)/Application Scripts/59GAB85EFG.com.apple.dt.XcodeCloud")
        let one = try collect(solo, ["Xcode"], signing: signing)
        XCTAssertEqual(match(one, "\(gc)/59GAB85EFG.com.apple.dt.XcodeCloud"), .appGroup)
        XCTAssertEqual(match(one, "\(lib)/Application Scripts/59GAB85EFG.com.apple.dt.XcodeCloud"), .appGroup,
                       "Application Scripts cũng mang tên App Group")
        XCTAssertFalse(one.contains { $0.isSharedAppFile })
    }

    /// App khác hãng nhưng cùng Team ID cùng khai một group chỉ trong appex: vẫn thấy được.
    func testSameTeamOtherVendorReadDeep() throws {
        let tree = FakeTree()
        app(tree, "/Applications/Messenger.app", "com.facebook.archon")
        app(tree, "/Applications/WhatsApp.app", "net.whatsapp.WhatsApp")
        app(tree, "/Applications/WhatsApp.app/Contents/PlugIns/Share.appex", "net.whatsapp.WhatsApp.Share")
        tree.mkdir("\(lib)/Group Containers/group.com.facebook.family")
        let signing = ["/Messenger.app": SigningInfo(teamID: "TEAMFB0001", appGroups: ["group.com.facebook.family"]),
                       "/WhatsApp.app": SigningInfo(teamID: "TEAMFB0001"),
                       "/Share.appex": SigningInfo(teamID: "TEAMFB0001", appGroups: ["group.com.facebook.family"])]
        let fs = try collect(tree, ["Messenger"], signing: signing)
        XCTAssertEqual(fs.first { $0.target.hasSuffix("group.com.facebook.family") }?.reason,
                       .appRelatedShared(AppRef(name: "Messenger", path: "/Applications/Messenger.app"), match: .appGroup,
                                         sharedWith: ["WhatsApp"]))
    }

    func testXPCServicesWrappedPlugInsAndNestedApps() throws {
        let tree = FakeTree()
        app(tree, "/Applications/LINE.app", "jp.naver.line.mac")
        app(tree, "/Applications/LINE.app/Contents/XPCServices/LINE.MediaService.xpc", "LINE.MediaService")
        app(tree, "/Applications/LINE.app/Contents/XPCServices/Updater.xpc", "org.sparkle-project.InstallerLauncher")
        app(tree, "/Applications/Rocket.app", "com.rocket.ios")
        tree.mkdir("/Applications/Rocket.app/Wrapper/Rocket.app")
        tree.plist("/Applications/Rocket.app/Wrapper/Rocket.app/PlugIns/Tunnel.appex/Info.plist",
                   ["CFBundleIdentifier": "com.rocket.tunnel"])
        app(tree, "/Applications/Xcode.app", "com.apple.dt.Xcode")
        app(tree, "/Applications/Xcode.app/Contents/Applications/Instruments.app", "com.apple.dt.Instruments")
        app(tree, "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app", "com.apple.iphonesimulator")
        let c = "\(lib)/Containers"
        for n in ["LINE.MediaService", "org.sparkle-project.InstallerLauncher", "com.rocket.tunnel"] { tree.mkdir("\(c)/\(n)") }
        tree.mkdir("\(lib)/Application Scripts/LINE.MediaService")
        tree.write("\(lib)/Preferences/com.apple.dt.Instruments.plist")
        tree.write("\(lib)/Preferences/com.apple.iphonesimulator.plist")
        let line = try collect(tree, ["LINE"])
        XCTAssertEqual(match(line, "\(c)/LINE.MediaService"), .embeddedBundleID, "XPC khác hãng nằm trong gói")
        XCTAssertEqual(match(line, "\(lib)/Application Scripts/LINE.MediaService"), .embeddedBundleID)
        XCTAssertNil(match(line, "\(c)/org.sparkle-project.InstallerLauncher"), "Sparkle dùng chung, không phải bằng chứng")
        let rocket = try collect(tree, ["Rocket"])
        XCTAssertEqual(match(rocket, "\(c)/com.rocket.tunnel"), .embeddedBundleID, "appex của app iOS bọc trong Wrapper")
        let xcode = try collect(tree, ["Xcode"])
        XCTAssertEqual(match(xcode, "\(lib)/Preferences/com.apple.dt.Instruments.plist"), .embeddedBundleID)
        XCTAssertEqual(match(xcode, "\(lib)/Preferences/com.apple.iphonesimulator.plist"), .embeddedBundleID)
    }

    /// Bậc gần đúng: Zalo (tiền tố tên + cache updater), Notion (cache updater), Ledger (tên cũ ghép từ bundle id),
    /// Cloudflare (thư mục hãng). Không áp khi app khác cùng tên/hãng còn cài.
    func testLowConfidenceTier() throws {
        let tree = FakeTree()
        app(tree, "/Applications/Zalo.app", "com.vng.zalo")
        app(tree, "/Applications/Notion.app", "notion.id")
        app(tree, "/Applications/Notion Calendar.app", "com.cron.electron")
        app(tree, "/Applications/Ledger Wallet.app", "com.ledger.live")
        app(tree, "/Applications/Cloudflare WARP.app", "com.cloudflare.1dot1dot1dot1.macos")
        let a = "\(lib)/Application Support"
        for n in ["ZaloPC", "ZaloData", "Notion", "NotionCalendarData", "NotionExtra", "Ledger Live", "Ledger Wallet",
                  "Caches/zalo-updater", "Caches/notion-updater", "Caches/notion-calendar-updater", "Caches/other-updater"] {
            tree.mkdir("\(a)/\(n)")
        }
        tree.mkdir("/Library/Application Support/Cloudflare/warp")
        tree.mkdir("\(lib)/Logs/Cloudflare")
        tree.mkdir("\(lib)/Logs/Sync")

        let zalo = try collect(tree, ["Zalo"])
        XCTAssertEqual(match(zalo, "\(a)/ZaloPC"), .namePrefix)
        XCTAssertEqual(match(zalo, "\(a)/ZaloData"), .namePrefix)
        XCTAssertEqual(match(zalo, "\(a)/Caches/zalo-updater"), .updaterCache)
        XCTAssertTrue(AppFileMatch.namePrefix.isLowConfidence)
        XCTAssertFalse(AppFileMatch.updaterCache.isLowConfidence)
        XCTAssertEqual(zalo.first { $0.target == "\(a)/ZaloPC" }?.kind, .trashPath)

        let notion = try collect(tree, ["Notion"])
        XCTAssertEqual(match(notion, "\(a)/Caches/notion-updater"), .updaterCache)
        XCTAssertNil(match(notion, "\(a)/Caches/notion-calendar-updater"))
        XCTAssertNil(match(notion, "\(a)/NotionCalendarData"), "tên app khác (Notion Calendar) là tiền tố: không lấy")
        XCTAssertEqual(match(notion, "\(a)/NotionExtra"), .namePrefix)

        let ledger = try collect(tree, ["Ledger Wallet"])
        XCTAssertEqual(match(ledger, "\(a)/Ledger Live"), .bundleIDWords)
        XCTAssertEqual(match(ledger, "\(a)/Ledger Wallet"), .name)

        let warp = try collect(tree, ["Cloudflare WARP"])
        XCTAssertEqual(match(warp, "/Library/Application Support/Cloudflare"), .vendorFolder)
        XCTAssertEqual(match(warp, "\(lib)/Logs/Cloudflare"), .vendorFolder)
        XCTAssertEqual(match(warp, "/Library/Application Support/Cloudflare/warp"), .vendorSubfolder)

        // app khác cùng hãng còn cài: thư mục hãng dùng chung
        app(tree, "/Applications/1.1.1.1.app", "com.cloudflare.oneonedotone")
        let shared = try collect(tree, ["Cloudflare WARP"])
        XCTAssertTrue(shared.first { $0.target == "\(lib)/Logs/Cloudflare" }?.isSharedAppFile == true)
    }

    /// Tên mất chữ khi chuẩn hóa (QQ音乐 → qq, Ảnh → nh) không dùng để khớp; tên thành phần macOS không khớp.
    func testLossyAndSystemNamesNeverMatchByName() throws {
        let tree = FakeTree()
        app(tree, "/Applications/QQ音乐.app", "com.tencent.QQMusicMac")
        app(tree, "/Applications/Ảnh.app", "com.demo.anh")
        app(tree, "/Applications/Sync.app", "com.sync.desktop")
        app(tree, "/Applications/Music Tool.app", "com.tool.music", extra: ["CFBundleDisplayName": "UU加速器"])
        let a = "\(lib)/Application Support"
        for n in ["QQ", "nh", "uu"] { tree.mkdir("\(a)/\(n)") }
        tree.mkdir("\(lib)/Logs/Sync")
        tree.mkdir("\(lib)/Caches/PassKit")
        tree.write("\(lib)/Preferences/loginwindow.plist")
        let listing = try catalog(tree).load()
        let un = AppUninstaller(env: tree.env, runner: StubRunner(), signing: NoSigningInfoReader())
        for app in listing.apps {
            let fs = try un.collect([app], listing: listing, computeSizes: false)
            XCTAssertEqual(fs.filter { $0.category == .appFiles }.map(\.target), [], app.name)
        }
        XCTAssertTrue(AppUninstaller.normalizationDropsLetters("QQ音乐"))
        XCTAssertTrue(AppUninstaller.normalizationDropsLetters("Điện thoại"))
        XCTAssertFalse(AppUninstaller.normalizationDropsLetters("Visual Studio Code 2"))
    }

    func testXcodeDeveloperDataAndActiveDeveloperDir() throws {
        let tree = FakeTree()
        app(tree, "/Applications/Xcode.app", "com.apple.dt.Xcode")
        tree.mkdir("/Applications/Xcode.app/Contents/Developer")
        app(tree, "/Applications/Other.app", "com.other.app")
        let x = "\(lib)/Developer/Xcode"
        for n in ["DerivedData", "iOS DeviceSupport", "Archives", "UserData"] { tree.mkdir("\(x)/\(n)") }
        let fs = try collect(tree, ["Xcode"])
        XCTAssertEqual(match(fs, "\(x)/DerivedData"), .developerData)
        XCTAssertEqual(match(fs, "\(x)/iOS DeviceSupport"), .developerData)
        XCTAssertEqual(fs.first { $0.target == "\(x)/DerivedData" }?.kind, .trashPath)
        XCTAssertEqual(match(fs, "\(x)/Archives"), .developerArchives)
        XCTAssertEqual(fs.first { $0.target == "\(x)/Archives" }?.kind, .reportOnly, "bản build đã nộp: dữ liệu người dùng")
        XCTAssertFalse(fs.contains { $0.target == "\(x)/UserData" })
        XCTAssertTrue(try collect(tree, ["Other"]).allSatisfy { !$0.target.hasPrefix(x) })

        let listing = try catalog(tree).load()
        // không có link: mặc định /Applications/Xcode.app
        XCTAssertEqual(AppUninstaller.activeDeveloperApps(listing.apps, env: tree.env), ["/Applications/Xcode.app"])
        tree.symlink("/var/db/xcode_select_link", to: "/Library/Developer/CommandLineTools")
        XCTAssertTrue(AppUninstaller.activeDeveloperApps(listing.apps, env: tree.env).isEmpty)
    }

    func testBundleTrashedInFinderIsNotOfferedButLeftoversAre() throws {
        let tree = FakeTree()
        app(tree, "/Applications/Gone.app", "com.demo.gone")
        tree.mkdir("\(lib)/Caches/com.demo.gone")
        let listing = try catalog(tree).load()
        let gone = listing.apps[0]
        try FileManager.default.removeItem(atPath: tree.phys("/Applications/Gone.app"))
        let fs = try AppUninstaller(env: tree.env, runner: StubRunner(), signing: NoSigningInfoReader())
            .collect([gone], listing: listing, computeSizes: false)
        XCTAssertEqual(fs.map(\.target), ["\(lib)/Caches/com.demo.gone"])
    }

    /// Thứ tự gỡ: gói → job launchd → phần còn lại, mục chung cuối cùng; gói không gỡ được thì giữ mọi mục còn lại
    /// của app đó (app vẫn cài thì không mất dữ liệu).
    func testRemovalOrderAndKeepDataWhenBundleFails() throws {
        try XCTSkipIf(getuid() == 0, "root bỏ qua quyền thư mục")
        let tree = FakeTree()
        app(tree, "/Applications/Locked.app", "com.demo.locked")
        app(tree, "/Applications/Open.app", "com.demo.open")
        tree.mkdir("\(lib)/Caches/com.demo.locked")
        tree.mkdir("\(lib)/Caches/com.demo.open")
        tree.plist("\(lib)/LaunchAgents/com.demo.open.agent.plist", ["Label": "com.demo.open.agent", "Program": "/usr/bin/true"])
        tree.mkdir("\(lib)/Group Containers/group.shared")
        let signing = ["/Locked.app": SigningInfo(appGroups: ["group.shared"]), "/Open.app": SigningInfo(appGroups: ["group.shared"])]
        let fs = try collect(tree, ["Locked", "Open"], signing: signing)
        let order = AppUninstaller.removalOrder(fs.reversed())
        XCTAssertEqual(order.map(\.target), [
            "/Applications/Open.app", "\(lib)/LaunchAgents/com.demo.open.agent.plist", "\(lib)/Caches/com.demo.open",
            "/Applications/Locked.app", "\(lib)/Caches/com.demo.locked", "\(lib)/Group Containers/group.shared",
        ])
        // gói Locked bị khóa sau khi gom (ví dụ quyền đổi) → mục còn lại của Locked và mục chung bị giữ
        _ = chmod(tree.phys("/Applications/Locked.app"), 0o555)
        let report = Remover(env: tree.env, runner: StubRunner(), trasher: tree.trasher).removeSelected(order, appVersion: "t")
        let outcome = Dictionary(uniqueKeysWithValues: report.results.map { ($0.target, $0.outcome) })
        XCTAssertEqual(outcome["/Applications/Open.app"], .done)
        XCTAssertEqual(outcome["\(lib)/Caches/com.demo.open"], .done)
        XCTAssertEqual(outcome["/Applications/Locked.app"]?.status, .needsAdmin)
        XCTAssertEqual(outcome["\(lib)/Caches/com.demo.locked"], .skipped(.appKept(app: "Locked")))
        XCTAssertEqual(outcome["\(lib)/Group Containers/group.shared"], .skipped(.appKept(app: "Locked")))
        XCTAssertTrue(tree.exists("\(lib)/Caches/com.demo.locked"))
        _ = chmod(tree.phys("/Applications/Locked.app"), 0o755)
    }

    // MARK: Gỡ thật (Thùng rác giả) + khôi phục

    func testRemovalRoundTripSkipsSharedAndReportsReceipts() throws {
        let tree = FakeTree()
        app(tree, "/Applications/Demo.app", "com.demo.App")
        app(tree, "/Applications/Other.app", "com.other.App")
        tree.writeBytes("\(lib)/Caches/com.demo.App/blob", count: 2_048)
        tree.plist("\(lib)/LaunchAgents/com.demo.App.agent.plist", ["Label": "com.demo.App.agent",
                                                                     "Program": "/Applications/Demo.app/Contents/MacOS/run"])
        tree.mkdir("\(lib)/Group Containers/group.shared")
        let runner = StubRunner()
        runner.set("\(Tool.pkgutil) --pkgs", stdout: "com.demo.App\n")
        let signing = ["/Demo.app": SigningInfo(appGroups: ["group.shared"]), "/Other.app": SigningInfo(appGroups: ["group.shared"])]
        let fs = try collect(tree, ["Demo"], signing: signing, runner: runner, sizes: true)
        XCTAssertGreaterThan(fs.first { $0.target == "\(lib)/Caches/com.demo.App" }?.sizeBytes ?? 0, 0)

        let remover = Remover(env: tree.env, runner: runner, trasher: tree.trasher)
        let report = remover.removeSelected(fs, appVersion: "test")
        let status = Dictionary(uniqueKeysWithValues: report.results.map { ($0.target, $0.outcome.status) })
        XCTAssertEqual(status["/Applications/Demo.app"], .done)
        XCTAssertEqual(status["\(lib)/Caches/com.demo.App"], .done)
        XCTAssertEqual(status["\(lib)/LaunchAgents/com.demo.App.agent.plist"], .done)
        XCTAssertEqual(status["\(lib)/Group Containers/group.shared"], .skipped)
        XCTAssertEqual(status["/var/db/receipts/com.demo.App"], .needsAdmin)
        XCTAssertFalse(tree.exists("/Applications/Demo.app"))
        XCTAssertTrue(tree.exists("\(lib)/Group Containers/group.shared"), "thư mục dùng chung còn nguyên")
        XCTAssertTrue(tree.exists("/Applications/Other.app"))
        XCTAssertTrue(runner.called("\(Tool.launchctl) bootout gui/501/com.demo.App.agent")
                      || runner.calls.contains { $0.first == Tool.launchctl })

        let restore = Restorer(env: tree.env, runner: runner)
            .restore(backupDirectory: try XCTUnwrap(report.backupDirectory))
        XCTAssertTrue(tree.exists("/Applications/Demo.app/Contents/Info.plist"), "\(restore)")
        XCTAssertTrue(tree.exists("\(lib)/Caches/com.demo.App/blob"))
    }
}

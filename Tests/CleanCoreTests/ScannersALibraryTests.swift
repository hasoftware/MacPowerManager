import XCTest
@testable import CleanCore

/// Dựng ScanContext cho test bộ quét nhóm A (tên riêng để không trùng helper của nhóm khác).
enum ScannersAFixture {
    static func context(_ tree: FakeTree, index: AppIndex? = nil, runner: CommandRunner = StubRunner(),
                        cancellation: CancellationToken = CancellationToken()) -> ScanContext {
        ScanContext(env: tree.env, index: index ?? AppIndex(env: tree.env), runner: runner, hasFullDiskAccess: false,
                    cancellation: cancellation)
    }

    /// File thực thi (chmod 755) tại đường dẫn logic.
    static func executable(_ tree: FakeTree, _ logical: String) {
        tree.write(logical, "#!/bin/sh\n")
        _ = chmod(tree.phys(logical), 0o755)
    }

    static let mib = 1_048_576
}

/// Bộ quét tàn dư Library: AppSupport, Caches, Prefs, Containers, SavedState, LibraryMisc (spec A §3.2-3.7).
final class ScannersALibraryTests: XCTestCase {
    private typealias F = ScannersAFixture

    // MARK: AppSupport (+ hành vi _scan_container dùng chung)

    func testAppSupportFlagsOrphansInHomeThenSystem() throws {
        let tree = FakeTree()
        let home = "\(tree.homePath)/Library/Application Support"
        tree.writeBytes("\(home)/com.gone.big/data", count: 2 * F.mib)
        tree.mkdir("\(home)/com.gone.empty")
        tree.mkdir("\(home)/com.alive.app")
        tree.mkdir("\(home)/com.apple.TCC")
        tree.mkdir("\(home)/CrashReporter")                                // SYS_KEEP
        tree.mkdir("\(home)/0A2F4E1B-363A-41F8-BFA9-7706E6A02950")        // UUID
        tree.mkdir("\(home)/.com.hidden.gone")                            // thư mục ẩn
        tree.write("\(home)/com.loose.file.json")                         // file rời ở gốc
        tree.mkdir("/elsewhere/com.linked.gone")
        tree.symlink("\(home)/com.linked.gone", to: tree.phys("/elsewhere/com.linked.gone"))
        tree.mkdir("/Library/Application Support/com.system.gone")
        var idx = AppIndex(env: tree.env)
        idx.registerBundle("com.alive.app", path: "/Applications/Alive.app")

        let fs = try AppSupportScanner().scan(F.context(tree, index: idx))
        XCTAssertEqual(fs.map(\.name), ["com.gone.big", "com.gone.empty", "com.system.gone"])
        XCTAssertEqual(fs[0].severity, .high)
        XCTAssertGreaterThanOrEqual(fs[0].sizeMB, 2)
        XCTAssertEqual(fs[0].reason, .orphanBundleID("com.gone.big"))
        XCTAssertEqual(fs[0].id, "AppSupport|com.gone.big|/Users/tester/Library/Application Support/com.gone.big")
        XCTAssertEqual(fs[0].action, .trashPath(path: "\(home)/com.gone.big"))
        XCTAssertEqual(fs[1].severity, .medium)   // High rỗng → Medium (không phải Info)
        XCTAssertEqual(fs[2].target, "/Library/Application Support/com.system.gone")
        XCTAssertTrue(fs.allSatisfy { $0.category == .appSupport && $0.kind == .trashPath })
    }

    func testAppSupportBareNamesUseAgeAndAliveness() throws {
        let tree = FakeTree()
        tree.env.searchPath = ["/usr/local/bin"]
        F.executable(tree, "/usr/local/bin/sometool")
        let home = "\(tree.homePath)/Library/Application Support"
        for n in ["OldThing", "FreshThing", "Riot Client", "sometool", "ab"] { tree.mkdir("\(home)/\(n)") }
        tree.setModified("\(home)/OldThing", daysAgo: 100)
        tree.setModified("\(home)/FreshThing", daysAgo: 10)
        var idx = AppIndex(env: tree.env)
        idx.registerToken("Client Riot")

        let fs = try AppSupportScanner().scan(F.context(tree, index: idx))
        XCTAssertEqual(fs.map(\.name), ["FreshThing", "OldThing"])
        XCTAssertEqual(fs[0].severity, .info)
        XCTAssertEqual(fs[0].reason, .orphanName("FreshThing", days: 10))
        XCTAssertEqual(fs[1].severity, .medium)
        XCTAssertEqual(fs[1].reason, .orphanName("OldThing", days: 100))
    }

    /// Vỏ .app rỗng không che giấu tàn dư của chính nó; app hợp lệ thì có.
    func testHollowAppDoesNotProtectItsLeftovers() throws {
        let tree = FakeTree()
        tree.makeApp("/Applications/Good.app", bundleID: "com.test.good")
        tree.mkdir("/Applications/Hollow.app/Contents")
        let home = "\(tree.homePath)/Library/Application Support"
        tree.mkdir("\(home)/Good")
        tree.mkdir("\(home)/Hollow")
        tree.mkdir("\(home)/com.test.good")
        tree.mkdir("\(home)/com.hollowvendor.app")   // vendor khác; com.test.* sẽ sống nhờ tiền tố của Good
        let runner = StubRunner()
        runner.set("\(Tool.pkgutil) --pkgs", stdout: "")
        runner.set("\(Tool.launchctl) list", stdout: "")
        let idx = try AppIndex.build(env: tree.env, runner: runner)

        let fs = try AppSupportScanner().scan(F.context(tree, index: idx, runner: runner))
        XCTAssertEqual(fs.map(\.name), ["Hollow", "com.hollowvendor.app"])
    }

    func testMissingDirectoriesYieldNothing() throws {
        let tree = FakeTree()
        let ctx = F.context(tree)
        let scanners: [CleanScanner] = [AppSupportScanner(), CachesScanner(), PreferencesScanner(), ContainersScanner(),
                                        SavedStateScanner(), LibraryMiscScanner()]
        for s in scanners { XCTAssertEqual(try s.scan(ctx), [], s.id) }
    }

    func testCancellationStopsLibraryScanners() {
        let tree = FakeTree()
        tree.mkdir("\(tree.homePath)/Library/Caches/com.gone.a")
        tree.write("\(tree.homePath)/Library/Preferences/com.gone.a.plist")
        tree.mkdir("\(tree.homePath)/Library/Containers/com.gone.a")
        tree.write("\(tree.homePath)/Library/Cookies/com.gone.a.binarycookies")
        let token = CancellationToken()
        token.cancel()
        let ctx = F.context(tree, cancellation: token)
        let scanners: [CleanScanner] = [CachesScanner(), PreferencesScanner(), ContainersScanner(), LibraryMiscScanner()]
        for s in scanners {
            XCTAssertThrowsError(try s.scan(ctx), s.id) { XCTAssertTrue($0 is CancellationError) }
        }
    }

    // MARK: Caches

    func testCachesScansHomeAndSystem() throws {
        let tree = FakeTree()
        tree.mkdir("\(tree.homePath)/Library/Caches/com.gone.cache")
        tree.mkdir("\(tree.homePath)/Library/Caches/com.apple.Safari")
        tree.write("\(tree.homePath)/Library/Caches/com.gone.file")
        tree.mkdir("/Library/Caches/com.gone.syscache")
        let fs = try CachesScanner().scan(F.context(tree))
        XCTAssertEqual(fs.map(\.id), ["Caches|com.gone.cache|/Users/tester/Library/Caches/com.gone.cache",
                                      "Caches|com.gone.syscache|/Library/Caches/com.gone.syscache"])
    }

    // MARK: Prefs

    func testPreferencesRules() throws {
        let tree = FakeTree()
        let p = "\(tree.homePath)/Library/Preferences"
        tree.write("\(p)/com.gone.app.plist")
        tree.write("\(p)/com.alive.app.plist")
        tree.write("\(p)/com.apple.finder.plist")
        tree.write("\(p)/Foo.plist")                                    // không mang bundle id
        tree.write("\(p)/GlobalPreferences.foo.bar.plist")              // GlobalPreferences*
        tree.write("\(p)/.GlobalPreferences.plist")                     // file ẩn
        tree.write("\(p)/com.gone.notplist.json")
        tree.write("/elsewhere/com.linked.gone.plist")
        tree.symlink("\(p)/com.linked.gone.plist", to: tree.phys("/elsewhere/com.linked.gone.plist"))
        tree.mkdir("\(p)/com.dir.gone.plist")                           // thư mục, không phải file
        tree.write("\(p)/ByHost/com.host.gone.0A2F4E1B-363A-41F8-BFA9-7706E6A02950.plist")
        tree.write("\(p)/ByHost/com.mac.gone.001122aabbcc.plist")
        tree.write("\(p)/ByHost/com.alive.app.0A2F4E1B-363A-41F8-BFA9-7706E6A02950.plist")
        tree.write("\(p)/ByHost/.GlobalPreferences.0A2F4E1B-363A-41F8-BFA9-7706E6A02950.plist")
        tree.write("/Library/Preferences/com.sys.gone.plist")
        var idx = AppIndex(env: tree.env)
        idx.registerBundle("com.alive.app", path: "/Applications/Alive.app")

        let fs = try PreferencesScanner().scan(F.context(tree, index: idx))
        XCTAssertEqual(fs.map(\.name), ["com.gone.app", "com.host.gone", "com.mac.gone", "com.sys.gone"])
        XCTAssertTrue(fs.allSatisfy { $0.category == .prefs && $0.severity == .medium })   // file nhỏ → Medium
        XCTAssertEqual(fs[1].id, "Prefs|com.host.gone|/Users/tester/Library/Preferences/ByHost/"
                       + "com.host.gone.0A2F4E1B-363A-41F8-BFA9-7706E6A02950.plist")
        XCTAssertEqual(fs[1].reason, .orphanBundleID("com.host.gone"))
        XCTAssertEqual(fs[3].action, .trashPath(path: "/Library/Preferences/com.sys.gone.plist"))
    }

    /// Hậu tố hex chỉ bị cắt trong ByHost (kể cả quirk thành phần cuối toàn hex).
    func testByHostSuffixStripOnlyInByHost() throws {
        XCTAssertEqual(PreferencesScanner.stripHostSuffix("com.foo.bar.0A2F4E1B-363A-41F8-BFA9-7706E6A02950"), "com.foo.bar")
        XCTAssertEqual(PreferencesScanner.stripHostSuffix("com.foo.cafe"), "com.foo")       // quirk parity
        XCTAssertEqual(PreferencesScanner.stripHostSuffix("com.foo.bar"), "com.foo.bar")
        XCTAssertEqual(PreferencesScanner.stripHostSuffix("com.foo.bar."), "com.foo.bar.")
        XCTAssertEqual(PreferencesScanner.stripHostSuffix("nodots"), "nodots")
        XCTAssertEqual(PreferencesScanner.stripHostSuffix("com.foo.12.34"), "com.foo.12")    // chỉ cắt một lần

        let tree = FakeTree()
        tree.write("\(tree.homePath)/Library/Preferences/com.foo.cafe.plist")
        tree.write("\(tree.homePath)/Library/Preferences/ByHost/com.bar.cafe.plist")
        let fs = try PreferencesScanner().scan(F.context(tree))
        XCTAssertEqual(fs.map(\.name), ["com.foo.cafe", "com.bar"])
    }

    // MARK: Containers

    func testContainersUseMetadataIdentifierForNonBundleNames() throws {
        let tree = FakeTree()
        let c = "\(tree.homePath)/Library/Containers"
        tree.mkdir("\(c)/com.gone.sandboxed")
        tree.plist("\(c)/RandomGenerated/.com.apple.containermanager.metadata.plist",
                   ["MCMMetadataIdentifier": "com.gone.viameta"])
        tree.plist("\(c)/AliveGenerated/.com.apple.containermanager.metadata.plist",
                   ["MCMMetadataIdentifier": "com.alive.app.extension"])
        tree.plist("\(c)/EmptyMeta/.com.apple.containermanager.metadata.plist", ["MCMMetadataIdentifier": ""])
        tree.mkdir("\(c)/NoMetaThing")
        tree.setModified("\(c)/EmptyMeta", daysAgo: 200)
        tree.setModified("\(c)/NoMetaThing", daysAgo: 5)
        tree.mkdir("/elsewhere/com.linked.gone")
        tree.symlink("\(c)/com.linked.gone", to: tree.phys("/elsewhere/com.linked.gone"))
        tree.mkdir("/Library/Containers/com.system.gone")   // không quét /Library/Containers
        var idx = AppIndex(env: tree.env)
        idx.registerBundle("com.alive.app", path: "/Applications/Alive.app")

        let fs = try ContainersScanner().scan(F.context(tree, index: idx))
        XCTAssertEqual(fs.map(\.name), ["EmptyMeta", "NoMetaThing", "com.gone.viameta", "com.gone.sandboxed"])
        XCTAssertEqual(fs.map(\.severity), [.medium, .info, .medium, .medium])
        XCTAssertEqual(fs[2].id, "Containers|com.gone.viameta|/Users/tester/Library/Containers/RandomGenerated")
        XCTAssertEqual(fs[2].action, .trashPath(path: "\(c)/RandomGenerated"))
        XCTAssertTrue(fs.allSatisfy { $0.category == .containers })
    }

    func testGroupContainersStripTeamAndGroupPrefixes() throws {
        let tree = FakeTree()
        let g = "\(tree.homePath)/Library/Group Containers"
        tree.mkdir("\(g)/UBF8T346G9.com.gone.office")
        tree.mkdir("\(g)/group.com.gone.family")
        tree.mkdir("\(g)/group.com.apple.notes")
        tree.mkdir("\(g)/YHUG37CKN8.com.alive.app")
        tree.write("\(g)/default.store")
        var idx = AppIndex(env: tree.env)
        idx.registerBundle("com.alive.app", path: "/Applications/Alive.app")

        let fs = try ContainersScanner().scan(F.context(tree, index: idx))
        XCTAssertEqual(fs.map(\.name), ["UBF8T346G9.com.gone.office", "group.com.gone.family"])   // name giữ tiền tố
        XCTAssertEqual(fs.map(\.reason), [.orphanBundleID("com.gone.office"), .orphanBundleID("com.gone.family")])
        XCTAssertTrue(fs.allSatisfy { $0.category == .groupContainer })
        XCTAssertEqual(fs[1].id, "GroupContainer|group.com.gone.family|/Users/tester/Library/Group Containers/group.com.gone.family")
    }

    // MARK: SavedState

    func testSavedStateStripsSuffix() throws {
        let tree = FakeTree()
        let s = "\(tree.homePath)/Library/Saved Application State"
        tree.mkdir("\(s)/com.gone.app.savedState")
        tree.mkdir("\(s)/com.alive.app.savedState")
        tree.mkdir("\(s)/com.apple.Terminal.savedState")
        tree.mkdir("\(s)/com.nosuffix.gone")
        var idx = AppIndex(env: tree.env)
        idx.registerBundle("com.alive.app", path: "/Applications/Alive.app")

        let fs = try SavedStateScanner().scan(F.context(tree, index: idx))
        XCTAssertEqual(fs.map(\.name), ["com.gone.app", "com.nosuffix.gone"])
        XCTAssertEqual(fs[0].id, "SavedState|com.gone.app|/Users/tester/Library/Saved Application State/com.gone.app.savedState")
        XCTAssertTrue(fs.allSatisfy { $0.category == .savedState })
    }

    // MARK: LibraryMisc (HTTPStorages, WebKit, Application Scripts, Cookies, Logs)

    func testLibraryMiscCategoriesAndOrder() throws {
        let tree = FakeTree()
        let lib = "\(tree.homePath)/Library"
        tree.mkdir("\(lib)/HTTPStorages/com.gone.http")
        tree.write("\(lib)/HTTPStorages/com.gone.http.binarycookies")       // file cạnh: bỏ qua
        tree.mkdir("\(lib)/WebKit/com.gone.web")
        tree.mkdir("\(lib)/WebKit/com.apple.Safari")
        tree.mkdir("\(lib)/Application Scripts/YHUG37CKN8.com.gone.script")
        tree.mkdir("\(lib)/Application Scripts/group.com.alive.app")
        tree.write("\(lib)/Cookies/com.gone.cookie.binarycookies")
        tree.write("\(lib)/Cookies/Cookies.binarycookies")                  // Safari: không giống bundle id
        tree.write("\(lib)/Cookies/com.alive.app.binarycookies")
        tree.write("\(lib)/Cookies/com.gone.other.plist")                   // sai đuôi
        tree.write("/elsewhere/com.linked.gone.binarycookies")
        tree.symlink("\(lib)/Cookies/com.linked.gone.binarycookies", to: tree.phys("/elsewhere/com.linked.gone.binarycookies"))
        tree.mkdir("\(lib)/Logs/DiagnosticReports")
        tree.mkdir("\(lib)/Logs/com.gone.logger")
        tree.mkdir("/Library/Logs/com.system.gone")                         // không quét /Library/Logs
        var idx = AppIndex(env: tree.env)
        idx.registerBundle("com.alive.app", path: "/Applications/Alive.app")

        let fs = try LibraryMiscScanner().scan(F.context(tree, index: idx))
        XCTAssertEqual(fs.map(\.category), [.httpStorage, .webKit, .appScripts, .cookies, .logs])
        XCTAssertEqual(fs.map(\.name), ["com.gone.http", "com.gone.web", "YHUG37CKN8.com.gone.script",
                                        "com.gone.cookie", "com.gone.logger"])
        XCTAssertEqual(fs[0].id, "HTTPStorage|com.gone.http|/Users/tester/Library/HTTPStorages/com.gone.http")
        XCTAssertEqual(fs[2].reason, .orphanBundleID("com.gone.script"))
        XCTAssertEqual(fs[3].id, "Cookies|com.gone.cookie|/Users/tester/Library/Cookies/com.gone.cookie.binarycookies")
        XCTAssertEqual(fs[3].action, .trashPath(path: "\(lib)/Cookies/com.gone.cookie.binarycookies"))
    }

    // MARK: Gắn với ScanEngine

    func testEngineRunsGroupAScannersAndKeepsIDsLogical() throws {
        let tree = FakeTree()
        tree.mkdir("\(tree.homePath)/Library/Caches/com.gone.engine")
        let runner = StubRunner()
        runner.set("\(Tool.pkgutil) --pkgs", stdout: "")
        runner.set("\(Tool.launchctl) list", stdout: "")
        let engine = ScanEngine(env: tree.env, runner: runner,
                                scanners: [CachesScanner(), LoginItemsScanner()])
        let r = try engine.run()
        XCTAssertEqual(r.scannerErrors, [:])
        XCTAssertEqual(Set(r.findings.map(\.id)), [
            "Caches|com.gone.engine|/Users/tester/Library/Caches/com.gone.engine",
            "LoginItem|Background Task Management|(sfltool dumpbtm)",
        ])
        XCTAssertFalse(r.findings.contains { $0.target.hasPrefix(tree.root.path) })
    }
}

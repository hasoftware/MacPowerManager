import XCTest
@testable import CleanCore

/// Port 1:1 các section helper/heuristic của tests/mactrash_test.zsh.
final class MacTrashHelperTests: XCTestCase {
    // MARK: Chuẩn hóa tên

    func testNormName() {
        XCTAssertEqual(Names.norm("Google Chrome"), "googlechrome")         // bỏ dấu cách và hoa thường
        XCTAssertEqual(Names.norm("riot-client_ux.v2"), "riotclientuxv2")   // bỏ ký tự đặc biệt
        // Parity: chữ có dấu bị XÓA, không phiên âm
        XCTAssertEqual(Names.norm("Tiếng Việt Ñandú 2"), "tingvitand2")
        XCTAssertEqual(Names.norm("ÄBC"), "bc")
    }

    // MARK: Nhận dạng bundle id

    func testLooksLikeBundleID() {
        XCTAssertTrue(Names.looksLikeBundleID("com.foo.bar"))
        XCTAssertTrue(Names.looksLikeBundleID("io.sentry"))
        XCTAssertTrue(Names.looksLikeBundleID("pro.betterdisplay.BetterDisplay"))
        XCTAssertFalse(Names.looksLikeBundleID("BetterDisplay"))
        XCTAssertFalse(Names.looksLikeBundleID("default.store"))   // 1 dấu chấm, TLD lạ
        // Hành vi đã biết (rủi ro R3): tên có ≥ 2 dấu chấm luôn "giống bundle id"
        XCTAssertTrue(Names.looksLikeBundleID("foo 1.2.3"))
        XCTAssertTrue(Names.looksLikeBundleID("App.v2"))
        XCTAssertFalse(Names.looksLikeBundleID("a.b"))
    }

    // MARK: Tách Team ID / group.

    func testStripTeamPrefix() {
        XCTAssertEqual(Names.stripTeamPrefix("YHUG37CKN8.com.surfshark.vpn"), "com.surfshark.vpn")
        XCTAssertEqual(Names.stripTeamPrefix("group.com.facebook.family"), "com.facebook.family")
        XCTAssertEqual(Names.stripTeamPrefix("group.UBF8T346G9.com.ms.rdc"), "com.ms.rdc")
        XCTAssertEqual(Names.stripTeamPrefix("sourceforge.app.x"), "sourceforge.app.x")   // 10 ký tự thường
        XCTAssertEqual(Names.stripTeamPrefix("GROUP.com.x"), "GROUP.com.x")
        XCTAssertEqual(Names.stripTeamPrefix("1234567890.x"), "x")
    }

    // MARK: Nhận dạng UUID

    func testLooksLikeUUID() {
        XCTAssertTrue(Names.looksLikeUUID("0A2F4E1B-363A-41F8-BFA9-7706E6A02950"))
        XCTAssertFalse(Names.looksLikeUUID("com.foo.bar"))
        XCTAssertTrue(Names.looksLikeUUID("0a2f4e1b-363a-41f8-bfa9-7706e6a02950"))
    }

    // MARK: Chỉ mục ứng dụng

    private func manualIndex(_ tree: FakeTree) -> AppIndex {
        var idx = AppIndex(env: tree.env)   // searchPath rỗng: không có lệnh nào
        idx.registerBundle("com.surfshark.vpnclient.macos", path: "/Applications/Surfshark.app")
        idx.registerToken("Client Riot")
        idx.registerSystem("stickersd")
        return idx
    }

    func testAppIndexAliveness() {
        let tree = FakeTree()
        let idx = manualIndex(tree)
        XCTAssertTrue(idx.bundleIDAlive("com.surfshark.vpnclient.macos"))          // chính xác
        XCTAssertTrue(idx.bundleIDAlive("com.surfshark.vpn"))                      // anh em cùng vendor
        XCTAssertTrue(idx.bundleIDAlive("com.surfshark.vpnclient.macos.helper"))   // id con
        XCTAssertFalse(idx.bundleIDAlive("com.evilcorp.thing"))                    // vendor khác
        XCTAssertTrue(idx.bundleIDAlive("com.apple.whatever"))
        XCTAssertTrue(idx.nameAlive("Riot Client"))       // khớp theo TỪ
        XCTAssertTrue(idx.nameAlive("riot-client-ux"))    // khớp theo từ có dấu gạch
        XCTAssertTrue(idx.nameAlive("stickersd"))         // thành phần macOS
        XCTAssertFalse(idx.nameAlive("ZzzKhongCoThatDau"))
    }

    func testCommonWordsAreNotEvidence() {
        let tree = FakeTree()
        var idx = manualIndex(tree)
        idx.resetWords()
        idx.registerToken("Some Client")
        XCTAssertFalse(idx.words.contains("client"))
        XCTAssertTrue(idx.words.contains("some"))
    }

    func testOrphanCheckSparesSystemFolders() {
        let tree = FakeTree()
        var idx = manualIndex(tree)
        idx.resetWords()
        idx.registerToken("Some Client")
        let p = tree.mkdir("/sb")
        XCTAssertEqual(idx.orphanCheck(name: "com.apple.Safari", path: p), .alive)
        XCTAssertEqual(idx.orphanCheck(name: "is.workflow.my.app", path: p), .alive)
        XCTAssertEqual(idx.orphanCheck(name: "systemgroup.com.apple.x", path: p), .alive)
        XCTAssertEqual(idx.orphanCheck(name: "group.com.apple.x", path: p), .alive)   // com.apple lồng bên trong
        XCTAssertEqual(idx.orphanCheck(name: "logic", path: p), .alive)               // tài nguyên Pro dùng chung
    }

    // MARK: plist_get

    func testPlistGet() {
        let tree = FakeTree()
        let f = tree.phys("/sb/t.plist")
        tree.write("/sb/t.plist", """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>com.test.job</string>
        </dict></plist>
        """)
        XCTAssertEqual(Plist.get(f, "Label"), "com.test.job")
        XCTAssertNil(Plist.get(f, "KhongCo"))
        XCTAssertNil(Plist.get(tree.phys("/sb/khong-ton-tai.plist"), "Label"))   // không nhét thông báo lỗi vào biến
    }

    // MARK: Nhận dạng bundle ứng dụng

    private func makeBundles(_ tree: FakeTree) {
        tree.makeApp("/apps/Good.app", bundleID: "com.test.Good")
        tree.makeApp("/apps/NoExe.app", bundleID: "com.test.NoExe", withExecutable: false)
        tree.mkdir("/apps/Hollow.app/Contents")   // còn vỏ, không Info.plist
        tree.mkdir("/apps/Empty.app")             // rỗng hoàn toàn
        // App iOS đóng gói: Info.plist nằm trong Wrapper/, không có thư mục Contents
        tree.plist("/apps/Wrapped.app/Wrapper/Inner.app/Info.plist", ["CFBundleIdentifier": "vn.test.Wrapped"])
    }

    func testAppBundleRecognition() {
        let tree = FakeTree()
        makeBundles(tree)
        let env = tree.env
        XCTAssertTrue(env.appBundleValid("/apps/Good.app"))
        XCTAssertFalse(env.appBundleValid("/apps/NoExe.app"))
        XCTAssertFalse(env.appBundleValid("/apps/Hollow.app"))
        XCTAssertFalse(env.appBundleValid("/apps/Empty.app"))
        XCTAssertTrue(env.appBundleValid("/apps/Wrapped.app"))
        XCTAssertEqual(env.bundleIDOfApp("/apps/Wrapped.app"), "vn.test.Wrapped")
        XCTAssertEqual(env.bundleIDOfApp("/apps/Good.app"), "com.test.Good")
        XCTAssertEqual(env.appBundleProblem("/apps/Hollow.app"), .hollowApp)
        XCTAssertEqual(env.appBundleProblem("/apps/NoExe.app"), .brokenApp(executable: "run"))
    }

    /// Bài test quan trọng nhất về hành vi: vỏ .app còn nằm đó nhưng ruột đã gỡ không được coi là "đang cài".
    /// Chạy `AppIndex.build` thật trên `/Applications` của cây giả.
    func testHollowAppDoesNotHideItsLeftovers() throws {
        let tree = FakeTree()
        tree.makeApp("/Applications/Good.app", bundleID: "com.test.Good")
        tree.mkdir("/Applications/Hollow.app/Contents")
        let runner = StubRunner()
        runner.set("\(Tool.pkgutil) --pkgs", stdout: "")
        runner.set("\(Tool.launchctl) list", stdout: "")
        let idx = try AppIndex.build(env: tree.env, runner: runner)
        XCTAssertTrue(idx.nameAlive("Good"))
        XCTAssertFalse(idx.nameAlive("Hollow"))
        XCTAssertEqual(idx.deadApps.count, 1)
        XCTAssertEqual(idx.deadApps, ["/Applications/Hollow.app"])
    }
}

import XCTest
@testable import CleanCore

/// Port 1:1 các chốt an toàn của tests/mactrash_test.zsh (is_trash_path 13 + PurgeTrash 6 = 19 ca thùng rác,
/// _dir_is_empty, xóa một phần, is_deletable_path, is_precious_path, PurgeAny). Nhóm này không bao giờ được đỏ.
final class SafetyGuardTests: XCTestCase {
    private func session(_ tree: FakeTree) throws -> BackupSession {
        try BackupSession(env: tree.env, appVersion: "test", macOSVersion: "test")
    }

    private func remover(_ tree: FakeTree) -> Remover {
        Remover(env: tree.env, runner: StubRunner(), trasher: tree.trasher)
    }

    /// HOME giả: .Trash/sub/, quantrong/khong-duoc-xoa.txt, .Trash/rac.txt, .Trash/link-ra-ngoai → quantrong.
    private func trashHome() -> FakeTree {
        let tree = FakeTree()
        let h = tree.homePath
        tree.mkdir("\(h)/.Trash/sub")
        tree.write("\(h)/quantrong/khong-duoc-xoa.txt", "dữ liệu thật")
        tree.write("\(h)/.Trash/rac.txt")
        tree.symlink("\(h)/.Trash/link-ra-ngoai", to: tree.phys("\(h)/quantrong"))
        return tree
    }

    // MARK: is_trash_path - chốt an toàn rm -rf

    func testIsTrashPath() {
        let tree = trashHome()
        let env = tree.env, h = tree.homePath
        XCTAssertTrue(env.isTrashPath("\(h)/.Trash/rac.txt"))           // file trong Thùng rác
        XCTAssertTrue(env.isTrashPath("\(h)/.Trash/sub/x"))             // trong thư mục con (không tồn tại)
        XCTAssertTrue(env.isTrashPath("\(h)/.Trash/link-ra-ngoai"))     // symlink trong Thùng rác
        XCTAssertFalse(env.isTrashPath("\(h)/.Trash"))                  // CHÍNH thư mục gốc Thùng rác
        XCTAssertFalse(env.isTrashPath("\(h)/.Trash/../quantrong"))     // thoát ra bằng ..
        XCTAssertFalse(env.isTrashPath("\(h)/quantrong"))
        XCTAssertFalse(env.isTrashPath(h))
        XCTAssertFalse(env.isTrashPath("/"))
        XCTAssertFalse(env.isTrashPath("/Applications/Safari.app"))
        XCTAssertFalse(env.isTrashPath("rac.txt"))                      // tương đối
        XCTAssertFalse(env.isTrashPath(""))
    }

    /// /var là symlink tới /private/var: chỉ phân giải một vế thì từ chối nhầm mục hợp lệ (đã xảy ra: 67/67).
    func testIsTrashPathResolvesBothSides() {
        let tree = FakeTree()
        tree.mkdir("/varlink/real/.Trash")
        tree.symlink("/varlink/alias", to: tree.phys("/varlink/real"))
        var env = tree.env
        env.userTrashPath = "/varlink/alias/.Trash"
        XCTAssertTrue(env.isTrashPath("/varlink/real/.Trash/x"))    // symlink ở giữa đường dẫn vẫn khớp
        XCTAssertTrue(env.isTrashPath("/varlink/alias/.Trash/x"))   // đường dẫn qua alias cũng khớp
    }

    /// Cùng các ca trên với root thật `/` và HOME là thư mục tạm dưới /var/folders (= /private/var/folders).
    func testIsTrashPathWithRealRootUnderVarFolders() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("CleanCoreTrash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent(".Trash/sub"), withIntermediateDirectories: true)
        let h = tmp.path
        let env = ScanEnvironment(homePath: h)
        XCTAssertTrue(env.isTrashPath("\(h)/.Trash/x"))
        XCTAssertTrue(env.isTrashPath(PathResolver.resolve(h) + "/.Trash/sub/y"))
        XCTAssertFalse(env.isTrashPath("\(h)/.Trash"))
        XCTAssertFalse(env.isTrashPath("\(h)/.Trash/../x"))
        XCTAssertTrue(env.isTrashPath("/Volumes/Data/.Trashes/501/x"))
        XCTAssertFalse(env.isTrashPath("/Volumes/Data/.Trashes/501"))
    }

    // MARK: PurgeTrash từ chối mọi thứ ngoài Thùng rác

    func testPurgeTrashRefusesOutsideTrash() throws {
        let tree = trashHome()
        let h = tree.homePath
        let s = try session(tree)
        let r = remover(tree)

        let outside = finding(.trash, .info, "x", target: "\(h)/quantrong", action: .purgeTrash(path: "\(h)/quantrong"))
        XCTAssertEqual(r.removeOne(outside, session: s), .failed(.notInTrash))          // trả mã lỗi
        XCTAssertTrue(tree.exists("\(h)/quantrong/khong-duoc-xoa.txt"))                  // còn nguyên

        let rac = finding(.trash, .info, "rac", target: "\(h)/.Trash/rac.txt", action: .purgeTrash(path: "\(h)/.Trash/rac.txt"))
        XCTAssertEqual(r.removeOne(rac, session: s), .done)                              // mục hợp lệ xóa được
        XCTAssertFalse(tree.exists("\(h)/.Trash/rac.txt"))                               // đã biến mất

        let link = finding(.trash, .info, "l", target: "\(h)/.Trash/link-ra-ngoai",
                           action: .purgeTrash(path: "\(h)/.Trash/link-ra-ngoai"))
        _ = r.removeOne(link, session: s)
        XCTAssertFalse(FileProbe.isSymlink(tree.phys("\(h)/.Trash/link-ra-ngoai")))      // symlink đã xóa
        XCTAssertTrue(FileProbe.isRegularFile(tree.phys("\(h)/quantrong/khong-duoc-xoa.txt")))   // ĐÍCH không bị xóa
    }

    // MARK: _dir_is_empty

    func testDirIsEmpty() {
        let tree = FakeTree()
        tree.mkdir("/sb/rong")
        tree.write("/sb/cofile/f")
        XCTAssertTrue(tree.env.dirIsEmpty("/sb/rong"))
        XCTAssertFalse(tree.env.dirIsEmpty("/sb/cofile"))
        tree.write("/sb/rong/.an", "y")
        XCTAssertFalse(tree.env.dirIsEmpty("/sb/rong"))   // file ẩn cũng tính là có
    }

    // MARK: Xóa được nội dung nhưng không gỡ được vỏ = xong MỘT PHẦN

    func testPurgeAnyPartialWhenShellRemains() throws {
        try XCTSkipIf(getuid() == 0, "root bỏ qua quyền thư mục")
        let tree = FakeTree()
        tree.write("/sb/cha/con/f")
        let s = try session(tree)
        chmod(tree.phys("/sb/cha"), 0o500)
        let f = finding(.disk, .high, "con", target: "/sb/cha/con", action: .purgeAny(path: "/sb/cha/con"))
        let outcome = remover(tree).removeOne(f, session: s)
        chmod(tree.phys("/sb/cha"), 0o700)
        XCTAssertEqual(outcome, .partial(.emptiedKeptFolder))   // một phần, không phải lỗi
        XCTAssertTrue(tree.env.dirIsEmpty("/sb/cha/con"))       // nội dung đã sạch
    }

    // MARK: is_deletable_path

    private func assertDeletableRules(_ env: ScanEnvironment, file: StaticString = #filePath, line: UInt = #line) {
        let h = env.homePath
        XCTAssertFalse(env.isDeletablePath("/"), file: file, line: line)
        XCTAssertFalse(env.isDeletablePath("/Library"), file: file, line: line)
        XCTAssertFalse(env.isDeletablePath("/Users"), file: file, line: line)
        XCTAssertFalse(env.isDeletablePath("/Applications"), file: file, line: line)
        XCTAssertFalse(env.isDeletablePath("/System/Library"), file: file, line: line)   // SIP
        XCTAssertFalse(env.isDeletablePath("/usr/local"), file: file, line: line)
        XCTAssertFalse(env.isDeletablePath("/private/var/db"), file: file, line: line)
        XCTAssertFalse(env.isDeletablePath("/Library/Developer"), file: file, line: line)
        XCTAssertFalse(env.isDeletablePath(h), file: file, line: line)                   // chính thư mục nhà
        XCTAssertFalse(env.isDeletablePath("/khongcothat"), file: file, line: line)      // một cấp ở gốc
        XCTAssertFalse(env.isDeletablePath("abc/def"), file: file, line: line)           // tương đối
        XCTAssertFalse(env.isDeletablePath(""), file: file, line: line)
        XCTAssertTrue(env.isDeletablePath("\(h)/Library/Caches/foo"), file: file, line: line)
        XCTAssertTrue(env.isDeletablePath("/Applications/Foo.app"), file: file, line: line)
        XCTAssertTrue(env.isDeletablePath("/Library/Developer/CoreSimulator/Caches"), file: file, line: line)
    }

    func testIsDeletablePathFakeRoot() {
        let tree = FakeTree()
        tree.mkdir("/Library/Developer")
        tree.mkdir("/Users/other")
        tree.mkdir("/Users/Shared")
        assertDeletableRules(tree.env)
        let env = tree.env
        XCTAssertEqual(env.deletionRefusal(for: "/Library"), .criticalSystemDir)
        XCTAssertEqual(env.deletionRefusal(for: "/System/Library"), .sipProtected)
        XCTAssertEqual(env.deletionRefusal(for: tree.homePath), .homeDir)
        XCTAssertEqual(env.deletionRefusal(for: "/Users/other"), .otherUserHome)
        XCTAssertEqual(env.deletionRefusal(for: "/Users/Shared"), .otherUserHome)
        XCTAssertEqual(env.deletionRefusal(for: "/khongcothat"), .rootLevel)
        XCTAssertEqual(env.deletionRefusal(for: "abc"), .invalidPath)
        XCTAssertEqual(env.deletionRefusal(for: "\(tree.homePath)/Library/Caches/../.."), .homeDir)
        XCTAssertEqual(env.deletionRefusal(for: "/Library/Caches/../Preferences/"), .criticalSystemDir)
    }

    /// Root thật: chỉ so chuỗi + realpath, không ghi gì.
    func testIsDeletablePathRealRoot() {
        assertDeletableRules(ScanEnvironment(homePath: FileManager.default.homeDirectoryForCurrentUser.path))
        let env = ScanEnvironment(homePath: FileManager.default.homeDirectoryForCurrentUser.path)
        XCTAssertFalse(env.isDeletablePath("/var/db"))     // /var/db → /private/var/db
        XCTAssertFalse(env.isDeletablePath("/etc"))        // /etc → /private/etc
        XCTAssertFalse(env.isDeletablePath("/usr/bin/zsh"))
    }

    // MARK: is_precious_path

    func testIsPreciousPath() {
        let tree = FakeTree()
        let env = tree.env, h = tree.homePath
        XCTAssertTrue(env.isPreciousPath("\(h)/Documents/x"))
        XCTAssertTrue(env.isPreciousPath("\(h)/Pictures/y"))
        XCTAssertTrue(env.isPreciousPath("\(h)/Library/Mobile Documents/z"))
        XCTAssertFalse(env.isPreciousPath("\(h)/Library/Caches/z"))
        XCTAssertTrue(env.isPreciousPath("\(h)/Downloads"))
    }

    // MARK: PurgeAny từ chối đường dẫn hệ thống

    func testPurgeAnyRefusesSystemPath() throws {
        let tree = FakeTree()
        tree.write("/Library/keep.txt")
        let s = try session(tree)
        let f = finding(.disk, .high, "lib", target: "/Library", action: .purgeAny(path: "/Library"))
        XCTAssertEqual(remover(tree).removeOne(f, session: s), .failed(.refused(.criticalSystemDir)))
        XCTAssertTrue(tree.env.isDirectory("/Library"))
        XCTAssertTrue(tree.exists("/Library/keep.txt"))
    }

    // MARK: Phân giải đường dẫn kiểu ${p:A}

    func testResolvedPath() throws {
        let tree = FakeTree()
        tree.mkdir("/t/real/T")
        tree.symlink("/t/T", to: tree.phys("/t/real/T"))
        let env = tree.env
        XCTAssertEqual(env.resolved("/t/T/x/.."), "/t/real/T")          // .. theo từ vựng TRƯỚC
        XCTAssertEqual(env.resolved("/t/T/../T"), "/t/real/T")
        XCTAssertEqual(env.resolved("/t/nonexist/x/../y"), "/t/nonexist/y")
        XCTAssertEqual(env.resolved("/t/real/T/"), "/t/real/T")         // bỏ / cuối
        XCTAssertEqual(env.resolved("/t/./real//T"), "/t/real/T")
        // Root thật: giữ /private
        XCTAssertEqual(PathResolver.resolve("/var/root/.Trash"), "/private/var/root/.Trash")
        XCTAssertEqual(PathResolver.resolve("/etc"), "/private/etc")
        XCTAssertEqual(PathResolver.resolve("/tmp/nonexist-\(UUID().uuidString)/x/../y").hasPrefix("/private/tmp/"), true)
        XCTAssertEqual(PathResolver.parent("/a/b/"), "/a")
        XCTAssertEqual(PathResolver.parent("/x"), "/")
        XCTAssertEqual(PathResolver.tail("/a/.Trash/"), ".Trash")
        XCTAssertEqual(PathResolver.tail("/"), "")
        XCTAssertEqual(SafetyGuards.isSIPPath("/System"), false)
        XCTAssertEqual(SafetyGuards.isSIPPath("/usr/local/bin/x"), false)
        XCTAssertEqual(SafetyGuards.isSIPPath("/usr/libexec/x"), true)
    }
}

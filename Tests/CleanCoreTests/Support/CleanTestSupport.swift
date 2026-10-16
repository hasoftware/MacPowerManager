import Foundation
import XCTest
@testable import CleanCore

/// Cây thư mục giả cho test: `root` là thư mục tạm riêng, home logic `/Users/tester` (vật lý `root/Users/tester`).
/// Không bao giờ chạm hệ thống thật. Dùng chung cho test lõi và test bộ quét.
final class FakeTree {
    let root: URL
    let homePath = "/Users/tester"
    var env: ScanEnvironment

    init(now: Date = Date()) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("CleanCoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = base
        env = ScanEnvironment(root: base, homePath: "/Users/tester", uid: 501, userName: "tester",
                              shellEnvironment: nil, searchPath: [], now: now)
        mkdir(homePath)
    }

    deinit {
        // Trả quyền ghi để xóa được cả thư mục đã chmod trong test.
        FakeTree.makeWritable(root.path)
        try? FileManager.default.removeItem(at: root)
    }

    private static func makeWritable(_ path: String) {
        guard FileProbe.isRealDirectory(path) else { return }
        _ = chmod(path, 0o755)
        for name in FileProbe.childNames(path) { makeWritable(path + "/" + name) }
    }

    /// Đường dẫn vật lý của đường dẫn logic.
    func phys(_ logical: String) -> String { env.physicalPath(logical) }

    /// Thùng rác giả (vật lý), không phải Thùng rác thật.
    var trashDir: URL { root.appendingPathComponent("FakeTrash") }
    var trasher: DirectoryTrasher { DirectoryTrasher(trashDir: trashDir) }

    @discardableResult
    func mkdir(_ logical: String) -> String {
        try? FileManager.default.createDirectory(atPath: phys(logical), withIntermediateDirectories: true)
        return logical
    }

    @discardableResult
    func write(_ logical: String, _ content: String = "x") -> String {
        mkdir(PathResolver.parent(logical))
        FileManager.default.createFile(atPath: phys(logical), contents: Data(content.utf8))
        return logical
    }

    /// File có kích thước thật (byte) để kiểm tra dung lượng.
    @discardableResult
    func writeBytes(_ logical: String, count: Int) -> String {
        mkdir(PathResolver.parent(logical))
        FileManager.default.createFile(atPath: phys(logical), contents: Data(repeating: 0x41, count: count))
        return logical
    }

    /// Symlink tại `logical` trỏ tới chuỗi `destination` NGUYÊN VĂN (không đổi sang vật lý).
    @discardableResult
    func symlink(_ logical: String, to destination: String) -> String {
        mkdir(PathResolver.parent(logical))
        try? FileManager.default.createSymbolicLink(atPath: phys(logical), withDestinationPath: destination)
        return logical
    }

    @discardableResult
    func plist(_ logical: String, _ dict: [String: Any]) -> String {
        mkdir(PathResolver.parent(logical))
        let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        FileManager.default.createFile(atPath: phys(logical), contents: data)
        return logical
    }

    /// Đặt mtime lùi `days` ngày so với `env.now`.
    func setModified(_ logical: String, daysAgo days: Int) {
        let d = env.now.addingTimeInterval(-Double(days) * 86_400 - 60)
        try? FileManager.default.setAttributes([.modificationDate: d], ofItemAtPath: phys(logical))
    }

    /// App bundle như `mk_app` của bộ test zsh.
    func makeApp(_ logical: String, bundleID: String?, executable: String? = "run", withExecutable: Bool = true) {
        mkdir(logical + "/Contents/MacOS")
        if let bundleID {
            var d: [String: Any] = ["CFBundleIdentifier": bundleID]
            if let executable { d["CFBundleExecutable"] = executable }
            plist(logical + "/Contents/Info.plist", d)
        }
        if withExecutable, let executable { write(logical + "/Contents/MacOS/" + executable, "bin") }
    }

    func exists(_ logical: String) -> Bool { FileProbe.lexists(phys(logical)) }
    func read(_ logical: String) -> String? { try? String(contentsOfFile: phys(logical), encoding: .utf8) }
}

/// CommandRunner giả: trả output cố định theo "executable arg1 arg2...", ghi lại mọi lời gọi.
/// Lệnh không khai báo → status 1, output rỗng.
final class StubRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: CommandResult] = [:]
    private var _calls: [[String]] = []

    init(_ responses: [String: CommandResult] = [:]) {
        self.responses = responses
    }

    func set(_ command: String, _ result: CommandResult) {
        lock.lock(); responses[command] = result; lock.unlock()
    }

    func set(_ command: String, stdout: String) {
        set(command, CommandResult(status: 0, stdout: stdout))
    }

    var calls: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    func called(_ command: String) -> Bool {
        calls.contains { $0.joined(separator: " ") == command }
    }

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
        lock.lock(); defer { lock.unlock() }
        _calls.append([executable] + arguments)
        return lookup(([executable] + arguments).joined(separator: " "))
    }

    private func lookup(_ key: String) -> CommandResult {
        responses[key] ?? CommandResult(status: 1)
    }
}

/// Bộ quét giả cho test ScanEngine.
struct StaticScanner: CleanScanner {
    let id: String
    let findings: [Finding]
    var cancelAfter: CancellationToken?

    func scan(_ context: ScanContext) throws -> [Finding] {
        cancelAfter?.cancel()
        return findings
    }
}

func finding(_ cat: CleanCategory = .caches, _ sev: Severity = .info, _ name: String, target: String = "t",
             mb: Int = 0, action: CleanAction = .reportOnly) -> Finding {
    Finding(category: cat, severity: sev, name: name, target: target, reason: .helperOrphan,
            sizeBytes: Int64(mb) * 1_048_576, action: action)
}

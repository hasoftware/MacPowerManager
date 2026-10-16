import CommonCrypto
import Foundation

/// Một dòng manifest (`bk_record kind orig rel extra`) + các trường bổ sung chỉ có trong manifest.json.
public struct ManifestEntry: Codable, Sendable, Equatable {
    /// Raw value của `CleanKind` (để đọc được cả kind lạ trong manifest cũ).
    public var kind: String
    /// Đường dẫn gốc (logic) hoặc định danh.
    public var original: String
    /// File backup tương đối với thư mục backup (`files/001_x`).
    public var backupRel: String?
    /// TrashPath: `user:group`; Symlink: đích; PathEntry: dir; LaunchdJob: `domain/label`; TccReset: service...
    public var extra: String?
    /// Chủ sở hữu gốc `user:group` (TrashPath).
    public var owner: String?
    /// Đường dẫn thực tế trong Thùng rác (logic). Khôi phục dùng nó trước tiên thay vì tra theo tên cuối.
    public var trashedPath: String?
    public var findingID: String?
    /// Băm nội dung file ngay sau khi app ghi (PathEntry/EnvLine) - phát hiện người dùng sửa thêm sau lần dọn.
    public var contentHashAfter: String?
    /// Backup là nội dung file ĐÍCH vì file gốc là symlink (dotfiles).
    public var backupIsSymlinkTarget: Bool?
    /// inode + thiết bị của mục ngay sau khi vào Thùng rác (TrashPath): tên trong Thùng rác có thể bị dùng lại.
    public var trashedInode: UInt64?
    public var trashedDevice: Int64?
    public var at: Date

    public init(kind: String, original: String, backupRel: String? = nil, extra: String? = nil,
                owner: String? = nil, trashedPath: String? = nil, findingID: String? = nil,
                contentHashAfter: String? = nil, backupIsSymlinkTarget: Bool? = nil,
                trashedInode: UInt64? = nil, trashedDevice: Int64? = nil, at: Date = Date()) {
        self.kind = kind
        self.original = original
        self.backupRel = backupRel
        self.extra = extra
        self.owner = owner
        self.trashedPath = trashedPath
        self.findingID = findingID
        self.contentHashAfter = contentHashAfter
        self.backupIsSymlinkTarget = backupIsSymlinkTarget
        self.trashedInode = trashedInode
        self.trashedDevice = trashedDevice
        self.at = at
    }

    /// Dòng TSV 4 cột như zsh. Ô TRỐNG ghi thành "-": TAB là ký tự khoảng trắng của IFS, nên
    /// `IFS=$'\t' read -r a b c d` GỘP hai tab liền nhau -> các cột sau bị dồn lên, restore đọc nhầm cột (symlink
    /// từng được tạo lại với đích rỗng). Trường chứa TAB/xuống dòng → nil (chỉ ghi JSON).
    public var tsvLine: String? {
        let cols = [kind, original, backupRel ?? "", extra ?? ""]
        if cols.contains(where: { $0.contains("\t") || $0.contains("\n") || $0.contains("\r") }) { return nil }
        return cols.map { $0.isEmpty ? "-" : $0 }.joined(separator: "\t") + "\n"
    }

    /// Đọc lại một dòng TSV (`-` → rỗng). Dòng không có kind → nil.
    public init?(tsvLine line: String) {
        var cols = line.components(separatedBy: "\t")
        // `read -r kind orig rel extra`: phần thừa dồn vào cột cuối
        if cols.count > 4 { cols = Array(cols[0..<3]) + [cols[3...].joined(separator: "\t")] }
        while cols.count < 4 { cols.append("") }
        let v = cols.map { $0 == "-" ? "" : $0 }
        guard !v[0].isEmpty else { return nil }
        self.init(kind: v[0], original: v[1], backupRel: v[2].isEmpty ? nil : v[2],
                  extra: v[3].isEmpty ? nil : v[3], at: Date(timeIntervalSince1970: 0))
    }
}

/// manifest.json - nguồn sự thật cho app.
public struct Manifest: Codable, Sendable {
    public var format: Int
    public var createdAt: Date
    public var app: String
    public var appVersion: String
    public var macOS: String
    public var isRoot: Bool
    public var entries: [ManifestEntry]
}

/// Phiên sao lưu của một lần dọn (`backup_init` + `bk_save_file` + `bk_record`).
///
/// Trạng thái `seq`/map đã-backup nằm trong đối tượng phiên (class), không copy theo giá trị: bản zsh từng trả kết
/// quả qua $(...) chạy trong subshell làm mất BK_SEQ/BK_SAVED; hai mục cùng sửa ~/.zshrc nhận cùng tên file backup
/// và lần chép thứ hai GHI ĐÈ bản gốc bằng nội dung đã sửa -> mất khả năng hoàn tác.
public final class BackupSession: @unchecked Sendable {
    public static let manifestJSONName = "manifest.json"
    public static let manifestTSVName = "manifest.tsv"
    public static let restoreScriptName = "restore.sh"
    public static let logName = "log.txt"

    /// Thư mục backup (vật lý): `dataDir/<yyyyMMdd_HHmmss>[_n]/`.
    public let directory: URL
    public let env: ScanEnvironment
    private let lock = NSLock()
    private var manifest: Manifest
    private var seq = 0
    private var saved: [String: String] = [:]

    public var filesDirectory: URL { directory.appendingPathComponent("files") }

    /// `backup_init`. Thư mục trùng giây thì thêm hậu tố `_2`, `_3`... (zsh dùng lại thư mục và truncate manifest
    /// -> mất manifest của lần dọn trước).
    public init(env: ScanEnvironment, appVersion: String, macOSVersion: String) throws {
        self.env = env
        let fm = FileManager.default
        try fm.createDirectory(at: env.dataDir, withIntermediateDirectories: true)
        let stamp = BackupSession.timestamp(env.now)
        var dir = env.dataDir.appendingPathComponent(stamp)
        var n = 2
        while FileProbe.lexists(dir.path) {
            dir = env.dataDir.appendingPathComponent("\(stamp)_\(n)")
            n += 1
        }
        try fm.createDirectory(at: dir.appendingPathComponent("files"), withIntermediateDirectories: true)
        directory = dir
        manifest = Manifest(format: 1, createdAt: env.now, app: "MacPowerManager", appVersion: appVersion,
                            macOS: macOSVersion, isRoot: env.isRoot, entries: [])
        try Data().write(to: dir.appendingPathComponent(BackupSession.manifestTSVName))
        try writeManifestJSON()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let header = "MacPowerManager \(appVersion) - \(f.string(from: env.now))\n"
            + "macOS \(macOSVersion)  root=\(env.isRoot ? "yes" : "no")\n\n"
        try Data(header.utf8).write(to: dir.appendingPathComponent(BackupSession.logName))
    }

    /// `yyyyMMdd_HHmmss` theo giờ địa phương, locale POSIX.
    public static func timestamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: d)
    }

    public var entries: [ManifestEntry] {
        lock.lock(); defer { lock.unlock() }
        return manifest.entries
    }

    /// `bk_save_file(src)` (logic) → `files/NNN_<tên>` hoặc nil. Mỗi file chỉ chép MỘT lần, ở trạng thái trước mọi
    /// thay đổi (khóa = chuỗi `src` nguyên văn). `src` là symlink (dotfiles) → chép NỘI DUNG file đích để backup tự
    /// đứng được.
    public func saveFile(_ src: String) -> String? {
        saveFileDetailed(src)?.rel
    }

    public func saveFileDetailed(_ src: String) -> (rel: String, isSymlinkTarget: Bool)? {
        lock.lock(); defer { lock.unlock() }
        let phys = env.physicalPath(src)
        guard FileProbe.exists(phys) else { return nil }
        if let rel = saved[src] { return (rel, FileProbe.isSymlink(phys)) }
        seq += 1
        let safe = String(String.UnicodeScalarView(PathResolver.tail(src).unicodeScalars.map { u -> Unicode.Scalar in
            (("A"..."Z").contains(u) || ("a"..."z").contains(u) || ("0"..."9").contains(u) || u == "." || u == "_" || u == "-")
                ? u : "_"
        }))
        let rel = "files/" + String(format: "%03d", seq) + "_" + safe
        let isLink = FileProbe.isSymlink(phys)
        let source = isLink ? PathResolver.resolve(phys) : phys
        do {
            try FileManager.default.copyItem(atPath: source, toPath: directory.appendingPathComponent(rel).path)
        } catch {
            return nil
        }
        saved[src] = rel
        return (rel, isLink)
    }

    /// `bk_record`: ghi đồng thời manifest.json (nguyên tử, sau MỖI entry để dừng giữa chừng vẫn còn manifest) và
    /// manifest.tsv (cho restore.sh).
    public func record(_ entry: ManifestEntry) {
        lock.lock(); defer { lock.unlock() }
        manifest.entries.append(entry)
        try? writeManifestJSON()
        if let line = entry.tsvLine {
            appendLine(line, to: BackupSession.manifestTSVName)
        } else {
            appendLine("TSV skipped (tab/newline in field): \(entry.kind)\n", to: BackupSession.logName)
        }
    }

    /// Ghi một dòng vào log.txt.
    public func log(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        appendLine(line + "\n", to: BackupSession.logName)
    }

    private func appendLine(_ s: String, to name: String) {
        let url = directory.appendingPathComponent(name)
        guard let h = try? FileHandle(forWritingTo: url) else {
            try? Data(s.utf8).write(to: url)
            return
        }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: Data(s.utf8))
    }

    private func writeManifestJSON() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: directory.appendingPathComponent(BackupSession.manifestJSONName),
                                       options: .atomic)
    }

    /// `write_restore_script`: sinh restore.sh chạy độc lập (`zsh restore.sh`).
    public func writeRestoreScript() throws {
        let url = directory.appendingPathComponent(BackupSession.restoreScriptName)
        try Data(RestoreScript.render(entries: entries).utf8).write(to: url, options: .atomic)
        _ = chmod(url.path, 0o755)
    }
}

/// SHA-256 (hex thường) để phát hiện file bị sửa sau lần dọn. Chọn SHA-256 để restore.sh tự kiểm được bằng
/// `shasum -a 256` (không cần app).
enum ContentHash {
    static func of(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func ofFile(_ path: String) -> String? {
        FileManager.default.contents(atPath: path).map(of)
    }
}

import Foundation

// Gọi hàm POSIX ở mức file: trong `FileProbe`, tên `stat` bị che bởi hàm tĩnh cùng tên.
private func posixStat(_ p: String, _ st: inout Darwin.stat) -> Int32 { stat(p, &st) }
private func posixLstat(_ p: String, _ st: inout Darwin.stat) -> Int32 { lstat(p, &st) }

/// Thao tác đĩa mức thấp trên đường dẫn VẬT LÝ (POSIX, không qua shell).
/// Bộ quét không gọi trực tiếp mà dùng các hàm đường dẫn logic của `ScanEnvironment`.
public enum FileProbe {
    // MARK: Kiểm tra kiểu (giữ đúng ngữ nghĩa `[[ -e/-d/-f/-L/-x ]]` của zsh)

    /// `-e`: tồn tại, có đi xuyên symlink (symlink gãy = không tồn tại).
    /// CHỈ dùng khi "không biết" được phép coi như "không có". Kết luận "đã mất" để báo/gỡ thì dùng `existence`.
    public static func exists(_ path: String) -> Bool { stat(path) != nil }

    /// Ba trạng thái của `-e`.
    public enum Existence: Sendable, Equatable {
        case exists
        /// Chắc chắn không có: ENOENT, ENOTDIR, ELOOP (vòng symlink).
        case missing
        /// stat lỗi vì lý do khác (EACCES/EPERM do quyền hoặc TCC, EIO...): không kết luận được.
        case unknown
    }

    /// `-e` có phân biệt "không có" với "không xem được". Thư mục không duyệt được (home người khác, ~/Documents khi
    /// thiếu FDA) cho EACCES/EPERM - coi là "mất" thì job/PATH/symlink đang dùng bị báo High và bị gỡ.
    public static func existence(_ path: String) -> Existence {
        var st = Darwin.stat()
        if posixStat(path, &st) == 0 { return .exists }
        switch errno {
        case ENOENT, ENOTDIR, ELOOP: return .missing
        default: return .unknown
        }
    }
    /// Tồn tại hoặc là symlink (kể cả gãy): `-e || -L`.
    public static func lexists(_ path: String) -> Bool { lstat(path) != nil }
    /// `-d`: là thư mục, đi xuyên symlink.
    public static func isDirectory(_ path: String) -> Bool { stat(path).map { isDir($0) } ?? false }
    /// `-f`: là file thường, đi xuyên symlink.
    public static func isRegularFile(_ path: String) -> Bool { stat(path).map { isReg($0) } ?? false }
    /// `-L`: là symlink.
    public static func isSymlink(_ path: String) -> Bool { lstat(path).map { isLnk($0) } ?? false }
    /// Thư mục thật (lstat, symlink không tính) - glob `(/)`.
    public static func isRealDirectory(_ path: String) -> Bool { lstat(path).map { isDir($0) } ?? false }
    /// File thường thật (lstat) - glob `(.)`.
    public static func isRealRegularFile(_ path: String) -> Bool { lstat(path).map { isReg($0) } ?? false }
    /// File thực thi (không phải thư mục), đi xuyên symlink.
    public static func isExecutableFile(_ path: String) -> Bool {
        guard let st = stat(path), !isDir(st) else { return false }
        return access(path, X_OK) == 0
    }
    /// `-w`.
    public static func isWritable(_ path: String) -> Bool { access(path, W_OK) == 0 }
    /// `-r && -f` nhưng kiểm tra bằng cách MỞ thật: `access()` có thể nói "đọc được" dù TCC chặn lúc `open()`.
    public static func isReadableFile(_ path: String) -> Bool {
        guard isRegularFile(path) else { return false }
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    /// `readlink` một cấp, chuỗi thô (có thể tương đối). Không phải symlink → nil.
    public static func readlink(_ path: String) -> String? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let n = Darwin.readlink(path, &buf, buf.count - 1)
        guard n >= 0 else { return nil }
        buf[n] = 0
        return String(cString: buf)
    }

    public static func stat(_ path: String) -> Darwin.stat? {
        var st = Darwin.stat()
        return posixStat(path, &st) == 0 ? st : nil
    }

    public static func lstat(_ path: String) -> Darwin.stat? {
        var st = Darwin.stat()
        return posixLstat(path, &st) == 0 ? st : nil
    }

    static func isDir(_ st: Darwin.stat) -> Bool { (st.st_mode & S_IFMT) == S_IFDIR }
    static func isReg(_ st: Darwin.stat) -> Bool { (st.st_mode & S_IFMT) == S_IFREG }
    static func isLnk(_ st: Darwin.stat) -> Bool { (st.st_mode & S_IFMT) == S_IFLNK }

    // MARK: Liệt kê

    /// Tên mục con (kể cả file ẩn), sắp theo byte. Không đọc được → rỗng.
    public static func childNames(_ dir: String) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return names.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    /// `_dir_is_empty`: không có mục con nào, kể cả file ẩn. Không đọc được → false (an toàn hơn zsh, vốn
    /// coi glob rỗng là rỗng): "không biết" thì không báo là đã dọn sạch.
    public static func dirIsEmpty(_ dir: String) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return false }
        return names.isEmpty
    }

    // MARK: Thời gian

    /// `days_since_modified`: floor((now - mtime) / 86400), lstat. Không stat được → 0.
    public static func daysSinceModified(_ path: String, now: Date) -> Int {
        guard let st = lstat(path) else { return 0 }
        return days(since: TimeInterval(st.st_mtimespec.tv_sec), now: now)
    }

    /// `days_since_trashed`: dùng ctime (đổi khi đổi tên/di chuyển); mtime có thể là nhiều năm trước,
    /// nên hoàn toàn không nói lên bỏ vào thùng rác bao lâu rồi.
    public static func daysSinceChanged(_ path: String, now: Date) -> Int {
        guard let st = lstat(path) else { return 0 }
        return days(since: TimeInterval(st.st_ctimespec.tv_sec), now: now)
    }

    private static func days(since t: TimeInterval, now: Date) -> Int {
        Int((now.timeIntervalSince1970 - t) / 86_400.0)
    }

    // MARK: Dung lượng

    /// `size_mb` tính bằng byte: dung lượng CẤP PHÁT của cả cây như `du -sxk`.
    /// - Không tồn tại (theo `-e`, symlink gãy = không tồn tại) → 0.
    /// - Không đi xuyên điểm mount (`-x`). Thiếu nó, một volume được mount vào bên trong thư mục (vd runtime
    ///   simulator ở /Library/Developer/CoreSimulator/Volumes) sẽ bị đếm như file thật: /Library/Developer
    ///   báo 28 GB thay vì 2,5 GB.
    /// - Không theo symlink bên trong cây; hardlink tính một lần; mục không đọc được bỏ qua.
    /// Đắt: chỉ gọi sau khi đã quyết định báo. Trả nil nếu bị hủy giữa chừng.
    public static func allocatedSize(_ path: String, isCancelled: () -> Bool = { false }) -> Int64? {
        guard exists(path) else { return 0 }
        guard let rootSt = lstat(path) else { return 0 }
        let rootDev = rootSt.st_dev
        guard let cPath = strdup(path) else { return 0 }
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return 0 }
        defer { fts_close(fts) }
        var total: Int64 = 0
        var seen = Set<HardLink>()
        var counter = 0
        while let ent = fts_read(fts) {
            counter += 1
            if counter % 512 == 0, isCancelled() { return nil }
            let info = Int32(ent.pointee.fts_info)
            if info == FTS_DP || info == FTS_NS || info == FTS_ERR { continue }
            guard let st = ent.pointee.fts_statp?.pointee else { continue }
            if st.st_dev != rootDev {
                if info == FTS_D { fts_set(fts, ent, Int32(FTS_SKIP)) }
                continue
            }
            if !isDir(st), st.st_nlink > 1 {
                let key = HardLink(dev: st.st_dev, ino: st.st_ino)
                if seen.contains(key) { continue }
                seen.insert(key)
            }
            total += Int64(st.st_blocks) * 512
        }
        return total
    }

    private struct HardLink: Hashable {
        let dev: dev_t
        let ino: ino_t
    }

    // MARK: Nội dung

    /// Đọc UTF-8 (file thường, đi xuyên symlink). Không đọc được hoặc không phải UTF-8 → nil.
    public static func readText(_ path: String) -> String? {
        guard isRegularFile(path), let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Chủ sở hữu `user:group` theo lstat (dùng cho manifest TrashPath). Không đọc được → nil.
    public static func ownerString(_ path: String) -> String? {
        guard let st = lstat(path) else { return nil }
        let user = getpwuid(st.st_uid).flatMap { $0.pointee.pw_name }.map { String(cString: $0) } ?? String(st.st_uid)
        let group = getgrgid(st.st_gid).flatMap { $0.pointee.gr_name }.map { String(cString: $0) } ?? String(st.st_gid)
        return "\(user):\(group)"
    }
}

/// Phân giải đường dẫn kiểu zsh `${p:A}` - DÙNG CHUNG CHO MỌI CHỐT AN TOÀN.
///
/// Thứ tự: (1) tuyệt đối hóa; (2) bỏ `.` và xử lý `..` theo TỪ VỰNG trước (`/t/lnk/..` → `/t`);
/// (3) realpath cho tiền tố đang tồn tại dài nhất; (4) nối phần đuôi chưa tồn tại nguyên văn; (5) bỏ `/` cuối.
/// Giữ `/private` (`/var/x` → `/private/var/x`). KHÔNG dùng `resolvingSymlinksInPath()`/`standardizingPath`:
/// Foundation tự cắt `/private`, làm hai vế so sánh lệch nhau (lỗi MacTrash 1.3.0 đã sửa).
public enum PathResolver {
    /// Chuẩn hóa từ vựng: tuyệt đối, bỏ `.`, `//`, xử lý `..` (không vượt quá `/`), bỏ `/` cuối.
    public static func lexical(_ p: String, cwd: String = "/") -> String {
        let abs = p.hasPrefix("/") ? p : (cwd.hasSuffix("/") ? cwd : cwd + "/") + p
        var out: [Substring] = []
        for c in abs.split(separator: "/", omittingEmptySubsequences: true) {
            if c == "." { continue }
            if c == ".." { if !out.isEmpty { out.removeLast() }; continue }
            out.append(c)
        }
        return "/" + out.joined(separator: "/")
    }

    /// `${p:A}` trên đường dẫn vật lý.
    public static func resolve(_ p: String, cwd: String = "/") -> String {
        let lex = lexical(p, cwd: cwd)
        let comps = lex.split(separator: "/").map(String.init)
        var i = comps.count
        while i >= 0 {
            let prefix = "/" + comps[0..<i].joined(separator: "/")
            if let real = realpath(prefix) {
                let tail = comps[i...].joined(separator: "/")
                if tail.isEmpty { return real }
                return real == "/" ? "/" + tail : real + "/" + tail
            }
            i -= 1
        }
        return lex
    }

    private static func realpath(_ p: String) -> String? {
        guard let r = Darwin.realpath(p, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }

    /// `${p:h}` theo từ vựng: bỏ `/` cuối rồi bỏ thành phần cuối. `/x` → `/`; không có `/` → `.`.
    public static func parent(_ p: String) -> String {
        var s = Substring(p)
        while s.count > 1, s.hasSuffix("/") { s = s.dropLast() }
        guard let slash = s.lastIndex(of: "/") else { return "." }
        if slash == s.startIndex { return "/" }
        return String(s[..<slash])
    }

    /// `${p:t}`: thành phần cuối sau khi bỏ `/` cuối. `/` → `""`.
    public static func tail(_ p: String) -> String {
        var s = Substring(p)
        while s.hasSuffix("/") { s = s.dropLast() }
        guard let slash = s.lastIndex(of: "/") else { return String(s) }
        return String(s[s.index(after: slash)...])
    }
}

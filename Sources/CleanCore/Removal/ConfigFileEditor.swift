import Foundation

/// Sửa file cấu hình theo dòng (`_rewrite_file`), có chủ đích sửa các lỗi của bản zsh:
/// - zsh đọc bằng `while read` nên dòng cuối không có `\n` bị MẤT; ở đây giữ mọi dòng và trạng thái `\n` cuối.
/// - zsh `mv` file tạm đè lên đường dẫn: nếu là symlink (dotfiles quản lý bằng repo) thì symlink thành file
///   thường; ở đây sửa FILE ĐÍCH đã phân giải, symlink còn nguyên.
/// - Ghi file tạm cùng thư mục, chép ACL/xattr + mode gốc, `rename` nguyên tử. File có hardlink (dotfiles kiểu
///   `ln`) hoặc của chủ khác: ghi đè TẠI CHỖ để không cắt link / đổi chủ (backup đã có trước khi gọi).
public enum ConfigFileEditor {
    /// Tiền tố comment khi tắt một dòng. Là nội dung file (người dùng grep được), giữ nguyên văn MacTrash.
    public static let disabledMarker = "# MacTrash đã tắt: "

    public enum Result: Equatable, Sendable {
        case changed
        case unchanged
        case failed
        /// `transform` từ chối: không sửa tự động an toàn được, người dùng phải tự sửa.
        case needsManualEdit
        /// `validate` từ chối nội dung mới (vd làm file shell hỏng cú pháp). Không ghi gì.
        case rejected
    }

    /// Đọc file (vật lý) dạng UTF-8, áp `transform` lên các dòng (nil = cần sửa tay), kiểm tra bằng `validate`
    /// (nội dung cũ, nội dung mới) rồi mới ghi. Không phải UTF-8 / không đọc được → `.failed` (không sửa gì).
    public static func rewrite(_ path: String, transform: ([String]) -> [String]?,
                               validate: ((Data, Data) -> Bool)? = nil) -> Result {
        let target = FileProbe.isSymlink(path) ? PathResolver.resolve(path) : path
        guard FileProbe.isRegularFile(target), let data = FileManager.default.contents(atPath: target),
              let text = String(data: data, encoding: .utf8) else { return .failed }
        var tl = TextLines(text)
        guard let newLines = transform(tl.lines) else { return .needsManualEdit }
        if newLines == tl.lines { return .unchanged }
        tl.lines = newLines
        if newLines.isEmpty { tl.endsWithNewline = false }
        let newData = Data(tl.text.utf8)
        if let validate, !validate(data, newData) { return .rejected }
        return write(newData, to: target) ? .changed : .failed
    }

    /// Ghi nguyên tử, giữ mode + ACL + xattr của file cũ (nếu có). Hardlink hoặc chủ khác → ghi tại chỗ.
    static func write(_ data: Data, to target: String) -> Bool {
        let st = FileProbe.stat(target)
        if let st, st.st_nlink > 1 || st.st_uid != getuid() { return writeInPlace(data, to: target) }
        let dir = PathResolver.parent(target)
        let tmp = dir + "/." + PathResolver.tail(target) + ".mpm.tmp"
        guard FileManager.default.createFile(atPath: tmp, contents: data) else { return false }
        if let st {
            // không chép COPYFILE_STAT: nó trả cả mtime cũ về, file vừa sửa trông như chưa đổi
            _ = copyfile(target, tmp, nil, copyfile_flags_t(COPYFILE_ACL | COPYFILE_XATTR))
            _ = chmod(tmp, st.st_mode & 0o7777)
        }
        guard rename(tmp, target) == 0 else {
            unlink(tmp)
            return false
        }
        return true
    }

    /// Ghi đè nội dung tại chỗ (giữ inode: hardlink, chủ, ACL, xattr còn nguyên).
    static func writeInPlace(_ data: Data, to target: String) -> Bool {
        let fd = open(target, O_WRONLY | O_TRUNC | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return data.withUnsafeBytes { raw -> Bool in
            guard var p = raw.baseAddress else { return true }
            var left = raw.count
            while left > 0 {
                let n = Darwin.write(fd, p, left)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                left -= n
                p += n
            }
            return true
        }
    }

    /// PathEntry trong `/etc/paths` hoặc `/etc/paths.d/*` (định dạng "mỗi dòng một thư mục"): bỏ mọi dòng bằng
    /// đúng `dir`.
    public static func removingPathLines(_ lines: [String], dir: String) -> [String] {
        lines.filter { $0 != dir }
    }

    /// PathEntry trong file shell: comment lại (KHÔNG xóa) mọi dòng có `dir` là MỘT PHẦN TỬ PATH trọn vẹn.
    /// nil = không tắt an toàn được bằng comment, người dùng phải tự sửa. MacTrash comment mọi dòng chứa CHUỖI CON
    /// `dir`, làm hỏng file theo nhiều cách (zsh dừng đọc phần còn lại của .zshrc):
    /// - `if [[ -d dir ]]; then` bị comment, `fi` còn trơ → parse error;
    /// - dòng nối `\` hoặc chuỗi nhiều dòng → mất dấu nháy đóng;
    /// - `PATH=dir:/opt/homebrew/bin:$PATH` → mất luôn thư mục còn sống;
    /// - `source dir2/init.sh` cũng khớp chuỗi con.
    /// Mọi dòng khớp đều phải an toàn; một dòng không an toàn là trả nil (không sửa nửa vời).
    public static func disablingPathEntry(_ dir: String, in lines: [String]) -> [String]? {
        var out = lines
        for (i, line) in lines.enumerated() {
            if line.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("#") { continue }
            guard lineHasPathElement(line, dir) else { continue }
            if !isSafeToComment(line, dir: dir) { return nil }
            if i > 0, endsWithContinuation(lines[i - 1]) { return nil }
            out[i] = disabledMarker + line
        }
        return out
    }

    /// Ký tự được phép đứng TRƯỚC / SAU một phần tử PATH.
    private static let elementStart: Set<Character> = [":", "\"", "'", "=", " ", "\t", "("]
    private static let elementEnd: Set<Character> = [":", "\"", "'", " ", "\t", ")", ";"]

    /// `dir` xuất hiện như một phần tử trọn vẹn (biên: đầu dòng, `:`, nháy, `=`, khoảng trắng, ngoặc; cho phép một
    /// `/` thừa ở cuối).
    static func lineHasPathElement(_ line: String, _ dir: String) -> Bool {
        guard !dir.isEmpty else { return false }
        var from = line.startIndex
        while let r = line.range(of: dir, range: from..<line.endIndex) {
            let okStart = r.lowerBound == line.startIndex || elementStart.contains(line[line.index(before: r.lowerBound)])
            var end = r.upperBound
            if end < line.endIndex, line[end] == "/", !dir.hasSuffix("/") { end = line.index(after: end) }
            let okEnd = end == line.endIndex || elementEnd.contains(line[end])
            if okStart && okEnd { return true }
            from = line.index(after: r.lowerBound)
        }
        return false
    }

    /// Từ khóa điều khiển / toán tử làm dòng không còn là một khai báo đơn.
    private static let controlWords: Set<String> = [
        "if", "then", "elif", "else", "fi", "for", "while", "until", "do", "done", "case", "esac", "select",
        "function", "{", "}", "[[", "]]", "[", "]", "test", "source", ".", "eval",
    ]

    /// Dòng là một khai báo đơn (`export PATH=dir:$PATH`, `path+=(dir)`, `dir` trần trong mảng nhiều dòng): không
    /// nối dòng, nháy cân bằng, không lệnh điều khiển/toán tử, không có thư mục nào khác ngoài `dir`.
    static func isSafeToComment(_ line: String, dir: String) -> Bool {
        if endsWithContinuation(line) { return false }
        if line.filter({ $0 == "\"" }).count % 2 != 0 || line.filter({ $0 == "'" }).count % 2 != 0 { return false }
        for op in ["&&", "||", "$(", "`", "|"] where line.contains(op) { return false }
        let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == ";" }).map(String.init)
        if words.contains(where: { controlWords.contains($0) }) { return false }
        // phần tử khác dạng đường dẫn (tuyệt đối, ~, $HOME) ngoài chính `dir`
        let trimmedDir = dir.hasSuffix("/") && dir.count > 1 ? String(dir.dropLast()) : dir
        let tokens = line.split(whereSeparator: { ":\"'= \t();".contains($0) }).map(String.init)
        for t in tokens {
            let tt = t.hasSuffix("/") && t.count > 1 ? String(t.dropLast()) : t
            if tt == trimmedDir { continue }
            if t.hasPrefix("/") || t.hasPrefix("~") || t.hasPrefix("$HOME") || t.hasPrefix("${HOME}") { return false }
        }
        return true
    }

    /// Dòng kết thúc bằng `\` (bỏ khoảng trắng cuối): dòng sau là phần tiếp theo của nó.
    static func endsWithContinuation(_ line: String) -> Bool {
        var t = Substring(line)
        while let c = t.last, c == " " || c == "\t" || c == "\r" { t = t.dropLast() }
        return t.hasSuffix("\\")
    }

    /// Shell dùng để kiểm tra cú pháp (`-n`) của một file cấu hình (logic).
    public static func syntaxShell(for file: String) -> String {
        let t = PathResolver.tail(file)
        if t.contains("bash") || t == ".profile" || file == "/etc/profile" { return "/bin/bash" }
        return "/bin/zsh"
    }

    /// EnvLine: comment mọi dòng BẰNG ĐÚNG `line` (so nguyên văn, kể cả khoảng trắng).
    public static func commentingLines(equalTo line: String, in lines: [String]) -> [String] {
        lines.map { $0 == line ? disabledMarker + $0 : $0 }
    }
}

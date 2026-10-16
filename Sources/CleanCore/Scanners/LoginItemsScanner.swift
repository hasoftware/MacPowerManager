import Foundation

/// `scan_loginitems`: danh sách mục khởi động nền (BTM) chỉ đọc được bằng root (spec A §3.10).
/// P0 luôn chạy quyền người dùng → đúng một mục Info chỉ báo, ID `LoginItem|Background Task Management|(sfltool dumpbtm)`.
public struct LoginItemsScanner: Scanner {
    public init() {}

    public var id: String { "LoginItem" }

    public func scan(_ context: ScanContext) throws -> [Finding] {
        guard context.env.isRoot else {
            return [Finding(category: .loginItem, severity: .info, name: FindingLiteral.backgroundTaskName,
                            target: FindingLiteral.backgroundTaskTarget, reason: .needRootForBackgroundTasks,
                            sizeBytes: 0, action: .reportOnly)]
        }
        // P5 (root): duyệt `sfltool dumpbtm`
        let res = context.runner.run(Tool.sfltool, ["dumpbtm"])
        guard res.succeeded else { return [] }
        return try LoginItemsScanner.parseDump(res.lines, context: context)
    }

    /// Mỗi dòng `Name:` đặt tên, mỗi dòng `Executable Path:` kết thúc một mục: đường dẫn tuyệt đối mà không tồn
    /// tại → Medium chỉ báo. Sửa lỗi bản gốc: zsh khớp `*Name:*` nên dòng `Developer Name:` ghi đè tên mục; ở đây
    /// chỉ nhận dòng mà phần đã trim BẮT ĐẦU bằng `Name:`.
    static func parseDump(_ lines: [String], context: ScanContext) throws -> [Finding] {
        var out: [Finding] = []
        var name = "", exe = ""
        for line in lines {
            try context.checkCancelled()
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("Name:") {
                name = valueAfterColon(line)
            } else if line.contains("Executable Path:") {
                exe = valueAfterColon(line)
                if !exe.isEmpty, exe.hasPrefix("/"), !context.env.exists(exe) {
                    out.append(Finding(category: .loginItem, severity: .medium, name: name.isEmpty ? exe : name,
                                       target: exe, reason: .loginItemDead, sizeBytes: 0, action: .reportOnly))
                }
                name = ""; exe = ""
            }
        }
        return out
    }

    /// `${line#*: }`: bỏ tới hết `": "` đầu tiên; không có thì giữ nguyên dòng.
    static func valueAfterColon(_ line: String) -> String {
        guard let r = line.range(of: ": ") else { return line }
        return String(line[r.upperBound...])
    }
}

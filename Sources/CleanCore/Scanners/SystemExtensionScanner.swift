import Foundation

/// `scan_sysext`: system extension treo, kext mồ côi - chỉ báo (spec B §8).
public struct SystemExtensionScanner: Scanner {
    public init() {}

    public var id: String { "SysExt" }

    public func scan(_ context: ScanContext) throws -> [Finding] {
        let env = context.env
        var out: [Finding] = []

        // A. System extension treo ở trạng thái gỡ dở / đã dừng
        let r = context.runner.run(Tool.systemextensionsctl, ["list"])
        for line in r.lines {
            try context.checkCancelled()
            guard let state = SystemExtensionScanner.state(ofLine: line) else { continue }
            guard state.contains("waiting to uninstall") || state.contains("terminated") else { continue }
            // Cột phân tách bằng tab: enabled / active / teamID / bundleID (version) / ... (giữ trường rỗng)
            let fields = line.components(separatedBy: "\t")
            var bid = ""
            if fields.count >= 4 {
                let f4 = fields[3]
                bid = f4.firstIndex(of: " ").map { String(f4[..<$0]) } ?? f4
            }
            // target là NGUYÊN dòng (gồm TAB, version) như zsh - ID đổi khi version đổi
            out.append(Finding(category: .sysExt, severity: .medium, name: bid.isEmpty ? "?" : bid, target: line,
                               reason: .sysExtStale(state: state), action: .reportOnly))
        }

        // B. Kext cũ trong /Library/Extensions của phần mềm đã gỡ.
        // CHỈ BÁO: trên Apple Silicon, gỡ kext phải qua kmutil + khởi động lại ở chế độ Recovery. Tự xóa thư mục
        // là cách sai và có thể làm máy không boot được.
        for k in env.list("/Library/Extensions", .any, suffix: ".kext") {
            try context.checkCancelled()
            // macOS ship sẵn vài kext rỗng (HighPointIOP/RR...) chỉ có Info.plist, không có binary -> không phải
            // tàn dư của ai cả
            guard env.isDirectory("\(k)/Contents/MacOS") else { continue }
            // nil -> tên file; khóa có mà rỗng -> "" -> orphan_check coi là còn sống (giữ như zsh)
            let bid = env.plistString("\(k)/Contents/Info.plist", "CFBundleIdentifier")
                ?? Names.removingSuffix(PathResolver.tail(k), ".kext")
            // Chỉ dùng cờ mồ côi; mức cố định Medium, bỏ severity/why của classifier
            guard context.orphanCheck(name: bid, path: k).isOrphan else { continue }
            // macOS 15 ship kext HighPointIOP/RR CÓ binary (gói com.apple.files.data-template): chốt "không có
            // Contents/MacOS" ở trên không còn đủ. Một lệnh cho mỗi ứng viên mồ côi.
            if SystemExtensionScanner.installedByApple(k, runner: context.runner) { continue }
            out.append(Finding(category: .sysExt, severity: .medium, name: PathResolver.tail(k), target: k,
                               reason: .kextOrphan, sizeBytes: context.sizeBytes(k), action: .reportOnly))
        }
        return out
    }

    /// `pkgutil --file-info <kext>` có dòng `pkgid: com.apple.*` → do macOS cài.
    static func installedByApple(_ path: String, runner: CommandRunner) -> Bool {
        let r = runner.run(Tool.pkgutil, ["--file-info", path], timeout: 15)
        guard r.succeeded else { return false }
        return r.lines.contains { line in
            guard line.hasPrefix("pkgid:") else { return false }
            return line.dropFirst("pkgid:".count).trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("com.apple.")
        }
    }

    /// `[[ $line == *'['*']'* ]]` rồi `${${line##*\[}%\]*}`: phần sau dấu `[` CUỐI, cắt tại dấu `]` cuối của phần đó.
    static func state(ofLine line: String) -> String? {
        guard let open = line.firstIndex(of: "["), line[line.index(after: open)...].contains("]") else { return nil }
        guard let lastOpen = line.lastIndex(of: "[") else { return nil }
        let after = line[line.index(after: lastOpen)...]
        if let close = after.lastIndex(of: "]") { return String(after[..<close]) }
        return String(after)
    }
}

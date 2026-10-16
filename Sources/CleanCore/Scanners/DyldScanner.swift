import Foundation

/// `scan_dyld`: DYLD_INSERT_LIBRARIES trong plist/file shell, sudoers bên thứ ba - chỉ báo (spec B §4).
public struct DyldScanner: Scanner {
    public init() {}

    public var id: String { "Security.Dyld" }

    public func scan(_ context: ScanContext) throws -> [Finding] {
        let env = context.env
        var out: [Finding] = []
        let name = FindingLiteral.dyldName

        // A. Plist launchd: file thường thật (*.plist(N.) - symlink không tính)
        for d in ["\(env.homePath)/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons"] {
            try context.checkCancelled()
            guard env.isDirectory(d) else { continue }
            for f in env.list(d, .regularFiles, suffix: ".plist") {
                try context.checkCancelled()
                // Như plutil -extract … raw: mảng ra số phần tử ("0" vẫn khác rỗng) nên mảng cũng bị báo.
                guard let v = env.plistString(f, "EnvironmentVariables.DYLD_INSERT_LIBRARIES"), !v.isEmpty else {
                    continue
                }
                out.append(Finding(category: .security, severity: .high, name: name, target: f,
                                   reason: .dyldInsert(location: PathResolver.tail(f)), action: .reportOnly))
            }
        }

        // B. File shell: chuỗi xuất hiện ở bất cứ đâu (kể cả comment), mỗi file tối đa một finding
        let needle = Data(name.utf8)
        for f in env.rcFiles + ["/etc/launchd.conf"] where env.isReadableFile(f) {
            try context.checkCancelled()
            guard let data = FileManager.default.contents(atPath: env.physicalPath(f)),
                  data.range(of: needle) != nil else { continue }
            out.append(Finding(category: .security, severity: .high, name: name, target: f,
                               reason: .dyldInsert(location: f), action: .reportOnly))
        }

        // C. sudoers do bên thứ ba thêm vào: quyền root không cần mật khẩu. Chỉ cần liệt kê (file 0440 root).
        for f in env.list("/etc/sudoers.d", .regularFiles) {
            try context.checkCancelled()
            let base = PathResolver.tail(f)
            if base == "README" { continue }
            out.append(Finding(category: .security, severity: .medium, name: FindingLiteral.sudoersName(base),
                               target: f, reason: .thirdPartySudoers(file: base), action: .reportOnly))
        }
        return out
    }
}

import Foundation

/// `scan_helpers`: helper root trong `/Library/PrivilegedHelperTools` (spec A §3.11).
/// Mọi mục đều cần quyền quản trị để gỡ (thư mục thuộc root) - P0 chỉ báo, kind vẫn TrashPath cho P5.
public struct HelpersScanner: Scanner {
    public init() {}

    public var id: String { "Helper" }

    public func scan(_ context: ScanContext) throws -> [Finding] {
        let env = context.env
        var out: [Finding] = []
        for h in env.list("/Library/PrivilegedHelperTools", .any) {
            try context.checkCancelled()
            let name = PathResolver.tail(h)
            // Helper chạy quyền root: còn sót lại là vấn đề bảo mật, không chỉ là rác -> luôn High, không hạ mức
            // theo orphan_check hay theo dung lượng.
            let reason: CleanReason
            let severity: Severity
            if context.orphanCheck(name: name, path: h).isOrphan {
                (severity, reason) = (.high, .helperOrphan)
            } else if !env.isRegularFile("/Library/LaunchDaemons/\(name).plist") {
                (severity, reason) = (.medium, .helperNoJob)
            } else {
                continue
            }
            out.append(Finding(category: .helper, severity: severity, name: name, target: h, reason: reason,
                               sizeBytes: context.sizeBytes(h), action: .trashPath(path: h)))
        }
        return out
    }
}

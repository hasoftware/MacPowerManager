import Foundation

/// `scan_brokenapps`: vỏ `.app` rỗng/hỏng lấy từ `AppIndex.deadApps` (spec B §14).
/// Vỏ rỗng KHÔNG vào chỉ mục app sống (trình gỡ tồi, iCloud gỡ tải, xóa dở đều để lại vỏ), nên được báo High.
public struct BrokenAppScanner: Scanner {
    public init() {}

    public var id: String { "App" }

    public func scan(_ context: ScanContext) throws -> [Finding] {
        var out: [Finding] = []
        for a in context.index.deadApps {
            try context.checkCancelled()
            if a.hasPrefix("/System/") { continue }
            // zsh luôn dùng DHollowApp kể cả khi chỉ thiếu file thực thi; ở đây phân biệt (không ảnh hưởng ID)
            let reason = context.env.appBundleProblem(a) ?? .hollowApp
            out.append(Finding(category: .app, severity: .high, name: PathResolver.tail(a), target: a, reason: reason,
                               sizeBytes: context.sizeBytes(a), action: .trashPath(path: a)))
        }
        return out
    }
}

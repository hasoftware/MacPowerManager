import Foundation

/// `scan_containers`: `~/Library/Containers` rồi `~/Library/Group Containers` (spec A §3.5).
/// Không có `/Library/Containers`. Lưu ý (R6): đọc metadata/dung lượng trong container của app khác có thể bị TCC
/// chặn (size 0 → hạ mức) khi app chưa có Full Disk Access.
public struct ContainersScanner: Scanner {
    public init() {}

    public var id: String { "Containers" }

    public func scan(_ context: ScanContext) throws -> [Finding] {
        let env = context.env
        var out: [Finding] = []
        for c in env.list("\(env.homePath)/Library/Containers", .realDirectories) {
            try context.checkCancelled()
            var name = PathResolver.tail(c)
            // Tên thư mục thường LÀ bundle id, nhưng vài container mang chuỗi sinh tự động; khi đó lấy id thật
            // trong metadata của container manager.
            if !Names.looksLikeBundleID(name),
               let bid = env.plistString("\(c)/.com.apple.containermanager.metadata.plist", "MCMMetadataIdentifier"),
               !bid.isEmpty {
                name = bid
            }
            if let finding = context.reportOrphan(name: name, path: c, category: .containers) { out.append(finding) }
        }
        // Group Containers: tên dạng TEAMID.com.foo / group.com.foo - orphan_check tự cắt
        out += try context.scanContainer("\(env.homePath)/Library/Group Containers", category: .groupContainer)
        return out
    }
}

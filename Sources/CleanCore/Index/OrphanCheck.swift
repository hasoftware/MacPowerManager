import Foundation

/// Kết luận của `orphan_check`.
public enum OrphanVerdict: Sendable, Equatable {
    case alive
    case orphan(Severity, CleanReason)

    public var isOrphan: Bool {
        if case .orphan = self { return true }
        return false
    }
}

extension AppIndex {
    /// `orphan_check(name, path)`. Nguyên tắc: chỉ báo High khi có bằng chứng mạnh (bundle id rõ ràng, không khớp
    /// gì cả); tên trần chỉ là suy đoán -> Medium/Info. `path` (logic) chỉ dùng để đọc mtime cho tên trần.
    /// `includePackageReceipts: false`: nhánh bundle id bỏ qua id chỉ đến từ `pkgutil --pkgs` (bộ quét biên nhận).
    public func orphanCheck(name: String, path: String, includePackageReceipts: Bool = true) -> OrphanVerdict {
        if name.isEmpty { return .alive }
        if Names.systemKeep.contains(Names.norm(name)) { return .alive }
        // container tạm, profile... không suy ra được chủ sở hữu
        if Names.looksLikeUUID(name) { return .alive }
        // App Group khai trong entitlement của app đang cài (Office: `UBF8T346G9.Office` - tên trần sau khi cắt
        // Team ID là "Office", vốn là STOP_WORD, nên không có bước này là báo nhầm 176 MB dữ liệu Outlook).
        let lower = name.lowercased()
        if appGroups.contains(lower) { return .alive }
        if lower.hasPrefix("group."), appGroups.contains(String(lower.dropFirst("group.".count))) { return .alive }
        let base = Names.stripTeamPrefix(name)
        if ownNames.contains(Names.norm(base)) { return .alive }
        // Team ID của app đang cài + phần còn lại KHÔNG phải bundle id (`<TEAM>.Office`): tên trần không có bằng
        // chứng nào khác. Phần còn lại là bundle id thì vẫn xét bundle id như thường (app khác cùng vendor đã gỡ).
        if let team = Names.teamIdentifier(name), teamIDs.contains(team), !Names.looksLikeBundleID(base) {
            return .alive
        }
        let lb = base.lowercased()
        if lb.contains("com.apple.") || lb.hasPrefix("apple") || lb.hasPrefix(".") || lb.hasPrefix("systemgroup.")
            || lb.contains(".appleinternal.") || lb.hasPrefix("is.workflow.") || lb.hasPrefix("swift-playgrounds") {
            return .alive
        }
        if Names.systemKeep.contains(Names.norm(base)) { return .alive }
        if Names.looksLikeBundleID(base) {
            return bundleIDAlive(base, includePackageReceipts: includePackageReceipts) ? .alive : .orphan(.high, .orphanBundleID(base))
        }
        if nameAlive(base) { return .alive }
        let d = env.daysSinceModified(path)
        return .orphan(d >= 90 ? .medium : .info, .orphanName(base, days: d))
    }
}

extension ScanContext {
    /// `orphan_check` với chỉ mục của lượt quét.
    /// Bundle id bị coi là mồ côi được tra thêm trong Spotlight (`bundleLocator`): app nằm ngoài các thư mục tìm
    /// (ổ ngoài, ~/Downloads, sâu hơn 4 cấp, DerivedData) vẫn là app đang cài.
    public func orphanCheck(name: String, path: String, includePackageReceipts: Bool = true) -> OrphanVerdict {
        if env.isOwnDataPath(path) { return .alive }
        let v = index.orphanCheck(name: name, path: path, includePackageReceipts: includePackageReceipts)
        if case .orphan(_, .orphanBundleID(let bid)) = v, bundleLocator.isInstalled(bid) { return .alive }
        if case .orphan(_, .orphanName(let name, _)) = v, bundleLocator.isNameInstalled(name) { return .alive }
        return v
    }

    /// `bid_alive` + tra Spotlight cho app nằm ngoài các thư mục tìm.
    public func bundleIDAlive(_ bid: String) -> Bool {
        index.bundleIDAlive(bid) || bundleLocator.isInstalled(bid)
    }

    /// `_report_orphan(name, path, category)`: mồ côi → finding TrashPath với `name` NGUYÊN (chưa cắt Team ID),
    /// target = `path`, kèm dung lượng. High mà dưới 1 MiB cấp phát thì hạ xuống Medium (comment gốc nói "hạ
    /// xuống mức thông tin" nhưng code hạ về Medium - giữ code). Còn sống → nil.
    public func reportOrphan(name: String, path: String, category: CleanCategory) -> Finding? {
        // backup/manifest của chính app: không bao giờ báo
        if env.isOwnDataPath(path) { return nil }
        guard case .orphan(var sev, let reason) = orphanCheck(name: name, path: path) else { return nil }
        let bytes = sizeBytes(path)
        if bytes < 1_048_576, sev == .high { sev = .medium }
        return Finding(category: category, severity: sev, name: name, target: path, reason: reason,
                       sizeBytes: bytes, action: .trashPath(path: path))
    }

    /// `_scan_container(dir, category, stripSuffix)`: mỗi THƯ MỤC con thật (không symlink, không ẩn) → `reportOrphan`.
    /// Symlink: để scanner symlink lo. File rời nằm ở gốc (default.store, *.json, *.png) là dữ liệu của tiến trình
    /// khác, không suy ra được chủ sở hữu -> báo là chỉ tạo nhiễu. `stripSuffix` bị cắt một lần ở cuối tên.
    public func scanContainer(_ dir: String, category: CleanCategory, stripSuffix: String? = nil) throws -> [Finding] {
        guard env.isDirectory(dir) else { return [] }
        var out: [Finding] = []
        for child in env.list(dir, .realDirectories) {
            try checkCancelled()
            if env.isSymlink(child) || env.isOwnDataPath(child) { continue }
            var name = PathResolver.tail(child)
            if let s = stripSuffix { name = Names.removingSuffix(name, s) }
            if let f = reportOrphan(name: name, path: child, category: category) { out.append(f) }
        }
        return out
    }
}

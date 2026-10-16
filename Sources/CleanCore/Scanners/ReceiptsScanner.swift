import Foundation

/// `scan_receipts`: biên nhận gói của phần mềm đã gỡ, không còn file nào tồn tại (spec A §3.12, rủi ro R2).
/// Luôn cần quyền quản trị (`sudo pkgutil --forget <id>`) - P0 chỉ báo. target `/var/db/receipts/<id>` là chuỗi
/// tổng hợp (không phải file thật), giữ nguyên để ID khớp MacTrash.
///
/// Quyết định R2 (lệch bản gốc có chủ đích): chỉ mục đăng ký MỌI id của `pkgutil --pkgs` là bundle còn sống, nên ở
/// MacTrash 1.5.0 orphan_check luôn nói "còn" với biên nhận dạng bundle id - bộ quét này gần như không bao giờ báo.
/// Ở đây nhánh bundle id xét chỉ mục KHÔNG gồm nguồn pkgutil (app, plugin, toolchain, hệ thống), rồi vẫn giữ chốt
/// "còn file nào của gói không" như bản gốc. Việc phân loại nằm trong `AppIndex.build` (`staleReceiptIDs`).
public struct ReceiptsScanner: Scanner {
    public init() {}

    public var id: String { "Receipt" }

    public func scan(_ context: ScanContext) throws -> [Finding] {
        var out: [Finding] = []
        // Phân loại đã làm lúc dựng chỉ mục (biên nhận chết không được đăng ký làm bằng chứng cho dữ liệu khác)
        for pkg in context.index.packageReceiptIDs where context.index.staleReceiptIDs.contains(pkg) {
            try context.checkCancelled()
            // app nằm ngoài thư mục tìm (Spotlight thấy) -> gói vẫn đang dùng
            if Names.looksLikeBundleID(pkg), context.bundleLocator.isInstalled(pkg) { continue }
            out.append(Finding(category: .receipt, severity: .medium, name: pkg, target: "/var/db/receipts/\(pkg)",
                               reason: .receiptOrphan, sizeBytes: 0, action: .pkgReceipt(id: pkg)))
        }
        return out
    }
}

import Foundation

/// `scan_appsupport`: tàn dư trong `~/Library/Application Support` và `/Library/Application Support` (spec A §3.2).
/// Thư mục con ở `/Library` đa phần thuộc root → TrashPath của chúng cần quyền quản trị (Remover tự tính).
public struct AppSupportScanner: Scanner {
    public init() {}

    public var id: String { "AppSupport" }

    public func scan(_ context: ScanContext) throws -> [Finding] {
        try context.scanContainer("\(context.env.homePath)/Library/Application Support", category: .appSupport)
            + context.scanContainer("/Library/Application Support", category: .appSupport)
    }
}

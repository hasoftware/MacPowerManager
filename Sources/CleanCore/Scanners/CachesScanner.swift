import Foundation

/// `scan_caches`: tàn dư trong `~/Library/Caches` và `/Library/Caches` (spec A §3.3).
public struct CachesScanner: Scanner {
    public init() {}

    public var id: String { "Caches" }

    public func scan(_ context: ScanContext) throws -> [Finding] {
        try context.scanContainer("\(context.env.homePath)/Library/Caches", category: .caches)
            + context.scanContainer("/Library/Caches", category: .caches)
    }
}

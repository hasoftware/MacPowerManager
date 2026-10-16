import Foundation

/// `scan_state` phần 1: `~/Library/Saved Application State` (cắt `.savedState`) (spec A §3.6).
public struct SavedStateScanner: Scanner {
    public init() {}

    public var id: String { "SavedState" }

    public func scan(_ context: ScanContext) throws -> [Finding] {
        try context.scanContainer("\(context.env.homePath)/Library/Saved Application State", category: .savedState,
                                  stripSuffix: ".savedState")
    }
}

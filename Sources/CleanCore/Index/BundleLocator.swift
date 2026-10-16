import Foundation

/// App đang cài nhưng nằm NGOÀI các thư mục `build_app_index` tìm (ổ ngoài, ~/Downloads, ~/Desktop, sâu hơn 4 cấp,
/// bản build trong DerivedData). Không có bước này, container/preferences của chúng bị báo High là mồ côi.
///
/// Nguồn: MỘT lệnh `mdfind` liệt kê mọi app bundle kèm bundle id (~30 ms), chạy lười ở lần tra đầu tiên rồi giữ lại.
/// Spotlight tắt / lệnh lỗi → không thêm gì (hành vi như cũ).
public final class BundleLocator: @unchecked Sendable {
    private let env: ScanEnvironment
    private let runner: CommandRunner
    private let lock = NSLock()
    private var located: AppIndex?

    public init(env: ScanEnvironment, runner: CommandRunner) {
        self.env = env
        self.runner = runner
    }

    static let query = "kMDItemContentType == \"com.apple.application-bundle\""
    static let attributeTag = "   kMDItemCFBundleIdentifier = "

    /// Tên trần (thư mục `Application Support/<Tên>`) khớp tên một app hợp lệ Spotlight thấy, theo luật `name_alive`.
    /// Ví dụ app tự build nằm trong `~/Code/<dự án>/build/`.
    public func isNameInstalled(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let idx = index()
        guard !idx.tokens.isEmpty else { return false }
        return idx.nameAlive(name)
    }

    /// Bundle id (hoặc id con/anh em cùng vendor, theo đúng luật `bid_alive`) thuộc một app hợp lệ Spotlight thấy.
    public func isInstalled(_ bid: String) -> Bool {
        guard !bid.isEmpty else { return false }
        return index().bundleIDAlive(bid, includePackageReceipts: false)
    }

    private func index() -> AppIndex {
        lock.lock(); defer { lock.unlock() }
        if let located { return located }
        var idx = AppIndex(env: env)
        let r = runner.run(Tool.mdfind, ["-attr", "kMDItemCFBundleIdentifier", BundleLocator.query], timeout: 20)
        if r.succeeded {
            for line in r.lines {
                guard let (path, bid) = BundleLocator.parse(line) else { continue }
                // app trong Thùng rác không phải "đang cài"; vỏ .app rỗng cũng không
                if env.isTrashPath(path) || path.contains("/.Trash/") || path.contains("/.Trashes/") { continue }
                guard env.appBundleValid(path) else { continue }
                idx.registerBundle(bid, path: path)
                idx.registerToken(((path as NSString).lastPathComponent as NSString).deletingPathExtension)
            }
        }
        located = idx
        return idx
    }

    /// `<path>   kMDItemCFBundleIdentifier = <bid>` → (path, bid). `(null)` → nil.
    static func parse(_ line: String) -> (String, String)? {
        guard let r = line.range(of: attributeTag, options: .backwards) else { return nil }
        let path = String(line[..<r.lowerBound])
        var bid = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
        if bid.hasPrefix("\""), bid.hasSuffix("\""), bid.count >= 2 { bid = String(bid.dropFirst().dropLast()) }
        guard path.hasPrefix("/"), !bid.isEmpty, bid != "(null)" else { return nil }
        return (path, bid)
    }
}

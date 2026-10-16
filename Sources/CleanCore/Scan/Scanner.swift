import Foundation

/// Một bộ quét. Đồng bộ, Sendable, chạy ngoài main thread, CHỈ ĐỌC.
///
/// Hợp đồng cho người viết bộ quét:
/// - Trả finding theo đúng thứ tự zsh sinh ra (thứ tự chỉ dùng làm khóa phụ khi sắp xếp).
/// - Mọi đường dẫn trong finding là đường dẫn logic (`ScanEnvironment`), dùng `context.env.*` để chạm đĩa.
/// - Gọi `try context.checkCancelled()` trước mỗi thư mục / mỗi mục con / mỗi dòng output lớn.
/// - Không cần điền `needsAdmin`: ScanEngine tính sau khi quét.
/// - Lệnh ngoài qua `context.runner` (lệnh lỗi → coi như output rỗng).
/// Lưu ý: bên ngoài module, tên `Scanner` trùng `Foundation.Scanner` - dùng `CleanScanner` (hoặc `CleanCore.Scanner`).
public protocol Scanner: Sendable {
    /// Định danh ổn định cho tiến độ/log (vd "AppSupport").
    var id: String { get }
    func scan(_ context: ScanContext) throws -> [Finding]
}

/// Tên không mơ hồ cho code ngoài module (app, test) vốn cũng import Foundation.
public typealias CleanScanner = Scanner

/// Cờ hủy dùng chung giữa UI và luồng quét/gỡ.
public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
}

/// Mọi thứ một bộ quét cần: môi trường, chỉ mục dựng sẵn, runner, FDA, cờ hủy.
public struct ScanContext: Sendable {
    public let env: ScanEnvironment
    public let index: AppIndex
    public let runner: CommandRunner
    /// Có Full Disk Access (TCC chỉ quét khi có).
    public let hasFullDiskAccess: Bool
    public let cancellation: CancellationToken
    /// Tra app theo bundle id trong Spotlight (lười, một lần mỗi lượt quét).
    public let bundleLocator: BundleLocator

    public init(env: ScanEnvironment, index: AppIndex, runner: CommandRunner,
                hasFullDiskAccess: Bool, cancellation: CancellationToken = CancellationToken(),
                bundleLocator: BundleLocator? = nil) {
        self.env = env
        self.index = index
        self.runner = runner
        self.hasFullDiskAccess = hasFullDiskAccess
        self.cancellation = cancellation
        self.bundleLocator = bundleLocator ?? BundleLocator(env: env, runner: runner)
    }

    public var isCancelled: Bool { cancellation.isCancelled }

    /// Ném `CancellationError` nếu người dùng đã hủy.
    public func checkCancelled() throws {
        if cancellation.isCancelled { throw CancellationError() }
    }

    /// `size_mb` (byte) có hỗ trợ hủy. Chỉ gọi sau khi đã quyết định báo (đắt).
    public func sizeBytes(_ path: String) -> Int64 {
        env.sizeBytes(path, isCancelled: { cancellation.isCancelled })
    }
}

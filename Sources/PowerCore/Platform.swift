import Darwin

public enum Platform {
    /// Máy có chip Apple Silicon hay không. Kiểm tra lúc chạy (không dùng `#if arch`) để vẫn đúng
    /// khi app universal được mở bằng Rosetta. Điều khiển sạc hiện chỉ hỗ trợ Apple Silicon.
    public static let isAppleSilicon: Bool = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }()
}

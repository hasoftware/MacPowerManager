// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MacPowerManager",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacPowerManager", targets: ["MacPowerManager"]),
        .executable(name: "PowerHelper", targets: ["PowerHelper"]),
        .executable(name: "smc-probe", targets: ["SMCProbe"]),
    ],
    targets: [
        // Truy cập SMC (System Management Controller) mức thấp qua IOKit.
        .target(
            name: "CSMC",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        // Model, giao thức XPC và logic điều khiển sạc dùng chung.
        .target(
            name: "PowerCore",
            dependencies: ["CSMC"],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        // Lõi dọn dẹp (port MacTrash): chỉ mục app, bộ quét, chốt an toàn, Thùng rác, sao lưu/khôi phục.
        .target(
            name: "CleanCore"
        ),
        // Daemon chạy quyền root, ghi SMC để bật/tắt sạc và adapter.
        .executableTarget(
            name: "PowerHelper",
            dependencies: ["PowerCore", "CSMC"]
        ),
        // Ứng dụng SwiftUI (menu bar + cửa sổ).
        .executableTarget(
            name: "MacPowerManager",
            dependencies: ["PowerCore", "CleanCore"]
        ),
        // Công cụ CLI để kiểm tra các SMC key trên máy.
        .executableTarget(
            name: "SMCProbe",
            dependencies: ["PowerCore", "CSMC"]
        ),
        .testTarget(
            name: "PowerCoreTests",
            dependencies: ["PowerCore"]
        ),
        .testTarget(
            name: "CleanCoreTests",
            dependencies: ["CleanCore"]
        ),
        .testTarget(
            name: "MacPowerManagerTests",
            dependencies: ["MacPowerManager", "PowerCore"]
        ),
    ]
)

import AppKit
import SwiftUI

@main
struct MacPowerManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        #if DEBUG
        // Chế độ chụp giao diện để kiểm tra bố cục: vẽ các màn hình với dữ liệu giả rồi thoát.
        if let index = CommandLine.arguments.firstIndex(of: "--render-snapshots") {
            let path = CommandLine.arguments.dropFirst(index + 1).first ?? "/tmp/mpm-snapshots"
            SnapshotRenderer.run(directory: URL(fileURLWithPath: path))
            exit(0)
        }
        // In kết quả quét ứng dụng điều khiển sạc khác (chỉ đọc) rồi thoát.
        if CommandLine.arguments.contains("--scan-conflicts") {
            for finding in ConflictScanner.scan() {
                print("\(finding.name): running=\(finding.running) limit=\(finding.chargeLimit.map(String.init) ?? "-")")
                finding.installedPaths.forEach { print("  installed: \($0)") }
                finding.processes.forEach { print("  process: \($0)") }
            }
            exit(0)
        }
        #endif
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(model)
                .environment(\.locale, Format.locale)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Window("MacPowerManager", id: WindowID.dashboard) {
            RootView()
                .environment(model)
                .environment(\.locale, Format.locale)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1080, height: 720)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands { AppCommands() }
    }
}

/// Mở lại app (Finder, Spotlight) khi không có cửa sổ thì mở bảng điều khiển: mục thanh menu có thể bị notch che.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var openDashboard: (() -> Void)?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            Self.openDashboard?()
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }
}

/// Phím tắt: ⌘1–⌘3 mở các trang Theo dõi, ⌘, mở Giới hạn sạc.
struct AppCommands: Commands {
    @AppStorage(Page.storageKey) private var page: Page = .overview
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Cài đặt…") { show(.limit) }
                .keyboardShortcut(",")
        }
        CommandGroup(before: .sidebar) {
            Button("Tổng quan") { show(.overview) }.keyboardShortcut("1")
            Button("Lịch sử") { show(.history) }.keyboardShortcut("2")
            Button("Tình trạng pin") { show(.health) }.keyboardShortcut("3")
            Divider()
        }
    }

    private func show(_ target: Page) {
        page = target
        openWindow(id: WindowID.dashboard)
    }
}

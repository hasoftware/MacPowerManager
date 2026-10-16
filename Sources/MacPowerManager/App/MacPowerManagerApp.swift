import AppKit
import SwiftUI
import UserNotifications

@main
struct MacPowerManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        // Lệnh `mpm` (dòng lệnh, Phím tắt): làm xong rồi thoát, không mở giao diện.
        if let index = CommandLine.arguments.firstIndex(of: "--cli") {
            exit(CommandLineTool.run(Array(CommandLine.arguments.dropFirst(index + 1))))
        }
        #if DEBUG
        // Chế độ chụp giao diện để kiểm tra bố cục: vẽ các màn hình với dữ liệu giả rồi thoát.
        if let index = CommandLine.arguments.firstIndex(of: "--render-snapshots") {
            let path = CommandLine.arguments.dropFirst(index + 1).first ?? "/tmp/mpm-snapshots"
            SnapshotRenderer.run(directory: URL(fileURLWithPath: path))
            exit(0)
        }
        // Đo CPU của từng trang với dữ liệu thật trong cửa sổ ngoài màn hình rồi thoát.
        if let index = CommandLine.arguments.firstIndex(of: "--bench") {
            Benchmark.run(Array(CommandLine.arguments.dropFirst(index + 1)))
            exit(0)
        }
        // Quét dọn dẹp (CleanCore) trên máy thật, chỉ đọc: in mọi finding + thời gian từng bộ quét rồi thoát.
        if CommandLine.arguments.contains("--clean-scan") {
            CleanScanDebug.run()
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
        let model = AppModel()
        _model = State(initialValue: model)
        AppDelegate.handleURL = { url in model.handle(url: url) }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(model)
                .environment(\.locale, Format.locale)
                .onAppear { model.setPopoverVisible(true) }
                .onDisappear { model.setPopoverVisible(false) }
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

        Window("Có gì mới", id: WindowID.whatsNew) {
            WhatsNewView()
                .environment(model)
                .environment(\.locale, Format.locale)
        }
        .defaultSize(width: WhatsNewView.size.width, height: WhatsNewView.size.height)
        .windowResizability(.contentMinSize)
    }
}

/// Mở lại app (Finder, Spotlight) khi không có cửa sổ thì mở bảng điều khiển: mục thanh menu có thể bị notch che.
/// Bấm thông báo "Có phiên bản mới" thì mở cửa sổ Có gì mới.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor static var openDashboard: (() -> Void)?
    @MainActor static var openWhatsNew: (() -> Void)? {
        didSet {
            if pendingWhatsNew, let openWhatsNew {
                pendingWhatsNew = false
                openWhatsNew()
            }
        }
    }
    /// Thông báo được bấm trước khi giao diện sẵn sàng (app vừa được mở bởi chính thông báo đó).
    @MainActor static var pendingWhatsNew = false
    /// Xử lý URL `macpowermanager://…` (Phím tắt, script). Do `MacPowerManagerApp` gán.
    @MainActor static var handleURL: ((URL) -> Void)?

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in urls.forEach { Self.handleURL?($0) } }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // UNUserNotificationCenter chỉ dùng được khi chạy trong app bundle.
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let isUpdate = response.notification.request.identifier == Notifier.requestIdentifier(Notifier.updateNotificationID)
        Task { @MainActor in
            if isUpdate {
                if let open = Self.openWhatsNew { open() } else { Self.pendingWhatsNew = true }
                NSApp.activate(ignoringOtherApps: true)
            }
            completionHandler()
        }
    }

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

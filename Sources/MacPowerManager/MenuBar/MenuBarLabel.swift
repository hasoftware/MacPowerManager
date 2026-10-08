import AppKit
import SwiftUI

extension AppModel {
    /// Nội dung mục thanh menu theo trạng thái hiện tại và tùy chọn của người dùng.
    var menuBarContent: MenuBarContent {
        let summary = summary
        let full = battery?.externalConnected == true && (battery?.fullyCharged == true || summary.percent >= 100)
        return MenuBarContent(percent: battery?.percent, limit: summary.limit, state: summary.state,
                              style: prefs.menuBarStyle,
                              showPercent: prefs.showPercentInMenuBar && !(prefs.hidePercentWhenFull && full),
                              colored: prefs.menuBarColored)
    }
}

/// Nhãn của `MenuBarExtra`: một ảnh duy nhất (biểu tượng + phần trăm) do `MenuBarRenderer` vẽ.
/// Khởi động model khi nhãn xuất hiện lần đầu (ngay lúc mở app).
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: MenuBarRenderer.image(for: model.menuBarContent))
            .task {
                AppDelegate.openDashboard = { openWindow(id: WindowID.dashboard) }
                AppDelegate.openWhatsNew = { openWindow(id: WindowID.whatsNew) }
                model.start()
            }
    }
}

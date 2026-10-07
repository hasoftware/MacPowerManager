import AppKit
import PowerCore
import SwiftUI

/// Cửa sổ bảng điều khiển: thanh bên chia nhóm Theo dõi / Chăm sóc pin / Ứng dụng.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Page.storageKey) private var page: Page = .overview

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<Page?>(get: { current }, set: { if let p = $0 { page = p } })) {
                Section("Theo dõi") { rows(Page.monitor) }
                Section("Chăm sóc pin") { rows(Page.care.filter(isVisible)) }
                Section("Ứng dụng") { rows(Page.app) }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            PageView(page: current)
                .navigationTitle(current.title)
        }
        // App chỉ sống trên thanh menu; hiện biểu tượng Dock khi bảng điều khiển đang mở để dễ chuyển cửa sổ.
        .onAppear {
            guard !model.isPreview else { return }
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear {
            guard !model.isPreview else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Trang đã lưu có thể không áp dụng trên máy này (ví dụ Xả pin trên Intel).
    private var current: Page { isVisible(page) ? page : .overview }

    private func isVisible(_ page: Page) -> Bool {
        !(page.appleSiliconOnly && model.isIntel)
    }

    private func rows(_ pages: [Page]) -> some View {
        ForEach(pages) { page in
            Label(page.title, systemImage: page.symbol)
                .badge(page == .system && model.hasSystemIssue ? Text("!") : nil)
                .tag(page)
        }
    }
}

struct PageView: View {
    let page: Page

    var body: some View {
        switch page {
        case .overview: OverviewPage()
        case .history: HistoryPage()
        case .health: HealthPage()
        case .limit: LimitPage()
        case .heat: HeatPage()
        case .discharge: DischargePage()
        case .sleep: SleepPage()
        case .menuBar: MenuBarPage()
        case .notifications: NotificationsPage()
        case .system: SystemPage()
        case .about: AboutPage()
        }
    }
}

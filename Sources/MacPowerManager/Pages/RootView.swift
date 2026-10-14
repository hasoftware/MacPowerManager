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
                Section("Hệ thống") { rows(Page.systemGroup) }
                Section("Chăm sóc pin") { rows(Page.care.filter(isVisible)) }
                Section("Ứng dụng") { rows(Page.app) }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            PageView(page: current)
                .navigationTitle(current.title)
        }
        // App chỉ sống trên thanh menu; hiện biểu tượng Dock khi bảng điều khiển đang mở để dễ chuyển cửa sổ.
        // Đo số liệu hệ thống chỉ khi bảng điều khiển đang mở (giá trị trên thanh bên, các trang Hệ thống).
        .onAppear { model.system.retain() }
        .onDisappear { model.system.release() }
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

    private func badge(for page: Page) -> Text? {
        let latest = model.system.latest
        switch page {
        case .system: return model.hasSystemIssue ? Text("!") : nil
        case .cpu: return latest.map { Text(verbatim: Format.percent($0.cpu.total * 100)) }
        case .memory: return latest.map { Text(verbatim: Format.percent(Double($0.memory.used) / Double(max($0.memory.total, 1)) * 100)) }
        case .processes: return model.processes.rows.isEmpty ? nil : Text(verbatim: "\(model.processes.rows.count)")
        case .energy: return (latest?.systemPower).map { Text(verbatim: Format.watts($0)) }
        case .gpu: return latest?.gpu.map { Text(verbatim: Format.percent($0.device * 100)) }
        case .disk: return latest.map { Text(verbatim: Format.rate($0.diskRead + $0.diskWrite)) }
        case .network: return latest.map { Text(verbatim: Format.rate($0.networkIn + $0.networkOut)) }
        default: return nil
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
                .badge(badge(for: page))
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
        case .cpu: CPUPage()
        case .memory: MemoryPage()
        case .gpu: GPUPage()
        case .disk: DiskPage()
        case .network: NetworkPage()
        case .processes: ProcessesPage()
        case .energy: EnergyPage()
        case .aboutMac: AboutMacPage()
        case .limit: LimitPage()
        case .heat: HeatPage()
        case .discharge: DischargePage()
        case .calibration: CalibrationPage()
        case .sleep: SleepPage()
        case .menuBar: MenuBarPage()
        case .notifications: NotificationsPage()
        case .system: SystemPage()
        case .about: AboutPage()
        }
    }
}

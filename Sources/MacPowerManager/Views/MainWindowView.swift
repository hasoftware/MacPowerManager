import SwiftUI

struct MainWindowView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            OverviewView()
                .tabItem { Label("Tổng quan", systemImage: "battery.75percent") }
            ControlsView()
                .tabItem { Label("Điều khiển sạc", systemImage: "slider.horizontal.3") }
            HistoryView()
                .tabItem { Label("Lịch sử", systemImage: "chart.xyaxis.line") }
            SettingsView()
                .tabItem { Label("Cài đặt", systemImage: "gearshape") }
        }
        .padding()
    }
}

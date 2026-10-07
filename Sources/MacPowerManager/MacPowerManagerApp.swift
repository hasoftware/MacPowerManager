import AppKit
import SwiftUI

@main
struct MacPowerManagerApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("MacPowerManager", id: "main") {
            MainWindowView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 540)
        }
        .windowResizability(.contentMinSize)
    }
}

struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: model.batterySymbol)
            if model.prefs.showPercentInMenuBar, let battery = model.battery {
                Text("\(battery.percent)%")
            }
        }
        .task { model.start() }
    }
}

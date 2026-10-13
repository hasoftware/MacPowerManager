import PowerCore
import SwiftUI

/// Tổng quan hệ thống: mỗi nhóm (CPU, bộ nhớ, năng lượng) một thẻ có biểu đồ nhỏ; bấm thẻ để xem chi tiết.
struct SystemOverviewPage: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Page.storageKey) private var page: Page = .overview

    var body: some View {
        let monitor = model.system
        let latest = monitor.latest
        let memory = latest?.memory
        MonitorPage { width in
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.m, alignment: .top),
                                     count: width >= 900 ? 3 : 2),
                      spacing: Theme.Space.m) {
                OverviewTile(title: "CPU", symbol: "cpu", tint: SystemTint.cpu, target: .cpu, page: $page) {
                    BigValue(caption: "Hiện tại", value: Format.percentNumber(latest?.cpu.total ?? 0), unit: "%")
                    HStack {
                        SystemStat(title: "Người dùng", value: Format.percent((latest?.cpu.user ?? 0) * 100))
                        SystemStat(title: "Hệ thống", value: Format.percent((latest?.cpu.system ?? 0) * 100))
                        SystemStat(title: "Nhiệt độ", value: Format.temperature(latest?.cpuTemperature))
                    }
                    DotMatrixChart(columns: monitor.columns(36) { [$0.cpu.system, $0.cpu.user] },
                                   colors: [SystemTint.cpuSystem, SystemTint.cpu], rows: 6, tint: SystemTint.cpu)
                        .frame(height: 82)
                }

                OverviewTile(title: "Bộ nhớ", symbol: "memorychip", tint: SystemTint.memory, target: .memory, page: $page) {
                    let used = Format.bytesParts(memory?.used ?? 0)
                    HStack(alignment: .top) {
                        BigValue(caption: "Đang dùng trong \(Format.bytes(memory?.total ?? 0))", value: used.value, unit: used.unit)
                        Spacer()
                        if let memory, memory.pressureLevel > 1 { PressureBadge(level: memory.pressureLevel) }
                    }
                    HStack {
                        SystemStat(title: "App", value: Format.bytes(memory?.app ?? 0))
                        SystemStat(title: "Wired", value: Format.bytes(memory?.wired ?? 0))
                        SystemStat(title: "Đã nén", value: Format.bytes(memory?.compressed ?? 0))
                    }
                    DotMatrixChart(columns: monitor.columns(36) { s in
                                       let t = Double(max(s.memory.total, 1))
                                       return [Double(s.memory.wired) / t, Double(s.memory.compressed) / t, Double(s.memory.app) / t]
                                   },
                                   colors: [SystemTint.memoryWired, SystemTint.memoryCompressed, SystemTint.memory],
                                   rows: 6, tint: SystemTint.memory)
                        .frame(height: 82)
                }

                OverviewTile(title: "Năng lượng", symbol: "bolt.fill", tint: SystemTint.energy, target: .health, page: $page) {
                    let battery = model.battery
                    BigValue(caption: battery?.externalConnected == true ? "Đang cắm sạc" : "Đang dùng pin",
                             value: "\(battery?.percent ?? 0)", unit: "%")
                    HStack {
                        SystemStat(title: "Máy tiêu thụ", value: Format.watts(latest?.systemPower ?? battery?.systemLoad))
                        SystemStat(title: "Pin", value: battery.map { Format.watts($0.batteryPower, signed: true) } ?? "—")
                        SystemStat(title: "Sức khỏe", value: battery.map { Format.percent(model.healthPercent($0)) } ?? "—")
                    }
                    let peak = max((monitor.stats { $0.systemPower ?? 0 }?.peak ?? 1) * 1.2, 1)
                    DotMatrixChart(columns: monitor.columns(36) { [($0.systemPower ?? 0) / peak] },
                                   colors: [SystemTint.energy], rows: 6, tint: SystemTint.energy)
                        .frame(height: 82)
                }
            }
        }
        .toolbar { SystemToolbar(monitor: monitor) }
    }
}

/// Thẻ bấm được để mở trang chi tiết.
private struct OverviewTile<Content: View>: View {
    let title: LocalizedStringKey
    let symbol: String
    let tint: Color
    let target: Page
    @Binding var page: Page
    @ViewBuilder var content: Content

    var body: some View {
        Button {
            page = target
        } label: {
            Card(title: title, symbol: symbol, tint: tint) {
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            } content: {
                VStack(alignment: .leading, spacing: Theme.Space.m) { content }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

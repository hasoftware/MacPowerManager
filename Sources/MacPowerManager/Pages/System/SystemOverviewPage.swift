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

                OverviewTile(title: "GPU", symbol: "cube.transparent", tint: SystemTint.gpu, target: .gpu, page: $page) {
                    let gpu = latest?.gpu
                    BigValue(caption: "\(gpu?.model ?? "GPU")", value: Format.percentNumber(gpu?.device ?? 0, digits: 1), unit: "%")
                    HStack {
                        SystemStat(title: "Bộ nhớ", value: Format.bytes(gpu?.memoryInUse ?? 0))
                        SystemStat(title: "Trung bình", value: monitor.stats { $0.gpu?.device ?? 0 }.map { Format.percent($0.average * 100) } ?? "—")
                        SystemStat(title: "Cao nhất", value: monitor.stats { $0.gpu?.device ?? 0 }.map { Format.percent($0.peak * 100) } ?? "—")
                    }
                    DotMatrixChart(columns: monitor.columns(36) { [$0.gpu?.device ?? 0] }, colors: [SystemTint.gpu], rows: 6, tint: SystemTint.gpu)
                        .frame(height: 82)
                }

                OverviewTile(title: "Ổ đĩa", symbol: "internaldrive", tint: SystemTint.disk, target: .disk, page: $page) {
                    let root = monitor.volumes.first
                    let free = Format.bytesParts(root?.available ?? 0)
                    BigValue(caption: "Còn trống trong \(Format.bytes(root?.total ?? 0))", value: free.value, unit: free.unit)
                    HStack {
                        SystemStat(title: "Đọc", value: Format.rate(latest?.diskRead ?? 0))
                        SystemStat(title: "Ghi", value: Format.rate(latest?.diskWrite ?? 0))
                        SystemStat(title: "Đã ghi", value: Format.bytes(monitor.diskTotals?.bytesWritten ?? 0))
                    }
                    let peak = max(monitor.stats { $0.diskRead + $0.diskWrite }?.peak ?? 0, 1_000_000)
                    DotMatrixChart(columns: monitor.columns(36) { [$0.diskWrite / peak, $0.diskRead / peak] },
                                   colors: [SystemTint.diskWrite, SystemTint.diskRead], rows: 6, tint: SystemTint.disk)
                        .frame(height: 82)
                }

                OverviewTile(title: "Mạng", symbol: "network", tint: SystemTint.network, target: .network, page: $page) {
                    let down = Format.rateParts(latest?.networkIn ?? 0)
                    BigValue(caption: "Tải xuống", value: down.value, unit: down.unit)
                    HStack {
                        SystemStat(title: "Tải lên", value: Format.rate(latest?.networkOut ?? 0))
                        SystemStat(title: "Đã nhận", value: monitor.networkTotals.map { Format.bytes($0.received) } ?? "—")
                        SystemStat(title: "Đã gửi", value: monitor.networkTotals.map { Format.bytes($0.sent) } ?? "—")
                    }
                    let peak = max(monitor.stats { $0.networkIn + $0.networkOut }?.peak ?? 0, 100_000)
                    DotMatrixChart(columns: monitor.columns(36) { [$0.networkOut / peak, $0.networkIn / peak] },
                                   colors: [SystemTint.networkUp, SystemTint.network], rows: 6, tint: SystemTint.network)
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

import PowerCore
import SwiftUI

/// Năng lượng: pin, công suất cả máy, năng lượng theo ứng dụng và nhiệt độ các bộ phận.
struct EnergyPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let monitor = model.system
        let processes = model.processes
        let latest = monitor.latest
        let battery = model.battery
        MonitorPage { width in
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if let battery {
                    Card(title: "Pin", symbol: "battery.75percent", tint: .green) {
                        ThermalBadge(state: ProcessInfo.processInfo.thermalState)
                    } content: {
                        HStack(alignment: .center, spacing: Theme.Space.xl) {
                            RingGauge(segments: [(Double(battery.percent) / 100, model.summary.state.tint)],
                                      center: "\(battery.percent)%",
                                      caption: battery.externalConnected ? "Đang cắm sạc" : "Đang dùng pin", lineWidth: 10)
                                .frame(width: 120, height: 120)
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
                                      alignment: .leading, spacing: Theme.Space.l) {
                                SystemStat(title: "Còn lại", value: remaining(battery))
                                SystemStat(title: "Dòng vào pin", value: Format.watts(battery.batteryPower, signed: true))
                                SystemStat(title: "Sức khỏe", value: Format.percent(model.healthPercent(battery)))
                                SystemStat(title: "Số lần sạc", value: Format.integer(battery.cycleCount))
                                SystemStat(title: "Dung lượng", value: "\(Format.integer(battery.maxCapacity)) mAh",
                                           note: String(localized: "thiết kế \(Format.integer(battery.designCapacity))"))
                                SystemStat(title: "Bộ sạc", value: battery.adapterWatts.map { "\($0) W" } ?? "—",
                                           note: battery.adapterName)
                            }
                        }
                    }
                }

                Card(title: "Công suất", symbol: "bolt.fill", tint: SystemTint.energy) {
                    let power = latest?.systemPower ?? battery?.systemLoad
                    HStack(alignment: .bottom, spacing: Theme.Space.xl) {
                        BigValue(caption: "Cả máy đang dùng", value: power.map { Format.number($0, digits: 1) } ?? "—", unit: "W")
                        SystemStat(title: "Tiến trình", value: Format.power(processes.totalPower))
                        SystemStat(title: "Trung bình", value: monitor.stats { $0.systemPower ?? 0 }.map { Format.watts($0.average) } ?? "—")
                        SystemStat(title: "Cao nhất", value: monitor.stats { $0.systemPower ?? 0 }.map { Format.watts($0.peak) } ?? "—")
                    }
                    let peak = max((monitor.stats { $0.systemPower ?? 0 }?.peak ?? 0) * 1.2, 5)
                    DotMatrixChart(columns: monitor.columns(60) { [($0.systemPower ?? 0) / peak] }, colors: [SystemTint.energy],
                                   axis: DotMatrixChart.axis(for: monitor.range, now: String(localized: "bây giờ")),
                                   tint: SystemTint.energy)
                        .frame(height: 180)
                }

                HStack(alignment: .top, spacing: Theme.Space.m) {
                    Card(title: "Năng lượng theo ứng dụng", symbol: "bolt.horizontal.fill", tint: SystemTint.energy) {
                        Text(verbatim: Format.power(processes.totalPower)).font(.callout).foregroundStyle(.secondary)
                    } content: {
                        let top = processes.top(8) { $0.power }
                        if top.isEmpty {
                            Text("Đang đo…").foregroundStyle(.secondary)
                        } else {
                            let peak = max(top.first?.power ?? 1, 0.001)
                            VStack(spacing: 10) {
                                ForEach(top) { row in
                                    TopRow(row: row, value: Format.power(row.power), fraction: row.power / peak, tint: SystemTint.energy)
                                }
                            }
                        }
                    }
                    Card(title: "Nhiệt độ", symbol: "thermometer.medium", tint: .orange) {
                        VStack(spacing: 12) {
                            TemperatureRow(title: "Bộ xử lý", value: latest?.cpuTemperature,
                                           note: latest?.cpuHottest.map { String(localized: "nóng nhất \(Format.temperature($0))") })
                            TemperatureRow(title: "GPU", value: latest?.gpuTemperature)
                            TemperatureRow(title: "Pin", value: model.temperature)
                        }
                    }
                }
            }
        }
        .toolbar { SystemToolbar(monitor: monitor) }
        .onAppear { processes.retain() }
        .onDisappear { processes.release() }
    }

    private func remaining(_ battery: BatteryInfo) -> String {
        if battery.externalConnected && !battery.isCharging { return String(localized: "Đang cắm sạc") }
        return battery.timeRemaining.map { Format.duration(minutes: $0) } ?? "—"
    }
}

/// Một dòng trong bảng "dùng nhiều nhất": biểu tượng, tên, giá trị, thanh tỉ lệ.
struct TopRow: View {
    let row: ProcessMonitor.Row
    let value: String
    let fraction: Double
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ProcessIcon(row: row, size: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(verbatim: row.name).lineLimit(1)
                    Spacer()
                    Text(verbatim: value).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
                MeterBar(value: fraction, tint: tint)
            }
        }
    }
}

private struct TemperatureRow: View {
    let title: LocalizedStringKey
    let value: Double?
    var note: String?

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.callout)
                if let note { Text(verbatim: note).font(.caption).foregroundStyle(.secondary) }
            }
            .frame(width: 110, alignment: .leading)
            // Thang 20–100 °C; xanh dưới 60, cam tới 80, đỏ trên 80.
            let fraction = ((value ?? 20) - 20) / 80
            MeterBar(value: fraction, tint: (value ?? 0) > 80 ? .red : (value ?? 0) > 60 ? .orange : .green)
            Text(verbatim: Format.temperature(value)).font(.callout.monospacedDigit()).frame(width: 64, alignment: .trailing)
        }
    }
}

private struct ThermalBadge: View {
    let state: ProcessInfo.ThermalState

    var body: some View {
        let (title, color): (LocalizedStringKey, Color) = switch state {
        case .nominal: ("Nhiệt độ bình thường", .green)
        case .fair: ("Hơi ấm", .yellow)
        case .serious: ("Nóng", .orange)
        case .critical: ("Rất nóng", .red)
        @unknown default: ("Nhiệt độ bình thường", .green)
        }
        Label(title, systemImage: state == .nominal ? "checkmark" : "thermometer.high")
            .font(.callout.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
    }
}

/// Thẻ "dùng … nhiều nhất" (CPU, ổ đĩa) với nút mở trang Tiến trình.
struct TopProcessesCard: View {
    let title: LocalizedStringKey
    let symbol: String
    let tint: Color
    let rows: [ProcessMonitor.Row]
    let value: (ProcessMonitor.Row) -> Double
    let format: (ProcessMonitor.Row) -> String
    @AppStorage(Page.storageKey) private var page: Page = .overview

    var body: some View {
        Card(title: title, symbol: symbol, tint: tint) {
            Button {
                page = .processes
            } label: {
                Label("Xem tất cả", systemImage: "chevron.right").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.link)
        } content: {
            if rows.isEmpty {
                Text("Đang đo…").foregroundStyle(.secondary)
            } else {
                let peak = max(rows.map(value).max() ?? 1, 0.000_001)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Space.xl), GridItem(.flexible())], spacing: 10) {
                    ForEach(rows) { row in
                        TopRow(row: row, value: format(row), fraction: value(row) / peak, tint: tint)
                    }
                }
            }
        }
    }
}

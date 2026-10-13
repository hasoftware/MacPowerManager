import PowerCore
import SwiftUI

/// CPU: tải tổng (người dùng / hệ thống), nhiệt độ, từng nhân, tải trung bình của hệ thống.
struct CPUPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let monitor = model.system
        let latest = monitor.latest
        let topology = monitor.topology
        MonitorPage { width in
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Card(title: "Tải bộ xử lý", symbol: "cpu", tint: SystemTint.cpu) {
                    ColorLegend(items: [("Người dùng", SystemTint.cpu), ("Hệ thống", SystemTint.cpuSystem)])
                } content: {
                    HStack(alignment: .bottom, spacing: Theme.Space.xl) {
                        BigValue(caption: "Hiện tại", value: Format.percentNumber(latest?.cpu.total ?? 0), unit: "%")
                        SystemStat(title: "Người dùng", value: Format.percent((latest?.cpu.user ?? 0) * 100))
                        SystemStat(title: "Hệ thống", value: Format.percent((latest?.cpu.system ?? 0) * 100))
                        SystemStat(title: "Nhiệt độ", value: Format.temperature(latest?.cpuTemperature),
                                   note: latest?.cpuHottest.map { String(localized: "nóng nhất \(Format.temperature($0))") })
                        SystemStat(title: "Trung bình", value: monitor.stats { $0.cpu.total }.map { Format.percent($0.average * 100) } ?? "—")
                    }
                    DotMatrixChart(columns: monitor.columns(60) { [$0.cpu.system, $0.cpu.user] },
                                   colors: [SystemTint.cpuSystem, SystemTint.cpu],
                                   axis: DotMatrixChart.axis(for: monitor.range, now: String(localized: "bây giờ")),
                                   tint: SystemTint.cpu)
                        .frame(height: 200)
                }

                HStack(alignment: .top, spacing: Theme.Space.m) {
                    Card(title: "Các nhân", symbol: "square.grid.3x3.fill", tint: SystemTint.cpu) {
                        Text("\(topology.logicalCores) nhân").font(.callout).foregroundStyle(.secondary)
                    } content: {
                        let cores = latest?.cpu.perCore ?? Array(repeating: 0, count: topology.logicalCores)
                        let indices = Array(cores.indices)
                        if topology.efficiencyCores > 0 {
                            CoreGroup(title: "Nhân hiệu năng", cores: cores,
                                      indices: indices.filter { !topology.isEfficiency(core: $0) }, tint: SystemTint.cpu)
                            CoreGroup(title: "Nhân tiết kiệm điện", cores: cores,
                                      indices: indices.filter { topology.isEfficiency(core: $0) }, tint: .teal)
                        } else {
                            CoreGroup(title: nil, cores: cores, indices: indices, tint: SystemTint.cpu)
                        }
                    }
                    .frame(width: width * 0.58)

                    Card(title: "Hoạt động", symbol: "waveform.path.ecg", tint: .secondary) {
                        let activity = monitor.activity
                        VStack(spacing: 8) {
                            InfoRow("Tải 1 phút", "\(Format.number(activity.load1, digits: 2)) · \(loadLabel(activity.load1, topology))")
                            InfoRow("Tải 5 phút", Format.number(activity.load5, digits: 2))
                            InfoRow("Tải 15 phút", Format.number(activity.load15, digits: 2))
                            InfoRow("Tiến trình", Format.integer(activity.processCount))
                            InfoRow("Thời gian chạy", Format.uptime(since: activity.bootTime))
                        }
                    }
                }

                Footnote("Tải là số tác vụ đang chờ CPU trung bình theo thời gian; dưới số nhân (\(topology.logicalCores)) là máy còn rảnh.")
            }
        }
        .toolbar { SystemToolbar(monitor: monitor) }
    }

    private func loadLabel(_ load: Double, _ topology: CPUTopology) -> String {
        let ratio = load / Double(max(topology.logicalCores, 1))
        if ratio < 0.4 { return String(localized: "Thấp") }
        if ratio < 0.8 { return String(localized: "Vừa") }
        return String(localized: "Cao")
    }
}

/// Một nhóm nhân (hiệu năng / tiết kiệm điện), hai cột, mỗi nhân một thanh.
private struct CoreGroup: View {
    let title: LocalizedStringKey?
    let cores: [Double]
    let indices: [Int]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Space.l), GridItem(.flexible())], spacing: 8) {
                ForEach(indices, id: \.self) { index in
                    let value = index < cores.count ? cores[index] : 0
                    HStack(spacing: 8) {
                        Text("Nhân \(index + 1)").font(.callout).foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .leading)
                        MeterBar(value: value, tint: tint)
                        Text(verbatim: Format.percent(value * 100)).font(.callout.monospacedDigit())
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
        .padding(.bottom, 4)
    }
}

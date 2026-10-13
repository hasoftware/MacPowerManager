import PowerCore
import SwiftUI

/// GPU: mức dùng (Device / Renderer / Tiler) và bộ nhớ GPU trong bộ nhớ hợp nhất.
struct GPUPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let monitor = model.system
        let gpu = monitor.latest?.gpu
        MonitorPage { width in
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Card(title: "Đồ họa", symbol: "cube.transparent", tint: SystemTint.gpu) {
                    HStack(alignment: .bottom, spacing: Theme.Space.xl) {
                        BigValue(caption: "\(gpu?.model ?? "GPU")", value: Format.percentNumber(gpu?.device ?? 0, digits: 1), unit: "%")
                        SystemStat(title: "Renderer", value: Format.percent((gpu?.renderer ?? 0) * 100))
                        SystemStat(title: "Tiler", value: Format.percent((gpu?.tiler ?? 0) * 100))
                        SystemStat(title: "Bộ nhớ", value: Format.bytes(gpu?.memoryInUse ?? 0))
                        SystemStat(title: "Cao nhất", value: monitor.stats { $0.gpu?.device ?? 0 }.map { Format.percent($0.peak * 100) } ?? "—")
                    }
                    DotMatrixChart(columns: monitor.columns(60) { [$0.gpu?.device ?? 0] }, colors: [SystemTint.gpu],
                                   axis: DotMatrixChart.axis(for: monitor.range, now: String(localized: "bây giờ")),
                                   tint: SystemTint.gpu)
                        .frame(height: 200)
                }

                HStack(alignment: .top, spacing: Theme.Space.m) {
                    Card(title: "Thông tin", symbol: "info.circle", tint: SystemTint.gpu) {
                        VStack(spacing: 8) {
                            InfoRow("Mẫu", gpu?.model ?? "—")
                            InfoRow("Số nhân", gpu?.cores.map(String.init) ?? "—")
                            InfoRow("Bộ nhớ đang dùng", Format.bytes(gpu?.memoryInUse ?? 0))
                            InfoRow("Bộ nhớ đã cấp phát", Format.bytes(gpu?.memoryAllocated ?? 0))
                            InfoRow("Bộ nhớ hợp nhất", Format.bytes(monitor.latest?.memory.total ?? 0))
                        }
                    }
                    Card(title: "Bộ phận", symbol: "waveform.path.ecg", tint: SystemTint.gpu) {
                        VStack(spacing: 12) {
                            EngineRow(title: "Device", value: gpu?.device ?? 0)
                            EngineRow(title: "Renderer", value: gpu?.renderer ?? 0)
                            EngineRow(title: "Tiler", value: gpu?.tiler ?? 0)
                        }
                    }
                }
                Footnote("Device: mức bận chung của GPU. Renderer: vẽ điểm ảnh. Tiler: chia cảnh thành ô. GPU dùng chung bộ nhớ với CPU (bộ nhớ hợp nhất).")
            }
        }
        .toolbar { SystemToolbar(monitor: monitor) }
    }
}

private struct EngineRow: View {
    let title: String
    let value: Double

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Text(verbatim: title).font(.callout).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            MeterBar(value: value, tint: SystemTint.gpu)
            Text(verbatim: Format.percent(value * 100)).font(.callout.monospacedDigit()).frame(width: 48, alignment: .trailing)
        }
    }
}

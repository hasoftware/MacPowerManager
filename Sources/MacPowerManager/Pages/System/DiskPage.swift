import PowerCore
import SwiftUI

/// Ổ đĩa: tốc độ đọc/ghi, tổng từ lúc khởi động, dung lượng từng ổ.
struct DiskPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let monitor = model.system
        let latest = monitor.latest
        let total = Format.rateParts((latest?.diskRead ?? 0) + (latest?.diskWrite ?? 0))
        MonitorPage { width in
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Card(title: "Hoạt động ổ đĩa", symbol: "internaldrive", tint: SystemTint.disk) {
                    ColorLegend(items: [("Ghi", SystemTint.diskWrite), ("Đọc", SystemTint.diskRead)])
                } content: {
                    HStack(alignment: .bottom, spacing: Theme.Space.xl) {
                        BigValue(caption: "Đọc và ghi", value: total.value, unit: total.unit)
                        SystemStat(title: "Đọc", value: Format.rate(latest?.diskRead ?? 0))
                        SystemStat(title: "Ghi", value: Format.rate(latest?.diskWrite ?? 0))
                        SystemStat(title: "Đã đọc", value: Format.bytes(monitor.diskTotals?.bytesRead ?? 0), note: String(localized: "từ lúc khởi động"))
                        SystemStat(title: "Đã ghi", value: Format.bytes(monitor.diskTotals?.bytesWritten ?? 0), note: String(localized: "từ lúc khởi động"))
                    }
                    let peak = max(monitor.stats { $0.diskRead + $0.diskWrite }?.peak ?? 0, 1_000_000)
                    DotMatrixChart(columns: monitor.columns(60) { [$0.diskWrite / peak, $0.diskRead / peak] },
                                   colors: [SystemTint.diskWrite, SystemTint.diskRead],
                                   axis: DotMatrixChart.axis(for: monitor.range, now: String(localized: "bây giờ")),
                                   tint: SystemTint.disk)
                        .frame(height: 200)
                }

                ForEach(monitor.volumes) { volume in
                    Card(title: Text(verbatim: volume.name), symbol: volume.isInternal ? "internaldrive" : "externaldrive", tint: SystemTint.disk) {
                        let free = Format.bytesParts(volume.available)
                        BigValue(caption: "Còn trống trong \(Format.bytes(volume.total))", value: free.value, unit: free.unit)
                        MeterBar(value: Double(volume.used) / Double(max(volume.total, 1)), tint: SystemTint.disk)
                        HStack {
                            SystemStat(title: "Đã dùng", value: Format.bytes(volume.used))
                            SystemStat(title: "Định dạng", value: volume.format ?? "—")
                            SystemStat(title: "Thiết bị", value: volume.device ?? "—")
                        }
                    }
                }
            }
        }
        .toolbar { SystemToolbar(monitor: monitor) }
    }
}

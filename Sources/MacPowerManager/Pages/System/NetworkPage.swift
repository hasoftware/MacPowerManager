import PowerCore
import SwiftUI

/// Mạng: tốc độ tải xuống / tải lên, tổng từ lúc khởi động, giao diện mạng đang dùng.
struct NetworkPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let monitor = model.system
        let latest = monitor.latest
        let down = Format.rateParts(latest?.networkIn ?? 0)
        MonitorPage { width in
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Card(title: "Mạng", symbol: "network", tint: SystemTint.network) {
                    ColorLegend(items: [("Tải xuống", SystemTint.network), ("Tải lên", SystemTint.networkUp)])
                } content: {
                    HStack(alignment: .bottom, spacing: Theme.Space.xl) {
                        BigValue(caption: "Tải xuống", value: down.value, unit: down.unit)
                        SystemStat(title: "Tải lên", value: Format.rate(latest?.networkOut ?? 0))
                        SystemStat(title: "Đã nhận", value: monitor.networkTotals.map { Format.bytes($0.received) } ?? "—",
                                   note: String(localized: "từ lúc khởi động"))
                        SystemStat(title: "Đã gửi", value: monitor.networkTotals.map { Format.bytes($0.sent) } ?? "—",
                                   note: String(localized: "từ lúc khởi động"))
                        SystemStat(title: "Cao nhất", value: monitor.stats { $0.networkIn }.map { Format.rate($0.peak) } ?? "—")
                    }
                    let peak = max(monitor.stats { $0.networkIn + $0.networkOut }?.peak ?? 0, 100_000)
                    DotMatrixChart(columns: monitor.columns(60) { [$0.networkOut / peak, $0.networkIn / peak] },
                                   colors: [SystemTint.networkUp, SystemTint.network],
                                   axis: DotMatrixChart.axis(for: monitor.range, now: String(localized: "bây giờ")),
                                   tint: SystemTint.network)
                        .frame(height: 200)
                }

                if let interface = monitor.primaryInterface {
                    Card(title: Text(verbatim: interface.displayName), symbol: interface.displayName == "Wi-Fi" ? "wifi" : "cable.connector",
                         tint: SystemTint.network) {
                        Text(verbatim: interface.bsdName).font(.callout.monospaced()).foregroundStyle(.secondary)
                    } content: {
                        VStack(spacing: 8) {
                            InfoRow("IPv4", interface.ipv4 ?? "—")
                            InfoRow("IPv6", interface.ipv6 ?? "—")
                            InfoRow("Địa chỉ phần cứng", interface.hardwareAddress ?? "—")
                        }
                        .textSelection(.enabled)
                    }
                } else {
                    Card(title: "Không có kết nối mạng", symbol: "wifi.slash", tint: .secondary) {
                        Text("Máy chưa kết nối Internet.").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .toolbar { SystemToolbar(monitor: monitor) }
    }
}

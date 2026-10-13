import PowerCore
import SwiftUI

/// Bộ nhớ: đang dùng (App, Wired, Compressed), cache, áp lực bộ nhớ và swap, theo cách Activity Monitor tính.
struct MemoryPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let monitor = model.system
        let memory = monitor.latest?.memory
        let total = Double(max(memory?.total ?? 1, 1))
        MonitorPage { width in
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Card(title: "Bộ nhớ", symbol: "memorychip", tint: SystemTint.memory) {
                    HStack(spacing: Theme.Space.m) {
                        ColorLegend(items: [("App", SystemTint.memory), ("Đã nén", SystemTint.memoryCompressed),
                                            ("Wired", SystemTint.memoryWired)])
                        if let memory { PressureBadge(level: memory.pressureLevel) }
                    }
                } content: {
                    let used = Format.bytesParts(memory?.used ?? 0)
                    HStack(alignment: .bottom, spacing: Theme.Space.xl) {
                        BigValue(caption: "Đang dùng trong \(Format.bytes(memory?.total ?? 0))", value: used.value, unit: used.unit)
                        SystemStat(title: "App", value: Format.bytes(memory?.app ?? 0))
                        SystemStat(title: "Wired", value: Format.bytes(memory?.wired ?? 0))
                        SystemStat(title: "Đã nén", value: Format.bytes(memory?.compressed ?? 0))
                        SystemStat(title: "Cache", value: Format.bytes(memory?.cached ?? 0))
                    }
                    if let memory {
                        SegmentedBar(segments: [(Double(memory.app) / total, SystemTint.memory),
                                                (Double(memory.wired) / total, SystemTint.memoryWired),
                                                (Double(memory.compressed) / total, SystemTint.memoryCompressed),
                                                (Double(memory.cached) / total, SystemTint.memoryCached)])
                    }
                    DotMatrixChart(columns: monitor.columns(60) { s in
                                       let t = Double(max(s.memory.total, 1))
                                       return [Double(s.memory.wired) / t, Double(s.memory.compressed) / t, Double(s.memory.app) / t]
                                   },
                                   colors: [SystemTint.memoryWired, SystemTint.memoryCompressed, SystemTint.memory],
                                   axis: DotMatrixChart.axis(for: monitor.range, now: String(localized: "bây giờ")),
                                   tint: SystemTint.memory)
                        .frame(height: 200)
                }

                if let memory, let latest = monitor.latest {
                    HStack(alignment: .top, spacing: Theme.Space.m) {
                        Card(title: "Phân loại", symbol: "chart.pie", tint: SystemTint.memory) {
                            HStack(spacing: Theme.Space.l) {
                                RingGauge(segments: [(Double(memory.app) / total, SystemTint.memory),
                                                     (Double(memory.wired) / total, SystemTint.memoryWired),
                                                     (Double(memory.compressed) / total, SystemTint.memoryCompressed),
                                                     (Double(memory.cached) / total, SystemTint.memoryCached)],
                                          center: Format.percent(Double(memory.used) / total * 100), caption: "đang dùng")
                                    .frame(width: 112, height: 112)
                                VStack(spacing: 6) {
                                    TypeRow(title: "App", value: memory.app, color: SystemTint.memory)
                                    TypeRow(title: "Wired", value: memory.wired, color: SystemTint.memoryWired)
                                    TypeRow(title: "Đã nén", value: memory.compressed, color: SystemTint.memoryCompressed)
                                    TypeRow(title: "Cache", value: memory.cached, color: SystemTint.memoryCached)
                                    TypeRow(title: "Trống", value: memory.free, color: Theme.track)
                                }
                            }
                        }

                        Card(title: "Áp lực", symbol: "gauge.with.dots.needle.33percent", tint: pressureColor(memory.pressureLevel)) {
                            PressureBadge(level: memory.pressureLevel)
                        } content: {
                            HStack {
                                Spacer()
                                RingGauge(segments: [(Double(memory.pressurePercent ?? 0) / 100, pressureColor(memory.pressureLevel))],
                                          center: memory.pressurePercent.map { "\($0)%" } ?? "—", caption: "áp lực")
                                    .frame(width: 112, height: 112)
                                Spacer()
                            }
                            InfoRow("Đọc trang vào", String(localized: "\(Format.number(latest.pageinsPerSecond, digits: 0))/giây"))
                            InfoRow("Đẩy ra swap", String(localized: "\(Format.number(latest.swapoutsPerSecond, digits: 0))/giây"))
                        }

                        Card(title: "Swap", symbol: "externaldrive", tint: .indigo) {
                            let swap = Format.bytesParts(memory.swapUsed)
                            BigValue(caption: "Đã ghi ra ổ đĩa", value: swap.value, unit: swap.unit)
                            MeterBar(value: memory.swapTotal > 0 ? Double(memory.swapUsed) / Double(memory.swapTotal) : 0, tint: .indigo)
                            InfoRow("Dung lượng swap", Format.bytes(memory.swapTotal))
                            InfoRow("Đã nén trong RAM", Format.bytes(memory.compressed))
                        }
                    }
                    .frame(minHeight: 220)
                }

                Footnote("App: bộ nhớ các ứng dụng đang dùng. Wired: hệ thống giữ cố định. Đã nén: macOS nén bớt để có chỗ trống. Cache: file vừa dùng, giải phóng được ngay khi cần. Áp lực cao kéo dài nghĩa là máy thiếu RAM.")
            }
        }
        .toolbar { SystemToolbar(monitor: monitor) }
    }
}

func pressureColor(_ level: Int) -> Color {
    switch level {
    case 4...: .red
    case 2...: .orange
    default: .green
    }
}

/// "Bình thường" / "Cao" / "Nghiêm trọng".
struct PressureBadge: View {
    let level: Int

    var body: some View {
        let color = pressureColor(level)
        Group {
            switch level {
            case 4...: Label("Nghiêm trọng", systemImage: "exclamationmark.octagon.fill")
            case 2...: Label("Cao", systemImage: "exclamationmark.triangle.fill")
            default: Label("Bình thường", systemImage: "checkmark")
            }
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.15), in: Capsule())
    }
}

private struct TypeRow: View {
    let title: LocalizedStringKey
    let value: UInt64
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(.callout)
            Spacer()
            Text(verbatim: Format.bytes(value)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

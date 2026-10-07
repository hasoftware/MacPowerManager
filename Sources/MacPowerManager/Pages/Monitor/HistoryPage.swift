import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

struct HistoryPage: View {
    @Environment(AppModel.self) private var model
    @AppStorage("ui.history.range") private var range: Range = .day
    @State private var confirmClear = false

    enum Range: String, CaseIterable, Identifiable {
        case hour, hours6, day, week
        var id: Self { self }
        var title: LocalizedStringKey {
            switch self {
            case .hour: "1 giờ"
            case .hours6: "6 giờ"
            case .day: "24 giờ"
            case .week: "7 ngày"
            }
        }
        var seconds: TimeInterval {
            switch self {
            case .hour: 3600
            case .hours6: 6 * 3600
            case .day: 24 * 3600
            case .week: 7 * 24 * 3600
            }
        }
    }

    var body: some View {
        let samples = model.history.samples(within: range.seconds)
        MonitorPage { _ in
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack {
                    Picker("Khoảng thời gian", selection: $range) {
                        ForEach(Range.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 320)
                    Spacer()
                    Button {
                        exportCSV()
                    } label: {
                        Label("Xuất CSV", systemImage: "square.and.arrow.up")
                    }
                    .disabled(samples.isEmpty)
                    Button(role: .destructive) {
                        confirmClear = true
                    } label: {
                        Label("Xóa lịch sử", systemImage: "trash")
                    }
                    .disabled(model.history.samples.isEmpty)
                }

                if samples.count < 2 {
                    ContentUnavailableView("Chưa có dữ liệu", systemImage: "chart.xyaxis.line",
                                           description: Text("Lịch sử sẽ xuất hiện sau vài phút. App ghi lại trạng thái pin mỗi phút khi đang chạy."))
                        .frame(maxWidth: .infinity, minHeight: 320)
                        .cardSurface()
                } else {
                    Card(title: "Mức pin", symbol: "battery.75percent", tint: .green) {
                        BatteryLevelChart(samples: samples, limit: model.summary.limit, tint: .green, range: range.seconds)
                    }
                    .frame(height: 260)

                    Card(title: "Công suất pin (W, dương = đang nạp)", symbol: "bolt.fill", tint: .green) {
                        SignedPowerChart(samples: samples, range: range.seconds)
                    }
                    .frame(height: 200)

                    Card(title: "Nhiệt độ pin (°C)", symbol: "thermometer.medium", tint: .orange) {
                        TemperatureChart(samples: samples, range: range.seconds,
                                         pause: model.activeConfig.flatMap { $0.thermalProtectionEnabled ? $0.thermalPauseAbove : nil },
                                         resume: model.activeConfig.flatMap { $0.thermalProtectionEnabled ? $0.thermalResumeBelow : nil })
                    }
                    .frame(height: 200)

                    Footnote("Mẫu được ghi mỗi phút khi app đang chạy và giữ trong 7 ngày. Khoảng trống là lúc máy ngủ hoặc app tắt.")
                }
            }
        }
        .confirmationDialog("Xóa toàn bộ lịch sử pin?", isPresented: $confirmClear) {
            Button("Xóa", role: .destructive) { model.history.clear() }
        } message: {
            Text("Không thể hoàn tác.")
        }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "MacPowerManager-history.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? model.history.csv(within: range.seconds).write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct SignedPowerChart: View {
    let samples: [HistorySample]
    let range: TimeInterval

    var body: some View {
        let points = samples.points { $0.batteryPower }
        // Vùng xanh phía trên 0 (đang nạp), cam phía dưới (pin đang cấp điện), mỗi đoạn liên tục một chuỗi riêng.
        Chart {
            ForEach(points) { p in
                AreaMark(x: .value("Thời gian", p.date), yStart: .value("0", 0), yEnd: .value("W", max(p.value, 0)),
                         series: .value("đoạn", "+\(p.segment)"))
                    .foregroundStyle(Color.green.opacity(0.45))
                AreaMark(x: .value("Thời gian", p.date), yStart: .value("0", min(p.value, 0)), yEnd: .value("W", 0),
                         series: .value("đoạn", "-\(p.segment)"))
                    .foregroundStyle(Color.orange.opacity(0.45))
                LineMark(x: .value("Thời gian", p.date), y: .value("W", p.value), series: .value("đoạn", "l\(p.segment)"))
                    .foregroundStyle(Color.secondary.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
            RuleMark(y: .value("0", 0))
                .foregroundStyle(Color.secondary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 0.5))
        }
        .chartXScale(domain: Date().addingTimeInterval(-range)...Date())
        .chartXAxis { ChartAxis.timeMarks(range: range) }
        .chartYAxis { AxisMarks(position: .trailing) }
        .environment(\.locale, Format.locale)
    }
}

private struct TemperatureChart: View {
    let samples: [HistorySample]
    let range: TimeInterval
    var pause: Double?
    var resume: Double?

    var body: some View {
        let points = samples.points { $0.temperature }
        Chart {
            ForEach(points) { p in
                LineMark(x: .value("Thời gian", p.date), y: .value("°C", p.value), series: .value("đoạn", p.segment))
                    .foregroundStyle(.orange)
                    .interpolationMethod(.monotone)
            }
            if let pause {
                RuleMark(y: .value("Dừng sạc", pause))
                    .foregroundStyle(.red.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("Dừng sạc \(Int(pause))°C").font(.caption2).foregroundStyle(.secondary)
                    }
            }
            if let resume {
                RuleMark(y: .value("Sạc lại", resume))
                    .foregroundStyle(.blue.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .bottom, alignment: .trailing) {
                        Text("Sạc lại \(Int(resume))°C").font(.caption2).foregroundStyle(.secondary)
                    }
            }
        }
        .chartXScale(domain: Date().addingTimeInterval(-range)...Date())
        .chartXAxis { ChartAxis.timeMarks(range: range) }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartYAxis { AxisMarks(position: .trailing) }
        .environment(\.locale, Format.locale)
    }
}

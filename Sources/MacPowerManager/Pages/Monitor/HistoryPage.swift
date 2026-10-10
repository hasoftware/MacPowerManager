import PowerCore
import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

struct HistoryPage: View {
    @Environment(AppModel.self) private var model
    @AppStorage("ui.history.range") private var storedRange: Range = .day
    /// Khoảng cố định (chụp giao diện), không đọc/ghi lựa chọn đã lưu.
    var fixedRange: Range?
    @State private var confirmClear = false

    enum Range: String, CaseIterable, Identifiable {
        case hour, hours6, day, week, month
        var id: Self { self }
        var title: LocalizedStringKey {
            switch self {
            case .hour: "1 giờ"
            case .hours6: "6 giờ"
            case .day: "24 giờ"
            case .week: "7 ngày"
            case .month: "30 ngày"
            }
        }
        var seconds: TimeInterval {
            switch self {
            case .hour: 3600
            case .hours6: 6 * 3600
            case .day: 24 * 3600
            case .week: 7 * 24 * 3600
            case .month: 30 * 24 * 3600
            }
        }
    }

    private var range: Range { fixedRange ?? storedRange }

    var body: some View {
        let samples = model.history.samples(within: range.seconds)
        MonitorPage { _ in
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack {
                    Picker("Khoảng thời gian", selection: Binding(get: { range }, set: { storedRange = $0 })) {
                        ForEach(Range.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 400)
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
                    let level = samples.series { Double($0.percent) }
                    if level.hasBridges {
                        ChartGapLegend(showsBand: !level.gaps.isEmpty)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }

                    Card(title: "Mức pin", symbol: "battery.75percent", tint: .green) {
                        BatteryLevelChart(samples: samples, limit: model.summary.limit, tint: .green, range: range.seconds)
                    }
                    .frame(height: 260)

                    Card(title: "Công suất pin (W, dương = đang nạp)", symbol: "bolt.fill", tint: .green) {
                        SignedPowerChart(samples: samples, range: range.seconds)
                    }
                    .frame(height: 200)

                    Card(title: "Hệ thống tiêu thụ (W)", symbol: "laptopcomputer", tint: .blue) {
                        SystemLoadChart(samples: samples, range: range.seconds)
                    }
                    .frame(height: 200)

                    Card(title: "Nhiệt độ pin (°C)", symbol: "thermometer.medium", tint: .orange) {
                        TemperatureChart(samples: samples, range: range.seconds,
                                         pause: model.activeConfig.flatMap { $0.thermalProtectionEnabled ? $0.thermalPauseAbove : nil },
                                         resume: model.activeConfig.flatMap { $0.thermalProtectionEnabled ? $0.thermalResumeBelow : nil })
                    }
                    .frame(height: 200)

                    Footnote("Helper ghi một mẫu mỗi phút, kể cả khi app đã tắt; khi chưa cài helper, app tự ghi lúc đang chạy. Lịch sử được giữ 30 ngày. Nét đứt nối qua lúc máy ngủ hoặc tắt; khi xem nhiều ngày, mỗi điểm là trung bình của một khoảng thời gian.")
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
        // Vùng xanh phía trên 0 (đang nạp), cam phía dưới (pin đang cấp điện).
        HistoryChart(series: samples.series { $0.batteryPower }, tint: .green, fill: .signed,
                     lineColor: .secondary.opacity(0.8), lineWidth: 1, range: range, includesZero: true) {
            Format.watts($0, signed: true)
        }
    }
}

private struct SystemLoadChart: View {
    let samples: [HistorySample]
    let range: TimeInterval

    var body: some View {
        HistoryChart(series: samples.series { $0.systemLoad }, tint: .blue, fill: .gradient(baseline: 0),
                     lineWidth: 1.5, range: range, includesZero: true) { Format.watts($0) }
    }
}

private struct TemperatureChart: View {
    let samples: [HistorySample]
    let range: TimeInterval
    var pause: Double?
    var resume: Double?

    var body: some View {
        var thresholds: [ChartThreshold] = []
        if let pause {
            thresholds.append(ChartThreshold(value: pause, label: String(localized: "Dừng sạc \(Int(pause))°C"),
                                             color: .red.opacity(0.6)))
        }
        if let resume {
            thresholds.append(ChartThreshold(value: resume, label: String(localized: "Sạc lại \(Int(resume))°C"),
                                             color: .blue.opacity(0.5), above: false))
        }
        return HistoryChart(series: samples.series { $0.temperature }, tint: .orange, range: range,
                            thresholds: thresholds) { Format.temperature($0) }
    }
}

import Charts
import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var range: Range = .day

    enum Range: String, CaseIterable, Identifiable {
        case hours6 = "6 giờ", day = "24 giờ", week = "7 ngày"
        var id: Self { self }
        var seconds: TimeInterval {
            switch self {
            case .hours6: 6 * 3600
            case .day: 24 * 3600
            case .week: 7 * 24 * 3600
            }
        }
    }

    var body: some View {
        let samples = model.history.samples(within: range.seconds)
        VStack(alignment: .leading, spacing: 16) {
            Picker("Khoảng thời gian", selection: $range) {
                ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 300)

            if samples.count < 2 {
                ContentUnavailableView("Chưa đủ dữ liệu", systemImage: "chart.xyaxis.line",
                                       description: Text("App ghi lại trạng thái pin mỗi phút khi đang chạy."))
            } else {
                ChartSection(title: "Mức pin (%)") {
                    Chart(samples) { s in
                        AreaMark(x: .value("Thời gian", s.date), y: .value("%", s.percent))
                            .foregroundStyle(.green.opacity(0.15))
                        LineMark(x: .value("Thời gian", s.date), y: .value("%", s.percent))
                            .foregroundStyle(.green)
                        if let config = model.activeConfig, config.chargeLimitEnabled {
                            RuleMark(y: .value("Giới hạn", config.chargeLimit))
                                .foregroundStyle(.secondary)
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        }
                    }
                    .chartYScale(domain: 0...100)
                }

                ChartSection(title: "Nhiệt độ pin (°C)") {
                    Chart(samples.filter { $0.temperature != nil }) { s in
                        LineMark(x: .value("Thời gian", s.date), y: .value("°C", s.temperature ?? 0))
                            .foregroundStyle(.orange)
                        if let config = model.activeConfig, config.thermalProtectionEnabled {
                            RuleMark(y: .value("Ngưỡng", config.thermalPauseAbove))
                                .foregroundStyle(.red.opacity(0.6))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        }
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                }

                ChartSection(title: "Công suất pin (W, dương = đang sạc)") {
                    Chart(samples) { s in
                        BarMark(x: .value("Thời gian", s.date), y: .value("W", s.batteryPower))
                            .foregroundStyle(s.batteryPower >= 0 ? .blue : .purple)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct ChartSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content.frame(minHeight: 110)
        }
    }
}

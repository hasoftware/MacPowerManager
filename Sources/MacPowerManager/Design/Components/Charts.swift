import PowerCore
import Charts
import SwiftUI

/// Cách tô vùng dưới đường.
enum ChartFill: Equatable {
    case none
    /// Dải màu nhạt dần từ đường xuống mốc `baseline`.
    case gradient(baseline: Double)
    /// Xanh phần dương (đang nạp), cam phần âm (pin đang cấp điện) quanh mốc 0.
    case signed
}

enum ChartStyle {
    /// Nền rất nhạt cho khoảng không có dữ liệu.
    static let gapFill = Color.primary.opacity(0.045)
    static let gapFillSelected = Color.primary.opacity(0.09)
    /// Nhạt hơn nữa trong biểu đồ nhỏ (vùng nền chiếm tỉ lệ lớn).
    static let gapFillSparkline = Color.primary.opacity(0.03)
    static let bridgeDash: [CGFloat] = [3, 3]
}

/// Đường liên tục: nét liền ở các đoạn có dữ liệu (kèm vùng tô), nét đứt mờ nối qua khoảng trống (không tô),
/// nền nhạt ở khoảng trống dài (máy ngủ hoặc tắt).
struct ContinuousMarks: ChartContent {
    let series: ChartSeries
    var tint: Color
    var fill: ChartFill = .none
    var lineColor: Color?
    var lineWidth: CGFloat = 2
    var areaOpacity: Double = 0.28
    var gapFill: Color = ChartStyle.gapFill

    var body: some ChartContent {
        let line = lineColor ?? tint
        ForEach(series.gaps) { gap in
            RectangleMark(xStart: .value("Thời gian", gap.start), xEnd: .value("Thời gian", gap.end))
                .foregroundStyle(gapFill)
        }
        ForEach(series.points) { p in
            if fill == .signed {
                AreaMark(x: .value("Thời gian", p.date), yStart: .value("0", 0), yEnd: .value("Giá trị", max(p.value, 0)),
                         series: .value("đoạn", "+\(p.run)"))
                    .foregroundStyle(Color.green.opacity(areaOpacity))
                AreaMark(x: .value("Thời gian", p.date), yStart: .value("0", min(p.value, 0)), yEnd: .value("Giá trị", 0),
                         series: .value("đoạn", "-\(p.run)"))
                    .foregroundStyle(Color.orange.opacity(areaOpacity))
            } else if case .gradient(let baseline) = fill {
                AreaMark(x: .value("Thời gian", p.date), yStart: .value("0", baseline), yEnd: .value("Giá trị", p.value),
                         series: .value("đoạn", "a\(p.run)"))
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(areaOpacity), tint.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
            }
            LineMark(x: .value("Thời gian", p.date), y: .value("Giá trị", p.value), series: .value("đoạn", "l\(p.run)"))
                .foregroundStyle(line)
                .lineStyle(StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                .interpolationMethod(fill == .signed ? .linear : .monotone)
        }
        // Mỗi đoạn nối là một chuỗi hai điểm riêng để có nét đứt (kiểu nét áp dụng cho cả chuỗi).
        ForEach(series.bridges) { bridge in
            ForEach([bridge.from, bridge.to]) { p in
                LineMark(x: .value("Thời gian", p.date), y: .value("Giá trị", p.value),
                         series: .value("đoạn", "b\(bridge.to.run)"))
                    .foregroundStyle(line.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: max(lineWidth * 0.75, 1), lineCap: .round, dash: ChartStyle.bridgeDash))
            }
        }
        ForEach(series.isolated) { p in
            PointMark(x: .value("Thời gian", p.date), y: .value("Giá trị", p.value))
                .foregroundStyle(line.opacity(0.7))
                .symbolSize(lineWidth * 6)
        }
    }
}

/// Đường mốc ngang (giới hạn, ngưỡng nhiệt) có nhãn.
struct ChartThreshold: Identifiable {
    var value: Double
    var label: String?
    var color: Color
    var above = true
    var id: String { "\(value)-\(label ?? "")" }
}

/// Biểu đồ nhỏ trong thẻ số liệu. `signed`: tô xanh phần dương, cam phần âm quanh mốc 0.
struct Sparkline: View {
    let series: ChartSeries
    var tint: Color = .accentColor
    var threshold: Double?
    var signed = false
    var domain: ClosedRange<Double>?

    private var yDomain: ClosedRange<Double> {
        if let domain { return domain }
        var values = series.values
        if let threshold { values.append(threshold) }
        if signed { values.append(0) }
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        let pad = max((hi - lo) * 0.15, 0.5)
        return (lo - pad)...(hi + pad)
    }

    var body: some View {
        if series.count < 2 {
            ZStack {
                Capsule().fill(Theme.track).frame(height: 1)
                Text("Chưa đủ dữ liệu")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .background(Theme.card)
            }
        } else {
            let domain = yDomain
            Chart {
                ContinuousMarks(series: series, tint: tint, fill: signed ? .signed : .gradient(baseline: domain.lowerBound),
                                lineColor: signed ? .secondary : nil, lineWidth: 1.5, areaOpacity: signed ? 0.35 : 0.3,
                                gapFill: ChartStyle.gapFillSparkline)
                if let threshold {
                    RuleMark(y: .value("Ngưỡng", threshold))
                        .foregroundStyle(Color.orange.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                if signed {
                    RuleMark(y: .value("0", 0))
                        .foregroundStyle(Color.secondary.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 0.5))
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .chartYScale(domain: domain)
            .accessibilityHidden(true)
        }
    }
}

/// Biểu đồ lịch sử theo thời gian: đường liên tục (nét đứt qua khoảng trống), mốc ngang có nhãn, rê chuột để xem giá
/// trị hoặc khoảng không có dữ liệu.
struct HistoryChart: View {
    let series: ChartSeries
    var tint: Color
    var fill: ChartFill = .none
    var lineColor: Color?
    var lineWidth: CGFloat = 2
    var range: TimeInterval = 24 * 3600
    var thresholds: [ChartThreshold] = []
    /// Trục 0–100% (mức pin); nếu không, trục tự động.
    var percentAxis = false
    var includesZero = false
    var format: (Double) -> String

    @State private var selected: Date?

    var body: some View {
        let now = Date()
        let selection = selected.flatMap { series.selection(at: $0, snap: range * 0.015) }
        let chart = Chart {
            ContinuousMarks(series: series, tint: tint, fill: fill, lineColor: lineColor, lineWidth: lineWidth,
                            areaOpacity: fill == .signed ? 0.45 : 0.28)
            if fill == .signed {
                RuleMark(y: .value("0", 0))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 0.5))
            }
            ForEach(thresholds) { t in
                RuleMark(y: .value("Ngưỡng", t.value))
                    .foregroundStyle(t.color)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: t.above ? .top : .bottom, alignment: .trailing, spacing: 2) {
                        if let label = t.label {
                            Text(label)
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
            }
            if let selected, let selection {
                selectionMarks(selection, cursor: selected)
            }
        }
        .chartXScale(domain: now.addingTimeInterval(-range)...now)
        .chartXAxis { ChartAxis.timeMarks(range: range) }
        .chartXSelection(value: $selected)
        .environment(\.locale, Format.locale)

        if percentAxis {
            chart
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(position: .trailing, values: [0, 50, 100]) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        AxisValueLabel { if let v = value.as(Int.self) { Text(verbatim: "\(v)%") } }
                    }
                }
        } else {
            chart
                .chartYScale(domain: .automatic(includesZero: includesZero))
                .chartYAxis { AxisMarks(position: .trailing) }
        }
    }

    @ChartContentBuilder
    private func selectionMarks(_ selection: ChartSeries.Selection, cursor: Date) -> some ChartContent {
        switch selection {
        case .point(let p):
            RuleMark(x: .value("Chọn", p.date))
                .foregroundStyle(Color.secondary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1))
                .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                    ChartTooltip {
                        Text(verbatim: format(p.value)).font(.caption.weight(.semibold).monospacedDigit())
                        Text(verbatim: Format.dateTime(p.date)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            PointMark(x: .value("Chọn", p.date), y: .value("Giá trị", p.value))
                .foregroundStyle(lineColor ?? tint)
                .symbolSize(30)
        case .gap(let start, let end):
            RectangleMark(xStart: .value("Thời gian", start), xEnd: .value("Thời gian", end))
                .foregroundStyle(ChartStyle.gapFillSelected)
            RuleMark(x: .value("Chọn", cursor))
                .foregroundStyle(Color.secondary.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                    ChartTooltip {
                        Text(.noDataLabel).font(.caption.weight(.semibold))
                        Text(verbatim: "\(Format.dateTime(start)) – \(Format.dateTime(end))")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
        }
    }
}

extension LocalizedStringKey {
    /// Nhãn của khoảng không có dữ liệu (chú thích và tooltip).
    static let noDataLabel: LocalizedStringKey = "Không có dữ liệu (máy ngủ hoặc tắt)"
}

/// Khung tooltip khi rê chuột trên biểu đồ.
private struct ChartTooltip<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 1) { content }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.cardStroke))
    }
}

/// Chú thích nét đứt và vùng nền của các biểu đồ lịch sử.
struct ChartGapLegend: View {
    var showsBand = true

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            HStack(spacing: 5) {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 4))
                    path.addLine(to: CGPoint(x: 18, y: 4))
                }
                .stroke(Color.secondary.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: ChartStyle.bridgeDash))
                .frame(width: 18, height: 8)
                Text("Nét đứt: nối qua lúc không có dữ liệu")
            }
            if showsBand {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(ChartStyle.gapFillSelected)
                        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Theme.cardStroke))
                        .frame(width: 14, height: 10)
                    Text(.noDataLabel)
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }
}

/// Biểu đồ mức pin: vùng màu, đường giới hạn nét đứt có nhãn, rê chuột để xem giá trị.
struct BatteryLevelChart: View {
    let samples: [HistorySample]
    var limit: Int?
    var tint: Color = .green
    var range: TimeInterval = 24 * 3600
    /// Hiện chú thích nét đứt dưới biểu đồ khi có khoảng trống.
    var showsLegend = false

    var body: some View {
        let series = samples.series { Double($0.percent) }
        VStack(alignment: .leading, spacing: 4) {
            HistoryChart(series: series, tint: tint, fill: .gradient(baseline: 0), range: range,
                         thresholds: limit.map { [ChartThreshold(value: Double($0), label: String(localized: "Giới hạn \($0)%"),
                                                                 color: Theme.limitLine.opacity(0.7))] } ?? [],
                         percentAxis: true) { Format.percent($0) }
            if showsLegend && series.hasBridges {
                ChartGapLegend(showsBand: !series.gaps.isEmpty)
            }
        }
    }
}

/// Mốc trục thời gian: tròn giờ (hoặc tròn ngày) theo giờ địa phương, bỏ các mốc sát hai mép để nhãn không bị cắt.
enum ChartAxis {
    /// Trục thời gian dùng chung cho các biểu đồ lịch sử (giờ "15:00", hoặc thứ và ngày khi xem nhiều ngày).
    static func timeMarks(range: TimeInterval) -> some AxisContent {
        AxisMarks(values: dates(range: range)) { _ in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
            AxisValueLabel(format: range > 10 * 24 * 3600
                           ? Date.FormatStyle.dateTime.day().month(.abbreviated).locale(Format.locale)
                           : range > 2 * 24 * 3600
                           ? Date.FormatStyle.dateTime.weekday(.abbreviated).day().locale(Format.locale)
                           : Date.FormatStyle.dateTime.hour().minute().locale(Format.locale))
        }
    }

    static func dates(range: TimeInterval, now: Date = Date()) -> [Date] {
        let calendar = Calendar.current
        let start = now.addingTimeInterval(-range)
        let (component, step): (Calendar.Component, Int) = switch range {
        case ...3600: (.minute, 10)
        case ...(6 * 3600): (.hour, 1)
        case ...(24 * 3600): (.hour, 3)
        case ...(10 * 24 * 3600): (.day, 1)
        default: (.day, 5)
        }
        // Nhãn ngày ("Th 7, 10") rộng hơn nhãn giờ nên cần lề lớn hơn.
        let margin = range * (component == .day ? 0.08 : 0.05)
        // Mốc đầu tiên: tròn theo đơn vị ngay sau `start`.
        var date: Date
        switch component {
        case .day: date = calendar.startOfDay(for: start)
        case .hour: date = calendar.dateInterval(of: .hour, for: start)?.start ?? start
        default: date = calendar.dateInterval(of: .hour, for: start)?.start ?? start
        }
        var result: [Date] = []
        while date <= now {
            let value = calendar.component(component, from: date)
            if date > start.addingTimeInterval(margin) && date < now.addingTimeInterval(-margin) && value % step == 0 {
                result.append(date)
            }
            guard let next = calendar.date(byAdding: component, value: 1, to: date) else { break }
            date = next
        }
        return result
    }
}

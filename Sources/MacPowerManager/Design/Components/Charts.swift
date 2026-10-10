import PowerCore
import Charts
import SwiftUI

/// Biểu đồ nhỏ trong thẻ số liệu. `signed`: tô xanh phần dương, cam phần âm quanh mốc 0.
struct Sparkline: View {
    let points: [ChartPoint]
    var tint: Color = .accentColor
    var threshold: Double?
    var signed = false
    var domain: ClosedRange<Double>?

    private var yDomain: ClosedRange<Double> {
        if let domain { return domain }
        var values = points.map(\.value)
        if let threshold { values.append(threshold) }
        if signed { values.append(0) }
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        let pad = max((hi - lo) * 0.15, 0.5)
        return (lo - pad)...(hi + pad)
    }

    var body: some View {
        if points.count < 2 {
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
                ForEach(points) { p in
                    if signed {
                        AreaMark(x: .value("Thời gian", p.date), yStart: .value("0", 0), yEnd: .value("Giá trị", max(p.value, 0)),
                                 series: .value("đoạn", "+\(p.segment)"))
                            .foregroundStyle(Color.green.opacity(0.35))
                        AreaMark(x: .value("Thời gian", p.date), yStart: .value("0", min(p.value, 0)), yEnd: .value("Giá trị", 0),
                                 series: .value("đoạn", "-\(p.segment)"))
                            .foregroundStyle(Color.orange.opacity(0.35))
                    } else {
                        AreaMark(x: .value("Thời gian", p.date), yStart: .value("Giá trị", domain.lowerBound), yEnd: .value("Giá trị", p.value),
                                 series: .value("đoạn", p.segment))
                            .foregroundStyle(LinearGradient(colors: [tint.opacity(0.3), tint.opacity(0)],
                                                            startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                    }
                    LineMark(x: .value("Thời gian", p.date), y: .value("Giá trị", p.value), series: .value("đoạn", p.segment))
                        .foregroundStyle(signed ? Color.secondary : tint)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
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

/// Biểu đồ mức pin: vùng màu, đường giới hạn nét đứt có nhãn, rê chuột để xem giá trị.
struct BatteryLevelChart: View {
    let samples: [HistorySample]
    var limit: Int?
    var tint: Color = .green
    var range: TimeInterval = 24 * 3600

    @State private var selected: Date?

    var body: some View {
        let points = samples.points { Double($0.percent) }
        let selectedPoint = selected.flatMap { date in points.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }) }
        Chart {
            ForEach(points) { p in
                AreaMark(x: .value("Thời gian", p.date), yStart: .value("0", 0), yEnd: .value("%", p.value),
                         series: .value("đoạn", p.segment))
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Thời gian", p.date), y: .value("%", p.value), series: .value("đoạn", p.segment))
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if let limit {
                RuleMark(y: .value("Giới hạn", limit))
                    .foregroundStyle(Theme.limitLine.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .trailing, spacing: 2) {
                        Text("Giới hạn \(limit)%")
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
            }
            if let p = selectedPoint {
                RuleMark(x: .value("Chọn", p.date))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(spacing: 1) {
                            Text("\(Int(p.value.rounded()))%").font(.caption.weight(.semibold).monospacedDigit())
                            Text(Format.dateTime(p.date)).font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.cardStroke))
                    }
                PointMark(x: .value("Chọn", p.date), y: .value("%", p.value))
                    .foregroundStyle(tint)
                    .symbolSize(30)
            }
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: Date().addingTimeInterval(-range)...Date())
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, 50, 100]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                AxisValueLabel { if let v = value.as(Int.self) { Text("\(v)%") } }
            }
        }
        .chartXAxis { ChartAxis.timeMarks(range: range) }
        .chartXSelection(value: $selected)
        .environment(\.locale, Format.locale)
    }
}

/// Mốc trục thời gian: tròn giờ (hoặc tròn ngày) theo giờ địa phương, bỏ các mốc sát hai mép để nhãn không bị cắt.
enum ChartAxis {
    /// Trục thời gian dùng chung cho các biểu đồ lịch sử (giờ "15:00", hoặc thứ và ngày khi xem nhiều ngày).
    static func timeMarks(range: TimeInterval) -> some AxisContent {
        AxisMarks(values: dates(range: range)) { _ in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
            AxisValueLabel(format: range > 2 * 24 * 3600
                           ? Date.FormatStyle.dateTime.weekday(.abbreviated).day().locale(Format.locale)
                           : Date.FormatStyle.dateTime.hour().minute().locale(Format.locale))
        }
    }

    static func dates(range: TimeInterval, now: Date = Date()) -> [Date] {
        let calendar = Calendar.current
        let start = now.addingTimeInterval(-range)
        let margin = range * 0.05
        let (component, step): (Calendar.Component, Int) = switch range {
        case ...3600: (.minute, 10)
        case ...(6 * 3600): (.hour, 1)
        case ...(24 * 3600): (.hour, 3)
        default: (.day, 1)
        }
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

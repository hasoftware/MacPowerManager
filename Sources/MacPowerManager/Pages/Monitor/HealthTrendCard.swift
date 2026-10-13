import Charts
import PowerCore
import SwiftUI

/// Sức khỏe pin theo thời gian: biểu đồ nhiều tháng, tốc độ chai và ước tính khi nào xuống 80%.
struct HealthTrendCard: View {
    let points: [HealthPoint]
    let trend: HealthTrend?

    var body: some View {
        let series = HealthLog.series(points)
        Card(title: "Sức khỏe theo thời gian", symbol: "chart.line.downtrend.xyaxis", tint: .pink) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if series.count >= 2 {
                    chart(series)
                        .frame(height: 150)
                }
                if let trend {
                    HStack(alignment: .top, spacing: Theme.Space.l) {
                        stat("Mỗi năm", Self.change(trend.changePerYear))
                        stat("Còn trên 80%", Self.remaining(trend))
                        stat("Sạc mỗi tháng", trend.cyclesPerMonth.map { String(localized: "\(Format.number($0, digits: 0)) lần") } ?? "—")
                    }
                    Text("Ước tính theo xu hướng \(Format.integer(Int(trend.spanDays))) ngày qua; con số thực tế còn tùy cách dùng và nhiệt độ.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Đang thu thập dữ liệu: app ghi mỗi ngày một điểm. Sau khoảng \(Int(HealthLog.minimumTrendDays)) ngày sẽ có ước tính tốc độ chai pin và thời điểm pin xuống dưới 80%.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func chart(_ series: [(day: Date, percent: Double)]) -> some View {
        let low = series.map(\.percent).min() ?? 80
        let lower = max(min(floor(low) - 2, HealthLog.serviceThreshold - 2), 0)
        return Chart {
            ForEach(series, id: \.day) { point in
                AreaMark(x: .value("Ngày", point.day), yStart: .value("", lower), yEnd: .value("%", point.percent))
                    .foregroundStyle(.linearGradient(colors: [.pink.opacity(0.28), .pink.opacity(0.02)],
                                                     startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.stepEnd)
                LineMark(x: .value("Ngày", point.day), y: .value("%", point.percent))
                    .foregroundStyle(.pink)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.stepEnd)
            }
            RuleMark(y: .value("", HealthLog.serviceThreshold))
                .foregroundStyle(Theme.limitLine.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .annotation(position: .top, alignment: .leading) {
                    Text(verbatim: Format.percent(HealthLog.serviceThreshold))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
        }
        .chartYScale(domain: lower...100)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                AxisValueLabel { if let v = value.as(Double.self) { Text(verbatim: Format.percent(v)) } }
            }
        }
        .chartXAxis {
            AxisMarks(values: Self.monthMarks(from: series.first?.day, to: series.last?.day)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                AxisValueLabel(format: Date.FormatStyle.dateTime.month(.abbreviated).year(.twoDigits).locale(Format.locale))
            }
        }
    }

    /// Mốc đầu tháng, tối đa khoảng 6 mốc, bỏ các mốc sát hai mép để nhãn không bị cắt.
    static func monthMarks(from start: Date?, to end: Date?, calendar: Calendar = .current) -> [Date] {
        guard let start, let end, end > start else { return [] }
        let span = end.timeIntervalSince(start)
        let months = max(Int(span / (30.44 * 86_400)), 1)
        let step = max(Int((Double(months) / 6).rounded(.up)), 1)
        let margin = span * 0.07
        guard var date = calendar.dateInterval(of: .month, for: start)?.end else { return [] }
        var result: [Date] = []
        while date < end.addingTimeInterval(-margin) {
            if date > start.addingTimeInterval(margin), calendar.component(.month, from: date) % step == 0 {
                result.append(date)
            }
            guard let next = calendar.date(byAdding: .month, value: 1, to: date) else { break }
            date = next
        }
        return result
    }

    private func stat(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: value).font(.title3.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "−1,2%" hoặc "+0,1%" (điểm phần trăm mỗi năm).
    static func change(_ perYear: Double) -> String {
        let value = Format.number(abs(perYear), digits: 1)
        return perYear < 0 ? "−\(value)%" : "+\(value)%"
    }

    /// Thời gian còn lại tới khi xuống dưới 80%.
    static func remaining(_ trend: HealthTrend) -> String {
        if trend.current <= HealthLog.serviceThreshold { return String(localized: "Đã dưới 80%") }
        guard let days = trend.daysUntilThreshold else { return String(localized: "Chưa thấy giảm") }
        let months = Int((days / 30.44).rounded())
        if months >= 120 { return String(localized: "Hơn 10 năm") }
        if months < 1 { return String(localized: "Dưới 1 tháng") }
        let years = months / 12, rest = months % 12
        if years == 0 { return String(localized: "~\(rest) tháng") }
        if rest == 0 { return String(localized: "~\(years) năm") }
        return String(localized: "~\(years) năm \(rest) tháng")
    }
}

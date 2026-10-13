import PowerCore
import SwiftUI

/// Màu của các nhóm số liệu hệ thống (dùng chung cho thanh bên, thẻ và biểu đồ).
enum SystemTint {
    static let cpu = Color.blue
    static let cpuSystem = Color.red
    static let memory = Color.green
    static let memoryWired = Color.orange
    static let memoryCompressed = Color.cyan
    static let memoryCached = Color.gray
    static let energy = Color.yellow
    static let gpu = Color.pink
    static let disk = Color.orange
    static let diskRead = Color.cyan
    static let diskWrite = Color.orange
    static let network = Color.teal
    static let networkUp = Color.blue
}

/// Một chỉ số nhỏ: nhãn ở trên, giá trị đậm ở dưới, có thể kèm ghi chú.
struct SystemStat: View {
    let title: LocalizedStringKey
    let value: String
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(verbatim: value).font(.headline.monospacedDigit())
            if let note {
                Text(verbatim: note).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Số lớn với đơn vị nhỏ phía sau ("59 %", "27,4 GB").
struct BigValue: View {
    let caption: LocalizedStringKey
    let value: String
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(caption).font(.callout).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: value).font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                Text(verbatim: unit).font(.title3.weight(.medium)).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// Chú giải màu: "● User  ● System".
struct ColorLegend: View {
    let items: [(LocalizedStringKey, Color)]

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 4) {
                    Circle().fill(item.1).frame(width: 7, height: 7)
                    Text(item.0)
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

/// Thanh ngang mảnh có màu (dùng cho từng nhân CPU, mức dùng…).
struct MeterBar: View {
    let value: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.18))
                Capsule().fill(tint).frame(width: geo.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 6)
    }
}

/// Thanh nhiều đoạn (bộ nhớ: App, Wired, Compressed, Cached, phần còn lại là trống).
struct SegmentedBar: View {
    let segments: [(Double, Color)]

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    Capsule().fill(segment.1).frame(width: max(geo.size.width * min(max(segment.0, 0), 1) - 2, 0))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Capsule().fill(Theme.track))
        }
        .frame(height: 8)
    }
}

/// Vòng tròn tỉ lệ có chữ ở giữa (áp lực bộ nhớ, phân loại bộ nhớ).
struct RingGauge: View {
    let segments: [(Double, Color)]
    let center: String
    let caption: LocalizedStringKey
    var lineWidth: CGFloat = 12

    var body: some View {
        ZStack {
            Circle().stroke(Theme.track, lineWidth: lineWidth)
            ForEach(Array(starts.enumerated()), id: \.offset) { index, start in
                Circle()
                    .trim(from: start, to: start + max(segments[index].0 - 0.004, 0))
                    .stroke(segments[index].1, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 0) {
                Text(verbatim: center).font(.title2.weight(.semibold).monospacedDigit())
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var starts: [Double] {
        var result: [Double] = []
        var sum = 0.0
        for segment in segments {
            result.append(sum)
            sum += min(max(segment.0, 0), 1)
        }
        return result
    }
}

/// Nút chọn khoảng thời gian (1m/5m/15m/1h) và tạm dừng, đặt trên thanh công cụ của các trang Hệ thống.
struct SystemToolbar: ToolbarContent {
    @Bindable var monitor: SystemMonitor

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Khoảng thời gian", selection: $monitor.range) {
                ForEach(SystemMonitor.Range.allCases) { Text(verbatim: $0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Button {
                monitor.paused.toggle()
            } label: {
                Label(monitor.paused ? "Tiếp tục" : "Tạm dừng", systemImage: monitor.paused ? "play.fill" : "pause.fill")
            }
            .help(monitor.paused ? "Tiếp tục cập nhật" : "Tạm dừng cập nhật")
        }
    }
}

extension Format {
    /// "59" cho 0,59 (phần trăm không có ký hiệu).
    static func percentNumber(_ fraction: Double, digits: Int = 0) -> String {
        number(fraction * 100, digits: digits)
    }

    /// "2,39 MB/s" (tốc độ đọc/ghi, mạng; theo hệ thập phân như Finder).
    static func rate(_ bytesPerSecond: Double) -> String {
        let parts = rateParts(bytesPerSecond)
        return "\(parts.value) \(parts.unit)"
    }

    static func rateParts(_ bytesPerSecond: Double) -> (value: String, unit: String) {
        let text = Int64(max(bytesPerSecond, 0).rounded()).formatted(.byteCount(style: .decimal).locale(locale))
        guard let space = text.lastIndex(where: { $0 == " " || $0 == "\u{00A0}" }) else { return (text, "/s") }
        return (String(text[..<space]), String(text[text.index(after: space)...]) + "/s")
    }

    /// "1 ngày 4 giờ", "3 giờ 12 phút".
    static func uptime(since boot: Date?, now: Date = Date()) -> String {
        guard let boot else { return "—" }
        let minutes = max(Int(now.timeIntervalSince(boot) / 60), 0)
        let days = minutes / 1440, hours = minutes % 1440 / 60
        if days > 0 { return String(localized: "\(days) ngày \(hours) giờ") }
        return duration(minutes: minutes)
    }
}

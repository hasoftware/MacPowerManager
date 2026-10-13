import SwiftUI

/// Biểu đồ dạng lưới chấm: mỗi cột là một khoảng thời gian, các chấm sáng từ dưới lên theo giá trị, nhiều tầng màu
/// xếp chồng (ví dụ System ở dưới, User ở trên). Chấm chưa sáng hiện mờ để thấy khung lưới.
struct DotMatrixChart: View {
    /// Mỗi cột: các tầng (0…1) theo thứ tự `colors`; nil = chưa có dữ liệu.
    let columns: [[Double]?]
    let colors: [Color]
    var rows = 12
    /// Nhãn trục thời gian (trái → phải), ví dụ ["−1m", "−45s", …, "now"].
    var axis: [String] = []
    var tint: Color = .accentColor

    var body: some View {
        VStack(spacing: 6) {
            Canvas { context, size in
                guard !columns.isEmpty else { return }
                let stepX = size.width / CGFloat(columns.count)
                let stepY = size.height / CGFloat(rows)
                let dot = max(min(stepX, stepY) * 0.56, 1.5)
                for (x, column) in columns.enumerated() {
                    // Tầng i chiếm các chấm từ tổng các tầng trước tới tổng gồm cả nó.
                    var bounds: [Int] = []
                    var sum = 0.0
                    for value in column ?? [] {
                        sum += max(value, 0)
                        bounds.append(Int((min(sum, 1) * Double(rows)).rounded()))
                    }
                    for row in 0..<rows {
                        let color = bounds.firstIndex { row < $0 }.map { colors[min($0, colors.count - 1)] }
                        let center = CGPoint(x: stepX * (CGFloat(x) + 0.5), y: size.height - stepY * (CGFloat(row) + 0.5))
                        let rect = CGRect(x: center.x - dot / 2, y: center.y - dot / 2, width: dot, height: dot)
                        context.fill(Path(ellipseIn: rect), with: .color(color ?? tint.opacity(0.16)))
                    }
                }
            }
            if !axis.isEmpty {
                HStack {
                    ForEach(Array(axis.enumerated()), id: \.offset) { index, label in
                        Text(verbatim: label)
                        if index < axis.count - 1 { Spacer() }
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
    }

    /// Nhãn trục cho khoảng thời gian: 5 mốc cách đều tới "now".
    static func axis(for range: SystemMonitor.Range, now: String) -> [String] {
        let seconds = Int(range.seconds)
        return (0...4).map { i in
            let ago = seconds - seconds * i / 4
            if ago == 0 { return now }
            if ago < 60 { return "−\(ago)s" }
            return ago % 60 == 0 ? "−\(ago / 60)m" : "−\(ago / 60)m\(ago % 60)s"
        }
    }
}

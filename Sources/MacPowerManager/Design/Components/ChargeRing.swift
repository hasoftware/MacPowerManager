import SwiftUI

/// Vòng % pin: cung theo màu trạng thái, khoảng giữ pin mờ, vạch giới hạn (motif "limit line").
struct ChargeRing<Center: View>: View {
    var percent: Int
    var limit: Int?
    var sailingFloor: Int?
    var tint: Color
    var lineWidth: CGFloat = 10
    @ViewBuilder var center: Center

    private func fraction(_ value: Int) -> CGFloat { CGFloat(min(max(value, 0), 100)) / 100 }

    var body: some View {
        ZStack {
            Circle().stroke(Theme.track, lineWidth: lineWidth)
            if let limit, let floor = sailingFloor, floor < limit {
                Circle()
                    .trim(from: fraction(floor), to: fraction(limit))
                    .stroke(tint.opacity(0.25), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            Circle()
                .trim(from: 0, to: max(fraction(percent), 0.005))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .motion(.easeInOut(duration: 0.6), value: percent)
            if let limit {
                LimitTick(limit: limit, lineWidth: lineWidth)
                    .motion(.easeInOut(duration: 0.6), value: limit)
            }
            center
        }
        .padding(lineWidth / 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Pin \(percent)%"))
    }
}

extension ChargeRing where Center == EmptyView {
    init(percent: Int, limit: Int?, sailingFloor: Int?, tint: Color, lineWidth: CGFloat = 10) {
        self.init(percent: percent, limit: limit, sailingFloor: sailingFloor, tint: tint, lineWidth: lineWidth) {
            EmptyView()
        }
    }
}

/// Vạch giới hạn cắt ngang vòng, nhô ra hai phía.
private struct LimitTick: View {
    let limit: Int
    let lineWidth: CGFloat

    var body: some View {
        GeometryReader { geo in
            let radius = min(geo.size.width, geo.size.height) / 2
            let width = max(2, lineWidth / 4)
            Capsule()
                .fill(Theme.limitLine)
                .frame(width: width, height: lineWidth + max(6, lineWidth * 0.8))
                .shadow(color: .black.opacity(0.25), radius: 0.5)
                .position(x: geo.size.width / 2, y: geo.size.height / 2 - radius)
                .rotationEffect(.degrees(Double(limit) * 3.6))
        }
    }
}

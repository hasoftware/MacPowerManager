import SwiftUI

/// Thang nhiệt độ 25–55°C: hai núm "Sạc lại ≤" và "Dừng sạc ≥", chấm nhiệt độ hiện tại.
/// Kéo núm để đổi; chỉ gửi giá trị khi thả tay (giống `LimitBar`).
struct ThermalScale: View {
    var pause: Double
    var resume: Double
    var current: Double?
    var range: ClosedRange<Double> = 25...55
    var onCommit: (_ pause: Double, _ resume: Double) -> Void

    private enum Thumb { case pause, resume }

    @State private var dragging: Thumb?
    @State private var dragValue: Double?
    @Environment(\.isEnabled) private var isEnabled

    private let trackHeight: CGFloat = 8
    private let labelHeight: CGFloat = 18

    private var shownPause: Double { dragging == .pause ? dragValue ?? pause : pause }
    private var shownResume: Double { dragging == .resume ? dragValue ?? resume : resume }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in scale(width: geo.size.width) }
                .frame(height: labelHeight * 2 + trackHeight + 16)
            GeometryReader { geo in ticks(width: geo.size.width) }
                .frame(height: 12)
        }
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Dừng sạc khi pin từ \(Int(pause))°C, sạc lại khi từ \(Int(resume))°C trở xuống"))
    }

    private func x(_ value: Double, _ width: CGFloat) -> CGFloat {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        return width * CGFloat((clamped - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    private func value(at location: CGFloat, _ width: CGFloat) -> Double {
        let raw = range.lowerBound + Double(location / max(width, 1)) * (range.upperBound - range.lowerBound)
        return raw.rounded()
    }

    @ViewBuilder
    private func scale(width: CGFloat) -> some View {
        let midY = labelHeight + 8 + trackHeight / 2
        let pauseX = x(shownPause, width)
        let resumeX = x(shownResume, width)
        ZStack(alignment: .topLeading) {
            Capsule()
                .fill(LinearGradient(colors: [.blue.opacity(0.35), .green.opacity(0.35), .orange.opacity(0.45), .red.opacity(0.55)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: width, height: trackHeight)
                .offset(y: midY - trackHeight / 2)

            // Vùng trễ giữa hai ngưỡng: đang nóng thì chờ nguội tới mức "sạc lại".
            Rectangle()
                .fill(.orange.opacity(0.25))
                .overlay(Rectangle().strokeBorder(.orange.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                .frame(width: max(pauseX - resumeX, 2), height: trackHeight + 6)
                .offset(x: resumeX, y: midY - (trackHeight + 6) / 2)

            thumb(color: .blue).offset(x: resumeX - 3.5, y: midY - 11)
            thumb(color: .orange).offset(x: pauseX - 3.5, y: midY - 11)

            label(String(localized: "Sạc lại ≤ \(Int(shownResume))°C"), color: .blue)
                .position(x: min(max(resumeX, 52), width - 52), y: midY + trackHeight / 2 + 6 + labelHeight / 2)
            label(String(localized: "Dừng ≥ \(Int(shownPause))°C"), color: .orange)
                .position(x: min(max(pauseX, 48), width - 48), y: labelHeight / 2)

            if let current {
                let cx = x(current, width)
                Circle()
                    .fill(Color.primary)
                    .overlay(Circle().strokeBorder(Theme.card, lineWidth: 2))
                    .frame(width: 12, height: 12)
                    .position(x: cx, y: midY)
                    .help(Text("Nhiệt độ pin hiện tại: \(Format.temperature(current))"))
            }
        }
        .frame(width: width, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if dragging == nil {
                        // Chọn núm gần điểm bắt đầu kéo nhất.
                        dragging = abs(g.startLocation.x - pauseX) <= abs(g.startLocation.x - resumeX) ? .pause : .resume
                    }
                    dragValue = clampedValue(value(at: g.location.x, width))
                }
                .onEnded { _ in
                    defer { dragging = nil; dragValue = nil }
                    guard let thumb = dragging, let v = dragValue else { return }
                    switch thumb {
                    case .pause: if v != pause { onCommit(v, min(resume, v - 1)) }
                    case .resume: if v != resume { onCommit(pause, v) }
                    }
                },
            including: isEnabled ? .all : .none
        )
    }

    private func clampedValue(_ v: Double) -> Double {
        switch dragging {
        case .pause: min(max(v, 30), range.upperBound)
        case .resume: min(max(v, range.lowerBound), pause - 1)
        case nil: v
        }
    }

    private func thumb(color: Color) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(.white)
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(.black.opacity(0.18), lineWidth: 0.5))
            .overlay(Capsule().fill(color).frame(width: 2, height: 12))
            .frame(width: 7, height: 22)
            .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
    }

    private func label(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(color)
            .fixedSize()
    }

    private func ticks(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach([25, 30, 35, 40, 45, 50, 55], id: \.self) { mark in
                Text("\(mark)°")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .position(x: min(max(x(Double(mark), width), 10), width - 10), y: 6)
            }
        }
    }
}

import SwiftUI

/// Thanh giới hạn sạc: rãnh là cả viên pin (0–100%), phần tô là mức pin hiện tại, khung nét đứt là khoảng
/// giữ pin (sailing), núm là "vạch giới hạn". Kéo để đổi; chỉ gửi giá trị khi thả tay.
struct LimitBar: View {
    enum Style { case compact, large }

    var limit: Int
    var percent: Int?
    /// nil = không hiện khoảng giữ pin (máy Intel, hoặc đang tắt giới hạn).
    var sailingGap: Int?
    var range: ClosedRange<Int> = 20...100
    /// Màu của khoảng giữ pin, núm và nhãn giá trị (điều khiển dùng màu nhấn của hệ thống).
    var tint: Color = .accentColor
    /// Màu phần tô mức pin hiện tại (theo trạng thái).
    var fillTint: Color = .green
    var style: Style = .compact
    var onCommit: (Int) -> Void

    @State private var dragValue: Int?
    @Environment(\.isEnabled) private var isEnabled

    private var trackHeight: CGFloat { style == .large ? 12 : 8 }
    private var thumbHeight: CGFloat { trackHeight + 12 }
    private var bubbleHeight: CGFloat { style == .large ? 26 : 0 }
    private var shown: Int { dragValue ?? limit }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                bar(width: geo.size.width)
            }
            .frame(height: bubbleHeight + thumbHeight)
            if style == .large {
                GeometryReader { geo in scale(width: geo.size.width) }
                    .frame(height: 14)
            }
        }
        .opacity(isEnabled ? 1 : 0.5)
        .focusable(isEnabled)
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(1) }
        .accessibilityRepresentation {
            Slider(value: Binding(get: { Double(limit) }, set: { onCommit(Int($0.rounded())) }),
                   in: Double(range.lowerBound)...Double(range.upperBound), step: 1) {
                Text("Giới hạn sạc")
            }
        }
    }

    private func x(_ value: Int, _ width: CGFloat) -> CGFloat {
        width * CGFloat(min(max(value, 0), 100)) / 100
    }

    private func value(at location: CGFloat, _ width: CGFloat) -> Int {
        let raw = Int((location / max(width, 1) * 100).rounded())
        return min(max(raw, range.lowerBound), range.upperBound)
    }

    private func step(_ delta: Int) -> KeyPress.Result {
        let next = min(max(limit + delta, range.lowerBound), range.upperBound)
        if next != limit { onCommit(next) }
        return .handled
    }

    @ViewBuilder
    private func bar(width: CGFloat) -> some View {
        let midY = bubbleHeight + thumbHeight / 2
        let thumbX = min(max(x(shown, width), 3), width - 3)
        ZStack(alignment: .topLeading) {
            // Phần không chọn được (dưới mức tối thiểu): nhạt hơn để người dùng hiểu vì sao núm dừng lại.
            Capsule()
                .fill(Theme.track)
                .frame(width: width, height: trackHeight)
                .offset(y: midY - trackHeight / 2)
            Rectangle()
                .fill(Theme.track)
                .frame(width: x(range.lowerBound, width), height: trackHeight)
                .clipShape(Capsule())
                .opacity(0.6)
                .offset(y: midY - trackHeight / 2)

            if let percent, percent > 0 {
                Capsule()
                    .fill(fillTint.gradient)
                    .frame(width: max(x(percent, width), trackHeight), height: trackHeight)
                    .offset(y: midY - trackHeight / 2)
                    .motion(.easeInOut(duration: 0.6), value: percent)
            }

            if let gap = sailingGap, shown < 100 {
                let lower = max(shown - gap, 0)
                let bandHeight = trackHeight + 6
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(tint.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(tint.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    .frame(width: max(x(shown, width) - x(lower, width), 2), height: bandHeight)
                    .offset(x: x(lower, width), y: midY - bandHeight / 2)
            }

            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(.white)
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(.black.opacity(0.18), lineWidth: 0.5))
                .overlay(Capsule().fill(tint).frame(width: 2, height: thumbHeight - 10))
                .frame(width: 7, height: thumbHeight)
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                .offset(x: thumbX - 3.5, y: midY - thumbHeight / 2)

            if style == .large || dragValue != nil {
                Text("\(shown)%")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(tint, in: Capsule())
                    .fixedSize()
                    .frame(width: 44)
                    .position(x: min(max(thumbX, 22), width - 22), y: style == .large ? 11 : -12)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: bubbleHeight + thumbHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in dragValue = value(at: g.location.x, width) }
                .onEnded { g in
                    let final = value(at: g.location.x, width)
                    dragValue = nil
                    if final != limit { onCommit(final) }
                },
            including: isEnabled ? .all : .none
        )
    }

    private func scale(width: CGFloat) -> some View {
        let marks = [range.lowerBound, 40, 60, 80, 100].filter { $0 >= range.lowerBound }
        return ZStack(alignment: .topLeading) {
            ForEach(Array(Set(marks)).sorted(), id: \.self) { mark in
                Text("\(mark)%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .frame(width: 36)
                    .position(x: min(max(x(mark, width), 18), width - 18), y: 7)
            }
        }
    }
}

/// Nút chọn nhanh mức giới hạn.
struct LimitPresets: View {
    var values: [Int] = [60, 80, 100]
    let current: Int
    var tint: Color = .accentColor
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(values, id: \.self) { value in
                let selected = value == current
                Button {
                    onSelect(value)
                } label: {
                    Text("\(value)%")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .fixedSize()
                        .foregroundStyle(selected ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(selected ? AnyShapeStyle(tint.opacity(0.16)) : AnyShapeStyle(Theme.panel), in: Capsule())
                        .overlay(Capsule().strokeBorder(selected ? tint.opacity(0.45) : Theme.cardStroke, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

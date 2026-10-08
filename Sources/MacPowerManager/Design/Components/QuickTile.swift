import SwiftUI

/// Ô thao tác nhanh (khoảng 72×64): vòng biểu tượng + nhãn, tô màu khi đang bật.
struct QuickTile: View {
    let title: LocalizedStringKey
    let symbol: String
    var isOn: Bool
    var tint: Color
    var height: CGFloat = 64
    var action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(isOn ? AnyShapeStyle(tint) : AnyShapeStyle(Theme.track))
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                }
                .frame(width: 28, height: 28)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(isOn ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    // Nhãn dài (ví dụ tiếng Anh "Heat Protection"): khít chữ trước, rồi mới thu nhỏ; chừa lề hai bên.
                    .allowsTightening(true)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 4)
            }
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .background(isOn ? AnyShapeStyle(tint.opacity(0.14)) : AnyShapeStyle(Theme.panel),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                .strokeBorder(isOn ? tint.opacity(0.35) : .clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
            .motion(.easeInOut(duration: 0.2), value: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

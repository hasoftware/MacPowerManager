import SwiftUI

/// Chip trạng thái: biểu tượng + chữ trên nền màu nhạt của trạng thái.
struct StateChip: View {
    let state: PowerState
    let title: String
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: state.symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(state.tint)
                .symbolEffect(.pulse, options: .repeating, isActive: animated && !reduceMotion && state.isCharging)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(state.tint.opacity(0.16), in: Capsule())
        .overlay(Capsule().strokeBorder(state.tint.opacity(0.25), lineWidth: 0.5))
        .motion(.easeInOut(duration: 0.25), value: state)
        .accessibilityElement(children: .combine)
    }
}

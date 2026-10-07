import SwiftUI

/// Biểu trưng của app: viên pin trên nền bo tròn, phần tô dừng ở "vạch giới hạn" (motif riêng của app).
struct AppLogo: View {
    var size: CGFloat = 64

    var body: some View {
        let s = size / 64
        ZStack {
            RoundedRectangle(cornerRadius: 14 * s, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.13, green: 0.72, blue: 0.62), Color(red: 0.06, green: 0.45, blue: 0.52)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: 14 * s, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: max(0.5, s))

            // Viên pin.
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5 * s, style: .continuous)
                    .strokeBorder(.white, lineWidth: 2.5 * s)
                    .frame(width: 38 * s, height: 22 * s)
                RoundedRectangle(cornerRadius: 2.5 * s, style: .continuous)
                    .fill(.white.opacity(0.9))
                    .frame(width: 25 * s, height: 14 * s)
                    .offset(x: 4 * s)
                // Vạch giới hạn ở 80%, nhô ra ngoài viền.
                Capsule()
                    .fill(.white)
                    .frame(width: 2.5 * s, height: 32 * s)
                    .offset(x: 31 * s)
            }
            .frame(width: 38 * s, height: 32 * s, alignment: .leading)
            .overlay(alignment: .trailing) {
                RoundedRectangle(cornerRadius: 1.5 * s)
                    .fill(.white)
                    .frame(width: 3 * s, height: 8 * s)
                    .offset(x: 4.5 * s)
            }
            .offset(x: -2 * s)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.15), radius: 2 * s, y: 1 * s)
        .accessibilityHidden(true)
    }
}

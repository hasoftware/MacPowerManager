import AppKit
import SwiftUI

/// Token giao diện dùng chung. Màu bề mặt định nghĩa bằng code (SwiftPM không biên dịch `.xcassets`).
enum Theme {
    // MARK: Bề mặt

    static let canvas = dynamic(light: 0xF2F2F5, dark: 0x17171A)
    static let card = dynamic(light: 0xFFFFFF, dark: 0x232327)
    static let elevated = dynamic(light: 0xF7F7FA, dark: 0x2C2C31)
    static let cardStroke = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.06)
    })
    /// Nền của các khối trong bảng nhanh (trên nền vật liệu của menu).
    static let panel = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor.white.withAlphaComponent(0.06) : NSColor.black.withAlphaComponent(0.04)
    })
    /// Rãnh của thanh giới hạn, vòng pin, biểu đồ nhỏ.
    static let track = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.08)
    })

    // MARK: Khoảng cách, bo góc

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let card: CGFloat = 12
        static let panel: CGFloat = 10
        static let tile: CGFloat = 10
    }

    // MARK: Chữ

    static let heroPercent = Font.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit()
    static let popoverPercent = Font.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit()
    static let kpi = Font.title2.weight(.semibold).monospacedDigit()
    static let cardTitle = Font.subheadline.weight(.semibold)

    /// Màu riêng của ứng dụng cho "vạch giới hạn" (limit line).
    static let limitLine = Color.primary

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.isDark ? NSColor(hex: dark) : NSColor(hex: light) })
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension View {
    /// Nền thẻ: đặc, viền mảnh, bóng nhẹ ở chế độ sáng.
    func cardSurface(radius: CGFloat = Theme.Radius.card) -> some View {
        modifier(CardSurface(radius: radius))
    }
}

private struct CardSurface: ViewModifier {
    let radius: CGFloat
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(Theme.card, in: shape)
            .overlay(shape.strokeBorder(Theme.cardStroke))
            .shadow(color: .black.opacity(scheme == .light ? 0.06 : 0), radius: 1.5, y: 1)
    }
}

/// Animation tắt khi người dùng bật Giảm chuyển động.
struct MotionAware: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: AnyHashable

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    func motion<V: Hashable>(_ animation: Animation, value: V) -> some View {
        modifier(MotionAware(animation: animation, value: AnyHashable(value)))
    }
}

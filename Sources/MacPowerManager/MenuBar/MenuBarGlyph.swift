import AppKit

/// Nội dung cần vẽ trên thanh menu. Dùng làm khóa cache: chỉ vẽ lại khi có thay đổi.
struct MenuBarContent: Hashable {
    var percent: Int?
    /// Vạch giới hạn (nil = không giới hạn).
    var limit: Int?
    var state: PowerState
    var style: MenuBarStyle = .glyph
    var showPercent = true
    /// Tô màu phần pin theo trạng thái (mặc định: ảnh template đơn sắc).
    var colored = false
}

/// Vẽ mục thanh menu bằng Core Graphics: "82%" rồi viên pin có phần tô theo %, vạch giới hạn 1 pt nhô ra
/// hai phía và huy hiệu trạng thái được khoét viền 1 pt để luôn dễ đọc. Mặc định là ảnh template để hệ thống
/// tự đổi màu theo thanh menu. Ô phần trăm có độ rộng cố định (đo từ "100%") để mục không bị nhảy.
@MainActor
enum MenuBarRenderer {
    static let height: CGFloat = 16
    /// Rộng hơn mức này có thể bị notch che trên MacBook có notch.
    static let notchWarningWidth: CGFloat = 90
    private static let glyphSize = CGSize(width: 27, height: 16)
    private static let gap: CGFloat = 4
    private static var cache: [MenuBarContent: NSImage] = [:]

    /// Ảnh cho thanh menu thật: template (đơn sắc), hoặc màu với `labelColor` được phân giải lúc vẽ.
    static func image(for content: MenuBarContent) -> NSImage {
        if let cached = cache[content] { return cached }
        let image = makeImage(content, ink: content.colored ? .labelColor : .black)
        image.isTemplate = !content.colored
        if cache.count > 64 { cache.removeAll() }
        cache[content] = image
        return image
    }

    /// Ảnh bitmap để xem trước trên nền sáng hoặc tối (màu được phân giải theo giao diện đó).
    static func previewImage(for content: MenuBarContent, dark: Bool, scale: CGFloat = 2) -> NSImage {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
        var result = NSImage(size: size(for: content))
        appearance.performAsCurrentDrawingAppearance {
            let ink: NSColor = dark ? .white : NSColor.black.withAlphaComponent(0.85)
            let image = makeImage(content, ink: ink)
            var rect = CGRect(origin: .zero, size: CGSize(width: image.size.width * scale, height: image.size.height * scale))
            if let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                result = NSImage(cgImage: cg, size: image.size)
            }
        }
        return result
    }

    static func size(for content: MenuBarContent) -> CGSize {
        let iconWidth = iconWidth(content)
        let textWidth = percentText(content) == nil ? 0 : slotWidth
        let width = ceil(iconWidth + (iconWidth > 0 && textWidth > 0 ? gap : 0) + textWidth)
        return CGSize(width: max(width, 1), height: height)
    }

    private static var font: NSFont { .monospacedDigitSystemFont(ofSize: 12, weight: .medium) }

    /// Độ rộng ô phần trăm, đo một lần từ chuỗi dài nhất.
    private static let slotWidth: CGFloat = ceil(("100%" as NSString).size(withAttributes: [.font: font]).width)

    private static func iconWidth(_ content: MenuBarContent) -> CGFloat {
        switch content.style {
        case .glyph: glyphSize.width
        case .symbol: symbolImage(content).map(\.size.width) ?? 0
        case .text: 0
        }
    }

    private static func makeImage(_ content: MenuBarContent, ink: NSColor) -> NSImage {
        let text = percentText(content)
        let size = size(for: content)
        let image = NSImage(size: size, flipped: true) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            // Lớp trong suốt riêng: thao tác khoét (destinationOut) chỉ ảnh hưởng hình của mình,
            // không xuyên xuống nền thanh menu khi ảnh được vẽ trực tiếp.
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            defer { cg.endTransparencyLayer() }
            var x: CGFloat = 0
            if let text {
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
                let textSize = (text as NSString).size(withAttributes: attrs)
                // Căn phải trong ô cố định để biểu tượng luôn đứng yên.
                (text as NSString).draw(at: CGPoint(x: slotWidth - textSize.width, y: (height - textSize.height) / 2),
                                        withAttributes: attrs)
                x = slotWidth + gap
            }
            switch content.style {
            case .glyph:
                drawGlyph(content, origin: CGPoint(x: x, y: 0), ink: ink)
            case .symbol:
                if let symbol = symbolImage(content) {
                    let rect = CGRect(origin: CGPoint(x: x, y: (height - symbol.size.height) / 2), size: symbol.size)
                    symbol.tinted(ink).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                                            respectFlipped: true, hints: nil)
                }
            case .text:
                break
            }
            return true
        }
        image.accessibilityDescription = content.percent.map { String(localized: "Pin \($0)%") }
        return image
    }

    private static func percentText(_ content: MenuBarContent) -> String? {
        guard let percent = content.percent else { return content.style == .text ? "—" : nil }
        if content.style == .text { return "\(percent)%" }
        return content.showPercent ? "\(percent)%" : nil
    }

    // MARK: Biểu tượng riêng

    private static func drawGlyph(_ content: MenuBarContent, origin: CGPoint, ink: NSColor) {
        let percent = CGFloat(min(max(content.percent ?? 0, 0), 100)) / 100
        let outline = CGRect(x: origin.x + 0.5, y: origin.y + 2.5, width: 23, height: 11)
        let interior = outline.insetBy(dx: 0.5, dy: 0.5)
        let fillArea = outline.insetBy(dx: 2, dy: 2)
        let fillColor: NSColor = content.colored && content.state != .onBattery && content.state != .unknown
            ? content.state.nsTint : ink

        // Viền và cực pin.
        ink.setStroke()
        let body = NSBezierPath(roundedRect: outline, xRadius: 3.5, yRadius: 3.5)
        body.lineWidth = 1
        body.stroke()
        ink.setFill()
        NSBezierPath(roundedRect: CGRect(x: outline.maxX + 1, y: origin.y + 5.5, width: 2, height: 5),
                     xRadius: 1, yRadius: 1).fill()

        // Phần tô theo %.
        if percent > 0 {
            fillColor.setFill()
            let width = max(fillArea.width * percent, 1.5)
            NSBezierPath(roundedRect: CGRect(x: fillArea.minX, y: fillArea.minY, width: width, height: fillArea.height),
                         xRadius: 1.5, yRadius: 1.5).fill()
        }

        // Vạch giới hạn: khoét khe 1 pt hai bên trong phần tô rồi vẽ vạch 1 pt nhô ra trên/dưới viền.
        if let limit = content.limit, limit < 100 {
            let x = (fillArea.minX + fillArea.width * CGFloat(limit) / 100).rounded(.down) + 0.5
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(rect: CGRect(x: x - 1.5, y: interior.minY, width: 3, height: interior.height)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            ink.setFill()
            NSBezierPath(rect: CGRect(x: x - 0.5, y: origin.y, width: 1, height: glyphSize.height)).fill()
        }

        // Huy hiệu trạng thái ở giữa, khoét viền 1 pt quanh nó.
        if let name = content.state.badge,
           let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold)) {
            let size = symbol.size
            let rect = CGRect(x: (interior.midX - size.width / 2).rounded(), y: (interior.midY - size.height / 2).rounded(),
                              width: size.width, height: size.height)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: interior).addClip()
            for dx in [-1.0, 0, 1] {
                for dy in [-1.0, 0, 1] where dx != 0 || dy != 0 {
                    symbol.draw(in: rect.offsetBy(dx: dx, dy: dy), from: .zero, operation: .destinationOut, fraction: 1,
                                respectFlipped: true, hints: nil)
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            symbol.tinted(ink).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                                    respectFlipped: true, hints: nil)
        }
    }

    // MARK: SF Symbol của hệ thống

    private static func symbolImage(_ content: MenuBarContent) -> NSImage? {
        let percent = content.percent ?? 0
        let name: String = if content.state.isCharging {
            "battery.100percent.bolt"
        } else {
            switch percent {
            case 88...: "battery.100percent"
            case 63...: "battery.75percent"
            case 38...: "battery.50percent"
            case 13...: "battery.25percent"
            default: "battery.0percent"
            }
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
    }
}

private extension NSImage {
    /// Bản tô màu của một ảnh template (ví dụ SF Symbol).
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }
}

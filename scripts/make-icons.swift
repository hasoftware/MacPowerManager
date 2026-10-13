// Tạo icon app, logo, favicon và ảnh social preview cho MacPowerManager.
//   swift scripts/make-icons.swift
// Kết quả:
//   Resources/AppIcon.icns                 icon app (Finder, Dock, Launchpad)
//   docs/assets/logo-{1024,512,256,128}.png logo kiểu icon macOS (nền trong suốt)
//   docs/assets/favicon.ico, favicon-{16,32}.png, apple-touch-icon.png
//   docs/assets/social-preview.png         ảnh 1280×640 cho GitHub (Settings → Social preview)
// Thiết kế: viên pin trắng trên nền gradient xanh ngọc, với "vạch giới hạn" nhô ra ngoài viền pin — motif của app.

import AppKit
import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("docs/assets")
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

let space = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}
let tealTop = color(0.16, 0.78, 0.66)
let tealBottom = color(0.05, 0.40, 0.50)

/// Hình chữ nhật bo góc kiểu "continuous" (gần squircle của macOS).
func squircle(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// Vẽ viên pin có vạch giới hạn, căn giữa trong `box`. `weight` là độ dày nét theo đơn vị của box 1024.
func drawBattery(in ctx: CGContext, box: CGRect, pixelSize: CGFloat) {
    let u = box.width / 824                       // đơn vị theo vùng nội dung 824 của lưới icon macOS
    // Ở kích thước nhỏ, làm nét dày hơn để vẫn đọc được.
    let boost: CGFloat = pixelSize <= 16 ? 1.25 : pixelSize <= 32 ? 1.3 : pixelSize <= 64 ? 1.15 : 1
    // Cỡ rất nhỏ: nét làm tròn theo pixel để không nhòe.
    let stroke = pixelSize <= 32 ? max((34 * u * boost).rounded(), 1) : 34 * u * boost
    let bodyW = 520 * u, bodyH = 300 * u
    let nubW = 36 * u, nubH = 122 * u, gap = 20 * u
    let totalW = bodyW + gap + nubW
    let origin = CGPoint(x: box.midX - totalW / 2, y: box.midY - bodyH / 2)
    let body = CGRect(x: origin.x, y: origin.y, width: bodyW, height: bodyH)

    // Đầu cực pin.
    ctx.setFillColor(color(1, 1, 1, 0.95))
    ctx.addPath(squircle(CGRect(x: body.maxX + gap, y: body.midY - nubH / 2, width: nubW, height: nubH), radius: 14 * u))
    ctx.fillPath()

    // Phần pin đã sạc (tới gần vạch giới hạn), gradient trắng → xanh bạc hà rất nhạt.
    // Khoảng hở giữa viền và phần đã sạc: tối thiểu 1 px để hai phần không dính vào nhau.
    let inset = stroke + max(22 * u * min(boost, 1.2), pixelSize <= 32 ? 1 : 0)
    let inner = body.insetBy(dx: inset, dy: inset)
    let limitX = inner.minX + inner.width * 0.80
    let fill = CGRect(x: inner.minX, y: inner.minY, width: inner.width * 0.72, height: inner.height)
    ctx.saveGState()
    ctx.addPath(squircle(fill, radius: 28 * u))
    ctx.clip()
    let fillGradient = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, 1), color(0.86, 1.0, 0.95, 1)] as CFArray,
                                  locations: [0, 1])!
    ctx.drawLinearGradient(fillGradient, start: CGPoint(x: fill.minX, y: fill.maxY), end: CGPoint(x: fill.maxX, y: fill.minY),
                           options: [])
    ctx.restoreGState()

    // Viền pin.
    ctx.setStrokeColor(color(1, 1, 1, 1))
    ctx.setLineWidth(stroke)
    ctx.addPath(squircle(body.insetBy(dx: stroke / 2, dy: stroke / 2), radius: 78 * u))
    ctx.strokePath()

    // Vạch giới hạn: nhô ra ngoài viền trên và dưới, có bóng mờ để nổi trên phần đã sạc.
    let lineW = pixelSize <= 32 ? max((30 * u * boost).rounded(), 1) : 30 * u * min(boost, 1.5)
    let overhang = 74 * u
    let line = CGRect(x: limitX - lineW / 2, y: body.minY - overhang, width: lineW, height: bodyH + overhang * 2)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * u), blur: 18 * u, color: color(0.02, 0.22, 0.27, 0.45))
    ctx.setFillColor(color(1, 1, 1, 1))
    ctx.addPath(squircle(line, radius: lineW / 2))
    ctx.fillPath()
    ctx.restoreGState()
}

/// Icon kiểu macOS: squircle 824/1024 có bóng đổ, nền gradient, ánh sáng nhẹ phía trên, viền mảnh.
func drawIcon(in ctx: CGContext, size: CGFloat, fullBleed: Bool = false) {
    let content: CGRect
    let radius: CGFloat
    if fullBleed {
        content = CGRect(x: 0, y: 0, width: size, height: size)
        radius = 0
    } else {
        // Cỡ nhỏ (Finder dạng danh sách, favicon): bớt lề để hình đủ lớn.
        let margin = size <= 32 ? size * 0.03 : size * 100 / 1024
        content = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
        radius = content.width * 0.2237     // tỉ lệ bo góc của icon macOS
        // Bóng đổ của tấm nền.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.028, color: color(0, 0, 0, 0.32))
        ctx.setFillColor(tealBottom)
        ctx.addPath(squircle(content, radius: radius))
        ctx.fillPath()
        ctx.restoreGState()
    }

    ctx.saveGState()
    ctx.addPath(squircle(content, radius: radius))
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [tealTop, tealBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: content.minX, y: content.maxY),
                           end: CGPoint(x: content.maxX, y: content.minY), options: [])
    // Ánh sáng nhẹ phía trên.
    let shine = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, 0.16), color(1, 1, 1, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(shine, start: CGPoint(x: content.midX, y: content.maxY),
                           end: CGPoint(x: content.midX, y: content.midY), options: [])
    ctx.restoreGState()

    if !fullBleed {
        ctx.setStrokeColor(color(1, 1, 1, 0.22))
        ctx.setLineWidth(max(size / 512, 0.5))
        ctx.addPath(squircle(content.insetBy(dx: ctx.boundingBoxOfClipPath.width > 0 ? size / 1024 : 0, dy: size / 1024), radius: radius))
        ctx.strokePath()
    }

    drawBattery(in: ctx, box: fullBleed ? content.insetBy(dx: size * 0.06, dy: size * 0.06) : content, pixelSize: size)
}

func render(size: Int, draw: (CGContext, CGFloat) -> Void) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    draw(ctx, CGFloat(size))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

func write(_ data: Data, _ url: URL) throws {
    try data.write(to: url)
    print("  \(url.path.replacingOccurrences(of: root.path + "/", with: ""))")
}

print("Icon app:")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try render(size: px) { drawIcon(in: $0, size: $1) }.write(to: iconset.appendingPathComponent(name))
    }
}
let icns = root.appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
precondition(iconutil.terminationStatus == 0, "iconutil thất bại")
print("  Resources/AppIcon.icns")

print("Logo:")
for px in [1024, 512, 256, 128] {
    try write(render(size: px) { drawIcon(in: $0, size: $1) }, assets.appendingPathComponent("logo-\(px).png"))
}

print("Favicon:")
var icoImages: [(Int, Data)] = []
for px in [16, 32, 48] {
    let png = render(size: px) { drawIcon(in: $0, size: $1, fullBleed: false) }
    icoImages.append((px, png))
    if px != 48 { try write(png, assets.appendingPathComponent("favicon-\(px).png")) }
}
try write(render(size: 180) { drawIcon(in: $0, size: $1, fullBleed: true) }, assets.appendingPathComponent("apple-touch-icon.png"))
// favicon.ico: định dạng ICO chứa trực tiếp các ảnh PNG.
var ico = Data([0, 0, 1, 0, UInt8(icoImages.count), 0])
var offset = 6 + 16 * icoImages.count
for (px, png) in icoImages {
    var entry = Data([UInt8(px % 256), UInt8(px % 256), 0, 0, 1, 0, 32, 0])
    withUnsafeBytes(of: UInt32(png.count).littleEndian) { entry.append(contentsOf: $0) }
    withUnsafeBytes(of: UInt32(offset).littleEndian) { entry.append(contentsOf: $0) }
    ico.append(entry)
    offset += png.count
}
for (_, png) in icoImages { ico.append(png) }
try write(ico, assets.appendingPathComponent("favicon.ico"))

print("Social preview:")
let social: Data = {
    let w = 1280, h = 640
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let bg = CGGradient(colorsSpace: space, colors: [color(0.05, 0.12, 0.15), color(0.03, 0.27, 0.30)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: .zero, end: CGPoint(x: w, y: h), options: [])
    // Icon bên trái.
    ctx.saveGState()
    ctx.translateBy(x: 90, y: 150)
    drawIcon(in: ctx, size: 340)
    ctx.restoreGState()
    // Chữ.
    let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    func text(_ s: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, at p: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor(white: 1, alpha: alpha),
        ]
        NSAttributedString(string: s, attributes: attrs).draw(at: p)
    }
    text("MacPowerManager", size: 78, weight: .bold, alpha: 1, at: CGPoint(x: 480, y: 360))
    text("Free, open-source battery care for Mac", size: 34, weight: .medium, alpha: 0.85, at: CGPoint(x: 484, y: 300))
    text("Charge limit · Heat Guard · Discharge · History", size: 26, weight: .regular, alpha: 0.6, at: CGPoint(x: 486, y: 250))
    text("github.com/hasoftware/MacPowerManager", size: 22, weight: .medium, alpha: 0.5, at: CGPoint(x: 486, y: 175))
    NSGraphicsContext.restoreGraphicsState()
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}()
try write(social, assets.appendingPathComponent("social-preview.png"))
print("Xong.")

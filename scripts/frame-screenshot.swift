// Đóng khung ảnh chụp giao diện cho README: cắt khoảng trống thừa ở đáy, bo góc, viền mảnh và bóng đổ.
//   swift scripts/frame-screenshot.swift <vào.png> <ra.png> [bán-kính-góc] [--trim]
// Dùng bởi scripts/make-screenshots.sh.

import AppKit
import CoreGraphics

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2, let source = NSImage(contentsOfFile: args[0]),
      var image = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("Cách dùng: frame-screenshot.swift <vào.png> <ra.png> [bán-kính] [--trim]\n".data(using: .utf8)!)
    exit(1)
}
let radius = args.count > 2 ? CGFloat(Double(args[2]) ?? 24) : 24
let space = CGColorSpace(name: CGColorSpace.sRGB)!

/// Cắt các hàng ở đáy có cùng màu với hàng cuối (nền trống của popover), chừa lại một lề.
func trimBottom(_ image: CGImage) -> CGImage {
    let w = image.width, h = image.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return image }
    // Trong bộ nhớ của CGContext, hàng 0 là hàng trên cùng của ảnh.
    func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = (y * w + x) * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
    }
    let background = pixel(w / 2, h - 3)
    func isBlank(_ y: Int) -> Bool {
        stride(from: w / 10, to: w - w / 10, by: 3).allSatisfy { x in
            let p = pixel(x, y)
            return abs(p.0 - background.0) + abs(p.1 - background.1) + abs(p.2 - background.2) < 12
        }
    }
    var last = h - 1
    while last > h / 3 && isBlank(last) { last -= 1 }
    let keep = min(h, last + 1 + 28)
    return image.cropping(to: CGRect(x: 0, y: 0, width: w, height: keep)) ?? image
}

if args.contains("--trim") { image = trimBottom(image) }

let w = CGFloat(image.width), h = CGFloat(image.height)
let pad: CGFloat = 60
let canvasSize = CGSize(width: w + pad * 2, height: h + pad * 2)
guard let ctx = CGContext(data: nil, width: Int(canvasSize.width), height: Int(canvasSize.height), bitsPerComponent: 8,
                          bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
let frame = CGRect(x: pad, y: pad, width: w, height: h)
let path = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Bóng đổ mềm như cửa sổ macOS.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 44, color: CGColor(gray: 0, alpha: 0.32))
ctx.addPath(path)
ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
ctx.fillPath()
ctx.restoreGState()

// Ảnh, cắt theo góc bo.
ctx.saveGState()
ctx.addPath(path)
ctx.clip()
ctx.draw(image, in: frame)
ctx.restoreGState()

// Viền mảnh để ảnh nền sáng không lẫn vào trang GitHub màu trắng.
ctx.addPath(path)
ctx.setStrokeColor(CGColor(gray: 0.5, alpha: 0.35))
ctx.setLineWidth(2)
ctx.strokePath()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[1]))

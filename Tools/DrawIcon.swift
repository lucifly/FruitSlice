import Foundation
import CoreGraphics
import ImageIO

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ hex: UInt32, _ alpha: Double = 1) -> CGColor {
    CGColor(colorSpace: space, components: [Double((hex >> 16) & 255) / 255,
        Double((hex >> 8) & 255) / 255, Double(hex & 255) / 255, alpha])!
}
func render(_ size: Int, to url: URL) throws {
    let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: size * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.scaleBy(x: Double(size) / 1024, y: Double(size) / 1024)
    c.setAllowsAntialiasing(true)
    let plate = CGPath(roundedRect: CGRect(x: 64, y: 64, width: 896, height: 896),
        cornerWidth: 196, cornerHeight: 196, transform: nil)
    c.addPath(plate); c.clip()
    let background = CGGradient(colorsSpace: space,
        colors: [color(0x092B2C), color(0x22655B)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(background, start: CGPoint(x: 800, y: 80), end: CGPoint(x: 180, y: 1000), options: [])
    let light = CGGradient(colorsSpace: space,
        colors: [color(0x8FF2BE, 0.13), color(0x8FF2BE, 0)] as CFArray, locations: [0, 1])!
    c.drawRadialGradient(light, startCenter: CGPoint(x: 340, y: 610), startRadius: 0,
        endCenter: CGPoint(x: 340, y: 610), endRadius: 620, options: [])

    // The orange halves open around the earbud stem.
    c.saveGState(); c.translateBy(x: 428, y: 426); c.rotate(by: .pi / 5)
    func half(_ upper: Bool) {
        c.saveGState(); c.translateBy(x: 0, y: upper ? 66 : -66)
        if !upper { c.scaleBy(x: 1, y: -1) }
        func semicircle(_ radius: Double) -> CGPath {
            let p = CGMutablePath(); p.move(to: CGPoint(x: -radius, y: 0))
            p.addArc(center: .zero, radius: radius, startAngle: .pi, endAngle: 0, clockwise: true)
            p.closeSubpath(); return p
        }
        c.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: color(0x001B19, 0.28))
        c.addPath(semicircle(264)); c.setFillColor(color(0xFF981E)); c.fillPath()
        c.setShadow(offset: .zero, blur: 0, color: nil)
        c.addPath(semicircle(241)); c.setFillColor(color(0xFFF0BF)); c.fillPath()
        c.addPath(semicircle(222)); c.setFillColor(color(upper ? 0xFFB63B : 0xFFA62B)); c.fillPath()
        c.saveGState(); c.addPath(semicircle(223)); c.clip()
        c.setStrokeColor(color(0xFFF3CD, 0.85)); c.setLineWidth(10); c.setLineCap(.round)
        for angle in [Double.pi / 5, Double.pi * 2 / 5, Double.pi * 3 / 5, Double.pi * 4 / 5] {
            c.move(to: CGPoint(x: cos(angle) * 26, y: sin(angle) * 26))
            c.addLine(to: CGPoint(x: cos(angle) * 225, y: sin(angle) * 225)); c.strokePath()
        }
        c.restoreGState()
        c.setFillColor(color(0xFFF1C8)); c.fillEllipse(in: CGRect(x: -22, y: -8, width: 44, height: 36))
        c.restoreGState()
    }
    half(true); half(false); c.restoreGState()

    c.saveGState(); c.translateBy(x: 345, y: 713); c.rotate(by: -0.25)
    let leaf = CGMutablePath(); leaf.move(to: CGPoint(x: -92, y: 0))
    leaf.addCurve(to: CGPoint(x: 92, y: 0), control1: CGPoint(x: -35, y: 100), control2: CGPoint(x: 62, y: 68))
    leaf.addCurve(to: CGPoint(x: -92, y: 0), control1: CGPoint(x: 28, y: -45), control2: CGPoint(x: -40, y: -43))
    c.addPath(leaf); c.setFillColor(color(0x9EE58C)); c.fillPath(); c.restoreGState()

    // A fading sweep ends at the earbud tip, making the earbud the cutting tool.
    let cut = CGMutablePath(); cut.move(to: CGPoint(x: 151, y: 220))
    cut.addQuadCurve(to: CGPoint(x: 431, y: 431), control: CGPoint(x: 295, y: 285))
    c.setLineCap(.round)
    c.addPath(cut); c.setStrokeColor(color(0x87FFD2, 0.15)); c.setLineWidth(42); c.strokePath()
    c.addPath(cut); c.setStrokeColor(color(0xD8FFF0, 0.5)); c.setLineWidth(15); c.strokePath()
    c.addPath(cut); c.setStrokeColor(color(0xFFFFFF, 0.9)); c.setLineWidth(5); c.strokePath()

    func earbud(_ x: Double, _ y: Double) {
        c.saveGState(); c.translateBy(x: x, y: y); c.rotate(by: -.pi * 0.3)
        c.scaleBy(x: 2.8, y: 2.8)
        c.setShadow(offset: CGSize(width: 0, height: -7), blur: 12, color: color(0x001D1D, 0.3))
        let body = CGMutablePath()
        body.addRoundedRect(in: CGRect(x: -10, y: -132, width: 39, height: 151), cornerWidth: 19.5, cornerHeight: 19.5)
        body.addEllipse(in: CGRect(x: -57, y: -15, width: 104, height: 82))
        c.setFillColor(color(0xEFFAF7))
        c.addPath(body); c.fillPath()
        c.setShadow(offset: .zero, blur: 0, color: nil)
        c.setFillColor(color(0xFFFFFF)); c.fillEllipse(in: CGRect(x: -53, y: 7, width: 77, height: 54))
        c.setFillColor(color(0x17423D)); c.fillEllipse(in: CGRect(x: -46, y: 12, width: 20, height: 34))
        c.setFillColor(color(0x597F77)); c.fillEllipse(in: CGRect(x: 2, y: -17, width: 10, height: 5))
        c.setFillColor(color(0xB7D2CC)); c.fill(CGRect(x: 1, y: -113, width: 17, height: 5))
        c.restoreGState()
    }
    earbud(720, 640)
    c.setFillColor(color(0xFFE7A1))
    c.fillEllipse(in: CGRect(x: 326, y: 455, width: 17, height: 17))
    c.fillEllipse(in: CGRect(x: 485, y: 335, width: 22, height: 22))
    c.fillEllipse(in: CGRect(x: 526, y: 375, width: 11, height: 11))
    let image = c.makeImage()!
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}
for base in [16, 32, 128, 256, 512] {
    try render(base, to: output.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2, to: output.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

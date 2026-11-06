import AppKit
import SpriteKit

final class FruitGameView: NSView {
    var game = FruitGame()
    var trackingEnabled = false
    var onFrameDrawn: ((Double) -> Void)?
    var onMouseMove: ((CGPoint) -> Void)?
    var onActivate: (() -> Void)?
    var onPrimaryAction: (() -> Void)?
    var onPause: (() -> Void)?
    private let renderer = SKView()
    private let scene = FruitScene(art: FruitArt())
    private var area: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true; layer?.cornerRadius = 20; layer?.masksToBounds = true
        renderer.translatesAutoresizingMaskIntoConstraints = false
        renderer.ignoresSiblingOrder = true
        renderer.shouldCullNonVisibleNodes = true
        renderer.allowsTransparency = false
        renderer.preferredFramesPerSecond = 120
        addSubview(renderer)
        NSLayoutConstraint.activate([
            renderer.leadingAnchor.constraint(equalTo: leadingAnchor),renderer.trailingAnchor.constraint(equalTo: trailingAnchor),
            renderer.topAnchor.constraint(equalTo: topAnchor),renderer.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        scene.onPointer = { [weak self] point in self?.onMouseMove?(point) }
        scene.onActivate = { [weak self] in self?.onActivate?() }
        scene.onPrimaryAction = { [weak self] in self?.onPrimaryAction?() }
        scene.onPause = { [weak self] in self?.onPause?() }
        if CommandLine.arguments.contains("--benchmark-motion") {
            scene.onPreparedFrame = { [weak self] duration in
                if Thread.isMainThread { self?.onFrameDrawn?(duration) }
                else { DispatchQueue.main.async { [weak self] in self?.onFrameDrawn?(duration) } }
            }
        }
        renderer.presentScene(scene)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    func submitFrame() { scene.bridge.submit(FruitSceneSnapshot(game: game,tracking: trackingEnabled)) }
    func previewImage() -> NSImage? {
        guard let texture = renderer.texture(from: scene,crop: FruitGame.world) else { return nil }
        return NSImage(cgImage: texture.cgImage(),size: FruitGame.world.size)
    }
    override func updateTrackingAreas() {
        if let area { removeTrackingArea(area) }
        area = NSTrackingArea(rect: .zero,options: [.mouseMoved,.activeInKeyWindow,.inVisibleRect],owner: self,userInfo: nil)
        addTrackingArea(area!); super.updateTrackingAreas()
    }
    override func mouseMoved(with event: NSEvent) {
        let point = scene.convertPoint(fromView: renderer.convert(event.locationInWindow,from: nil))
        onMouseMove?(CGPoint(x: point.x,y: 600-point.y))
    }
    override func mouseDown(with event: NSEvent) { mouseMoved(with: event); onActivate?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onPause?() }
        else if event.keyCode == 49 || event.keyCode == 36 { onPrimaryAction?() }
        else { super.keyDown(with: event) }
    }
}

/// Vector artwork is rasterized once, then shared by pooled GPU sprites.
final class FruitArt {
    private var textures: [String: SKTexture] = [:]
    let background: SKTexture
    let dot: SKTexture
    let blade: SKTexture
    init() {
        let backdrop = NSImage(size: FruitGame.world.size); backdrop.lockFocusFlipped(true)
        NSGradient(starting: NSColor(srgbRed: 0.188,green: 0.141,blue: 0.114,alpha: 1),ending: NSColor(srgbRed: 0.110,green: 0.102,blue: 0.106,alpha: 1))!.draw(in: FruitGame.world,angle: 90)
        for i in 0..<55 {
            let path = NSBezierPath(); let y = CGFloat(i*13%600)
            path.move(to: CGPoint(x: 0,y: y)); path.line(to: CGPoint(x: 1000,y: y+sin(Double(i))*12))
            NSColor(srgbRed: 0.945,green: 0.749,blue: 0.510,alpha: i.isMultiple(of: 5) ? 0.07 : 0.025).setStroke()
            path.lineWidth = i.isMultiple(of: 5) ? 2 : 1; path.stroke()
        }
        backdrop.unlockFocus(); background = SKTexture(image: backdrop)
        let circle = NSImage(size: CGSize(width: 16,height: 16)); circle.lockFocusFlipped(true)
        NSColor.white.setFill(); NSBezierPath(ovalIn: CGRect(x: 1,y: 1,width: 14,height: 14)).fill()
        circle.unlockFocus(); dot = SKTexture(image: circle)
        let line = NSImage(size: CGSize(width: 128,height: 32)); line.lockFocusFlipped(true)
        NSColor(srgbRed: 0.63,green: 1,blue: 0.85,alpha: 0.22).setFill()
        NSBezierPath(roundedRect: CGRect(x: 0,y: 7,width: 128,height: 18),xRadius: 9,yRadius: 9).fill()
        NSColor(srgbRed: 0.92,green: 1,blue: 0.965,alpha: 1).setFill()
        NSBezierPath(roundedRect: CGRect(x: 0,y: 14,width: 128,height: 4),xRadius: 2,yRadius: 2).fill()
        line.unlockFocus(); blade = SKTexture(image: line)
        for kind in FruitKind.allCases {
            for half in kind == .bomb ? [0] : [-1,0,1] { _ = texture(kind,half: half) }
        }
    }
    func texture(_ kind: FruitKind, half: Int) -> SKTexture {
        let key = "\(kind.rawValue)-\(half)"
        if let cached = textures[key] { return cached }
        let image = NSImage(size: CGSize(width: 128,height: 144)); image.lockFocusFlipped(true)
        drawFruit(kind,at: CGPoint(x: 64,y: 72),radius: 40,half: half)
        image.unlockFocus()
        let texture = SKTexture(image: image); texture.filteringMode = .linear
        textures[key] = texture; return texture
    }
    func color(_ kind: FruitKind) -> NSColor { fruitColor(kind) }
    private func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex>>16)&255)/255, green: CGFloat((hex>>8)&255)/255, blue: CGFloat(hex&255)/255, alpha: alpha)
    }
    private func fruitColor(_ kind: FruitKind) -> NSColor {
        switch kind {
        case .apple: return color(0xF45D63)
        case .orange: return color(0xFFAD36)
        case .lime: return color(0x9BCC55)
        case .melon: return color(0x52BA92)
        case .bomb: return color(0x555968)
        }
    }
    private func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat, tint: NSColor = .white, weight: NSFont.Weight = .regular) {
        (string as NSString).draw(at: CGPoint(x: x,y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: tint])
    }
    private func center(_ string: String, y: CGFloat, size: CGFloat, tint: NSColor = .white, weight: NSFont.Weight = .regular) {
        let attributes: [NSAttributedString.Key:Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor:tint]
        let width = (string as NSString).size(withAttributes: attributes).width
        (string as NSString).draw(at: CGPoint(x: 500-width/2,y: y), withAttributes: attributes)
    }
    private func circle(_ point: CGPoint, radius: Double, tint: NSColor) {
        tint.setFill(); NSBezierPath(ovalIn: CGRect(x: point.x-radius,y: point.y-radius,width: radius*2,height: radius*2)).fill()
    }

    private func drawFruit(_ kind: FruitKind, at position: CGPoint, radius: Double, angle: Double = 0, half: Int = 0, alpha: Double = 1) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.translateBy(x: position.x,y: position.y); context.rotate(by: angle)
        if half != 0 {
            NSBezierPath(rect: CGRect(x: half < 0 ? -radius-1 : 0,y: -radius-2,width: radius+1,height: radius*2+4)).addClip()
        }
        let outer = fruitColor(kind).withAlphaComponent(alpha)
        circle(.zero, radius: radius, tint: outer)
        if kind == .bomb {
            circle(CGPoint(x: -radius*0.25,y: -radius*0.28), radius: radius*0.30, tint: color(0x858B99,alpha: 0.5))
            let fuse = NSBezierPath(); fuse.move(to: CGPoint(x: 0,y: -radius))
            fuse.curve(to: CGPoint(x: 14,y: -radius-15), controlPoint1: CGPoint(x: -4,y: -radius-20), controlPoint2: CGPoint(x: 17,y: -radius-25))
            color(0xE7D0A6).setStroke(); fuse.lineWidth = 4; fuse.stroke()
            circle(CGPoint(x: 14,y: -radius-15), radius: 5, tint: color(0xFFB247))
            text("×",x: -12,y: -20,size: 31,tint: color(0xF4ECE3),weight: .bold)
            return
        }
        if half != 0 {
            let flesh: NSColor = kind == .melon ? color(0xFF7C82,alpha: alpha) : fruitColor(kind).blended(withFraction: 0.48,of: color(0xFFF1BD))!.withAlphaComponent(alpha)
            circle(.zero,radius: radius-5,tint: flesh)
            for index in 0..<4 {
                let x = Double(half)*(radius*0.25+Double(index%2)*radius*0.24)
                let y = (Double(index/2)-0.5)*radius*0.65
                circle(CGPoint(x: x,y: y),radius: 2.1,tint: color(kind == .melon ? 0x6C3733 : 0xFFF7DC,alpha: alpha))
            }
        } else {
            circle(CGPoint(x: -radius*0.28,y: -radius*0.3),radius: radius*0.28,tint: NSColor.white.withAlphaComponent(0.18))
            if kind == .melon {
                color(0x288B63).setStroke()
                for offset in [-0.4,0.1,0.55] {
                    let stripe = NSBezierPath()
                    stripe.move(to: CGPoint(x: offset*radius,y: -radius*0.8))
                    stripe.curve(to: CGPoint(x: offset*radius,y: radius*0.85),controlPoint1: CGPoint(x: offset*radius-9,y: -radius*0.2),controlPoint2: CGPoint(x: offset*radius+9,y: radius*0.3))
                    stripe.lineWidth = 3; stripe.stroke()
                }
            }
            let leaf = NSBezierPath(ovalIn: CGRect(x: -2,y: -radius-12,width: 23,height: 10))
            color(0x7BCB79).setFill(); leaf.fill()
            color(0xB58B58).setStroke()
            let stem = NSBezierPath(); stem.move(to: CGPoint(x: 0,y: -radius+3)); stem.line(to: CGPoint(x: -3,y: -radius-8)); stem.lineWidth = 3; stem.stroke()
        }
    }

}

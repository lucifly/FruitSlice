import AppKit
import SpriteKit

struct FruitSceneSnapshot { var game: FruitGame; var tracking: Bool }

/// The main loop publishes snapshots; SpriteKit consumes them in its own update.
final class FruitSceneBridge {
    private let lock = NSLock()
    private var latest: FruitSceneSnapshot?
    func submit(_ snapshot: FruitSceneSnapshot) { lock.lock(); latest = snapshot; lock.unlock() }
    func take() -> FruitSceneSnapshot? {
        lock.lock(); defer { lock.unlock() }
        let snapshot = latest; latest = nil; return snapshot
    }
}

final class FruitScene: SKScene {
    let bridge = FruitSceneBridge()
    var onPointer: ((CGPoint) -> Void)?
    var onActivate: (() -> Void)?
    var onPrimaryAction: (() -> Void)?
    var onPause: (() -> Void)?
    var onPreparedFrame: ((Double) -> Void)?
    private let art: FruitArt
    private var began = 0.0
    private var fruitNodes: [SKSpriteNode] = []
    private var pieceNodes: [SKSpriteNode] = []
    private var dropNodes: [SKSpriteNode] = []
    private var trailNodes: [SKSpriteNode] = []
    private let menuPanel = SKNode()
    private let pauseOverlay = SKNode()
    private let flash = SKSpriteNode(color: NSColor(srgbRed: 1,green: 0.4,blue: 0.3,alpha: 1),size: FruitGame.world.size)
    private let pointer = SKNode()
    private let button: SKShapeNode
    private let progress = SKSpriteNode(color: .white,size: CGSize(width: 1,height: 4))
    private let score = SKLabelNode()
    private let best = SKLabelNode()
    private let timer = SKLabelNode()
    private let combo = SKLabelNode()
    private let titleLabel = SKLabelNode()
    private let subtitle = SKLabelNode()
    private let buttonLabel = SKLabelNode()

    init(art: FruitArt) {
        self.art = art
        button = SKShapeNode(rectOf: FruitGame.playButton.size,cornerRadius: 16)
        super.init(size: FruitGame.world.size)
        scaleMode = .aspectFit; anchorPoint = .zero; backgroundColor = NSColor(srgbRed: 0.11,green: 0.10,blue: 0.095,alpha: 1)
        isUserInteractionEnabled = true
        makeScene()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    private func point(_ value: CGPoint) -> CGPoint { CGPoint(x: value.x,y: 600-value.y) }
    private func tint(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex>>16)&255)/255,green: CGFloat((hex>>8)&255)/255,blue: CGFloat(hex&255)/255,alpha: 1)
    }
    private func label(_ node: SKLabelNode = SKLabelNode(), text: String, x: CGFloat, y: CGFloat, size: CGFloat, color: NSColor = .white, centered: Bool = false, parent: SKNode? = nil, bold: Bool = false) {
        node.fontName = bold ? "HelveticaNeue-Bold" : "HelveticaNeue"
        node.fontSize = size; node.fontColor = color
        node.horizontalAlignmentMode = centered ? .center : .left
        node.verticalAlignmentMode = .top; node.position = point(CGPoint(x: x,y: y))
        node.text = text; node.zPosition = 30
        (parent ?? self).addChild(node)
    }
    private func setText(_ node: SKLabelNode, _ text: String) { if node.text != text { node.text = text } }
    private func makeScene() {
        let backdrop = SKSpriteNode(texture: art.background)
        backdrop.position = CGPoint(x: 500,y: 300); backdrop.size = size; backdrop.zPosition = -10
        addChild(backdrop)
        label(text: "FRUIT SLICE",x: 28,y: 20,size: 13,color: tint(0xC7AF91),bold: true)
        label(score,text: "0000",x: 28,y: 42,size: 32,bold: true)
        label(best,text: "最佳连切 ×0",x: 720,y: 25,size: 15,color: tint(0xF0CB8E))
        label(timer,text: "60 秒",x: 882,y: 45,size: 20,bold: true)
        label(combo,text: "",x: 500,y: 90,size: 27,color: tint(0xFFD787),centered: true,bold: true)
        menuPanel.zPosition = 40; addChild(menuPanel)
        label(titleLabel,text: "耳机切水果",x: 500,y: 125,size: 44,centered: true,parent: menuPanel,bold: true)
        label(subtitle,text: "转头挥刀，划过即切",x: 500,y: 190,size: 19,color: tint(0xD5C4B2),centered: true,parent: menuPanel)
        for (index,kind) in [FruitKind.apple,.orange,.melon].enumerated() {
            let node = SKSpriteNode(texture: art.texture(kind,half: 0))
            node.size = CGSize(width: 86.4,height: 97.2); node.position = point(CGPoint(x: 400+index*100,y: 265)); node.zPosition = 1
            node.zRotation = -Double(index-1)*0.14; menuPanel.addChild(node)
        }
        button.position = point(CGPoint(x: FruitGame.playButton.midX,y: FruitGame.playButton.midY)); button.zPosition = 2
        button.strokeColor = .clear; menuPanel.addChild(button)
        label(buttonLabel,text: "开始游戏",x: 500,y: 318,size: 18,color: tint(0xE0EADD),centered: true,parent: menuPanel,bold: true)
        progress.anchorPoint = CGPoint(x: 0,y: 0.5); progress.position = point(CGPoint(x: 366,y: 353)); progress.zPosition = 32; menuPanel.addChild(progress)
        label(text: "水果 +10   ·   连切有加分   ·   炸弹 −20",x: 500,y: 435,size: 17,color: tint(0xF1D8B4),centered: true,parent: menuPanel)
        label(text: "转头挥刀，挑战 60 秒连切。",x: 500,y: 470,size: 15,color: tint(0xB4A08C),centered: true,parent: menuPanel)
        pauseOverlay.zPosition = 80; addChild(pauseOverlay)
        let shade = SKSpriteNode(color: tint(0x191617),size: size)
        shade.alpha = 0.8; shade.position = CGPoint(x: 500,y: 300); pauseOverlay.addChild(shade)
        label(text: "切水果已暂停",x: 500,y: 240,size: 36,centered: true,parent: pauseOverlay,bold: true)
        label(text: "点击「继续」返回游戏",x: 500,y: 300,size: 18,color: tint(0xD5C4B2),centered: true,parent: pauseOverlay)
        flash.position = CGPoint(x: 500,y: 300); flash.zPosition = 20; addChild(flash)
        pointer.zPosition = 70; addChild(pointer)
        let ring = SKShapeNode(circleOfRadius: 10); ring.strokeColor = tint(0xC7FFE0); ring.lineWidth = 2; pointer.addChild(ring)
        let dot = SKSpriteNode(texture: art.dot); dot.size = CGSize(width: 6,height: 6); pointer.addChild(dot)
        apply(FruitSceneSnapshot(game: FruitGame(),tracking: false))
    }
    private func pooled(_ pool: inout [SKSpriteNode], count: Int, z: CGFloat, texture: SKTexture? = nil) {
        while pool.count < count {
            let node = SKSpriteNode(texture: texture); node.zPosition = z; addChild(node); pool.append(node)
        }
        for i in pool.indices { pool[i].isHidden = i >= count }
    }
    private func apply(_ snapshot: FruitSceneSnapshot) {
        let game = snapshot.game, playing = game.phase == .playing || game.phase == .paused
        setText(score,String(format: "%04d",game.score)); setText(best,"最佳连切 ×\(game.bestCombo)"); setText(timer,"\(Int(ceil(game.remaining))) 秒")
        setText(combo,game.combo > 1 && playing ? "连切 ×\(game.combo)" : "")
        pooled(&fruitNodes,count: playing ? game.fruits.count : 0,z: 5)
        for (i,fruit) in (playing ? game.fruits : []).enumerated() {
            let node = fruitNodes[i], texture = art.texture(fruit.kind,half: 0)
            if node.texture !== texture { node.texture = texture }
            node.position = point(fruit.position); node.size = CGSize(width: fruit.radius*3.2,height: fruit.radius*3.6); node.zRotation = -fruit.angle
        }
        pooled(&pieceNodes,count: playing ? game.pieces.count : 0,z: 6)
        for (i,piece) in (playing ? game.pieces : []).enumerated() {
            let node = pieceNodes[i], texture = art.texture(piece.kind,half: piece.side)
            if node.texture !== texture { node.texture = texture }
            node.position = point(piece.position); node.size = CGSize(width: piece.radius*3.2,height: piece.radius*3.6)
            node.zRotation = -piece.angle; node.alpha = min(1,piece.life/0.25)
        }
        pooled(&dropNodes,count: playing ? game.drops.count : 0,z: 4,texture: art.dot)
        for (i,drop) in (playing ? game.drops : []).enumerated() {
            let node = dropNodes[i]; node.position = point(drop.position); node.size = CGSize(width: drop.radius*2,height: drop.radius*2)
            node.color = art.color(drop.kind); node.colorBlendFactor = 1; node.alpha = max(0,drop.life/0.5)
        }
        pooled(&trailNodes,count: playing ? max(0,game.trail.count-1) : 0,z: 15,texture: art.blade)
        if playing && game.trail.count > 1 {
            for i in 1..<game.trail.count {
                let a = point(game.trail[i-1].point), b = point(game.trail[i].point), node = trailNodes[i-1]
                let alpha = max(0,1-(game.elapsed-game.trail[i].time)/0.22)
                node.position = CGPoint(x: (a.x+b.x)/2,y: (a.y+b.y)/2)
                node.size = CGSize(width: hypot(b.x-a.x,b.y-a.y)+3,height: 18)
                node.zRotation = atan2(b.y-a.y,b.x-a.x); node.alpha = alpha
            }
        }
        flash.alpha = game.flash*0.3
        menuPanel.isHidden = game.phase != .ready && game.phase != .finished
        if !menuPanel.isHidden {
            setText(titleLabel,game.phase == .ready ? "耳机切水果" : "本局完成")
            setText(subtitle,game.phase == .ready ? "转头挥刀，划过即切" : "得分 \(game.score)   ·   切开 \(game.sliced) 个   ·   最佳连切 ×\(game.bestCombo)")
            button.fillColor = tint(snapshot.tracking && FruitGame.playButton.contains(game.pointer) ? 0xA0E6B2 : 0x5A7960)
            setText(buttonLabel,snapshot.tracking ? "停留一下，\(game.phase == .ready ? "开始" : "再来一局")" : "开始游戏")
            buttonLabel.fontColor = tint(snapshot.tracking ? 0x183E28 : 0xE0EADD)
            progress.isHidden = game.menuProgress <= 0; progress.size.width = max(1,268*min(1,game.menuProgress))
        }
        pauseOverlay.isHidden = game.phase != .paused
        pointer.isHidden = !snapshot.tracking || game.phase == .paused; pointer.position = point(game.pointer)
    }
    override func update(_ currentTime: TimeInterval) {
        began = ProcessInfo.processInfo.systemUptime
        if let snapshot = bridge.take() { apply(snapshot) }
    }
    override func didFinishUpdate() { onPreparedFrame?(ProcessInfo.processInfo.systemUptime-began) }
    private func route(_ event: NSEvent) {
        guard let view else { return }
        let position = convertPoint(fromView: view.convert(event.locationInWindow,from: nil))
        onPointer?(CGPoint(x: position.x,y: 600-position.y))
    }
    override func mouseMoved(with event: NSEvent) { route(event) }
    override func mouseDown(with event: NSEvent) { route(event); onActivate?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onPause?() }
        else if event.keyCode == 49 || event.keyCode == 36 { onPrimaryAction?() }
        else { super.keyDown(with: event) }
    }
}

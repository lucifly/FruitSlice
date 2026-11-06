import Foundation

enum GamePhase { case ready, playing, paused, finished }
enum FruitKind: Int, CaseIterable { case apple, orange, lime, melon, bomb }
struct FlyingFruit {
    var id: Int
    var kind: FruitKind
    var position: CGPoint
    var velocity: CGPoint
    var radius: Double = 33
    var angle: Double = 0
    var spin: Double = 0
}
struct FruitPiece {
    var kind: FruitKind
    var position: CGPoint
    var velocity: CGPoint
    var radius: Double
    var angle: Double
    var side: Int
    var life: Double = 0.9
}
struct JuiceDrop {
    var kind: FruitKind
    var position: CGPoint
    var velocity: CGPoint
    var radius: Double
    var life: Double = 0.5
}
struct BladePoint { var point: CGPoint; var time: Double }

func bladeHitsCircle(from a: CGPoint, to b: CGPoint, center: CGPoint, radius: Double) -> Bool {
    let dx = b.x-a.x, dy = b.y-a.y, lengthSquared = dx*dx+dy*dy
    guard lengthSquared > 0.36 else { return false }
    let t = min(1, max(0, ((center.x-a.x)*dx + (center.y-a.y)*dy)/lengthSquared))
    return hypot(a.x+t*dx-center.x, a.y+t*dy-center.y) <= radius
}

struct FruitGame {
    static let world = CGRect(x: 0, y: 0, width: 1000, height: 600)
    static let flightBounds = CGRect(x: 22, y: 82, width: 956, height: 496)
    static let playButton = CGRect(x: 350, y: 298, width: 300, height: 64)
    private(set) var phase: GamePhase = .ready
    private(set) var score = 0
    private(set) var sliced = 0
    private(set) var bombsHit = 0
    private(set) var bestCombo = 0
    private(set) var combo = 0
    private(set) var elapsed = 0.0
    private(set) var remaining = 60.0
    private(set) var menuProgress = 0.0
    private(set) var flash = 0.0
    var pointer = CGPoint(x: 500, y: 450)
    var fruits: [FlyingFruit] = []
    var pieces: [FruitPiece] = []
    var drops: [JuiceDrop] = []
    private(set) var trail: [BladePoint] = []
    private var lastSlice = -Double.infinity
    private var nextWave = 0.25
    private var nextID = 0
    private var randomState: UInt64 = 42
    private var bladeAnchor: CGPoint?

    mutating func start(seed: UInt64 = 42) {
        let current = pointer
        self = FruitGame(); randomState = seed == 0 ? 42 : seed
        phase = .playing; pointer = current
    }
    mutating func activate() {
        if (phase == .ready || phase == .finished) && Self.playButton.contains(pointer) {
            start(seed: UInt64(Date().timeIntervalSince1970 * 1000))
        }
    }
    mutating func hoverMenu(delta: Double, enabled: Bool) {
        guard (phase == .ready || phase == .finished), enabled, Self.playButton.contains(pointer), delta.isFinite, delta > 0 else {
            menuProgress = 0; return
        }
        menuProgress += min(delta, 0.05)/0.9
        if menuProgress >= 1 { activate() }
    }
    mutating func pause() { if phase == .playing { phase = .paused }; menuProgress = 0; trail.removeAll(); bladeAnchor = pointer }
    mutating func resume() { if phase == .paused { phase = .playing }; trail.removeAll(); bladeAnchor = pointer }
    mutating func returnToMenu() { self = FruitGame() }

    private mutating func random() -> Double {
        randomState = randomState &* 6364136223846793005 &+ 1442695040888963407
        return Double(randomState >> 11)/Double(UInt64(1)<<53)
    }

    mutating func setPointer(_ point: CGPoint) {
        guard point.x.isFinite && point.y.isFinite else { return }
        let previous = pointer
        pointer = CGPoint(x: min(978, max(22, point.x)), y: min(578, max(82, point.y)))
        guard phase == .playing else { bladeAnchor = pointer; return }
        let from = bladeAnchor ?? previous
        guard hypot(pointer.x-from.x,pointer.y-from.y) > 0.6 else { return }
        bladeAnchor = pointer
        if trail.isEmpty { trail.append(BladePoint(point: from, time: elapsed)) }
        trail.append(BladePoint(point: pointer, time: elapsed))
        if trail.count > 32 { trail.removeFirst(trail.count-32) }
        let hits = fruits.filter { bladeHitsCircle(from: from, to: pointer, center: $0.position, radius: $0.radius+9) }
        guard !hits.isEmpty else { return }
        let identifiers = Set(hits.map(\.id))
        fruits.removeAll { identifiers.contains($0.id) }
        for fruit in hits {
            if fruit.kind == .bomb {
                score = max(0, score-20); bombsHit += 1; combo = 0; lastSlice = -.infinity; flash = 0.3
            } else {
                combo = elapsed-lastSlice < 0.35 ? combo+1 : 1
                lastSlice = elapsed; bestCombo = max(bestCombo, combo)
                score += 10+min(20, (combo-1)*2); sliced += 1
                for side in [-1, 1] {
                    pieces.append(FruitPiece(kind: fruit.kind, position: fruit.position,
                                             velocity: CGPoint(x: fruit.velocity.x+Double(side)*125, y: fruit.velocity.y-65),
                                             radius: fruit.radius, angle: fruit.angle, side: side))
                }
            }
            for _ in 0..<9 {
                let angle = random()*2 * .pi, speed = 70+random()*190
                drops.append(JuiceDrop(kind: fruit.kind, position: fruit.position,
                                      velocity: CGPoint(x: cos(angle)*speed, y: sin(angle)*speed), radius: 2+random()*4))
            }
        }
        if drops.count > 180 { drops.removeFirst(drops.count-180) }
    }

    mutating func update(delta: Double) {
        guard phase == .playing, delta.isFinite, delta > 0 else { return }
        let step = min(delta, 0.05)
        elapsed += delta; remaining = max(0, remaining-delta)
        if remaining == 0 { phase = .finished; trail.removeAll(); return }
        if elapsed-lastSlice > 0.55 { combo = 0 }
        flash = max(0, flash-step)
        nextWave -= delta
        if nextWave <= 0 {
            nextWave = 1.05+random()*0.55
            let count = 2+Int(random()*3)
            for index in 0..<count {
                let x = 120+random()*760
                let kind: FruitKind = index == 0 && elapsed > 5 && random() < 0.26 ? .bomb : FruitKind(rawValue: Int(random()*4))!
                nextID += 1
                fruits.append(FlyingFruit(id: nextID, kind: kind, position: CGPoint(x: x, y: 640+Double(index)*15),
                                          velocity: CGPoint(x: (500-x)*0.18+(random()-0.5)*110, y: -610-random()*90),
                                          radius: kind == .bomb ? 30 : 31+random()*8, angle: random()*6, spin: (random()-0.5)*3))
            }
        }
        for i in fruits.indices {
            fruits[i].velocity.y += 440*step
            fruits[i].position.x += fruits[i].velocity.x*step
            fruits[i].position.y += fruits[i].velocity.y*step
            fruits[i].angle += fruits[i].spin*step
        }
        for i in pieces.indices {
            pieces[i].life -= step; pieces[i].velocity.y += 440*step
            pieces[i].position.x += pieces[i].velocity.x*step; pieces[i].position.y += pieces[i].velocity.y*step
            pieces[i].angle += Double(pieces[i].side)*2*step
        }
        for i in drops.indices {
            drops[i].life -= step; drops[i].velocity.y += 300*step
            drops[i].position.x += drops[i].velocity.x*step; drops[i].position.y += drops[i].velocity.y*step
        }
        fruits.removeAll { $0.position.y > 730 && $0.velocity.y > 0 }
        pieces.removeAll { $0.life <= 0 || $0.position.y > 700 }
        drops.removeAll { $0.life <= 0 }
        trail.removeAll { elapsed-$0.time > 0.22 }
    }
}

func runFruitGameTests() {
    var checks = 0
    func check(_ value: Bool, _ name: String) {
        checks += 1
        if !value { fputs("FAIL: \(name)\n", stderr); exit(1) }
    }
    check(bladeHitsCircle(from: CGPoint(x: 100,y: 300), to: CGPoint(x: 900,y: 300), center: CGPoint(x: 500,y: 300), radius: 35), "swept blade catches fruit between samples")
    check(!bladeHitsCircle(from: .zero, to: .zero, center: .zero, radius: 35), "stationary blade does not cut")
    var still = FruitGame(); still.start()
    still.fruits = [FlyingFruit(id: 1,kind: .apple,position: still.pointer,velocity: .zero)]
    still.activate(); still.update(delta: 0.01)
    check(still.sliced == 0 && still.score == 0, "clicks and stationary contact do not replace slicing")
    var gentle = FruitGame(); gentle.start(); gentle.setPointer(CGPoint(x: 500,y: 330))
    gentle.fruits = [FlyingFruit(id: 1,kind: .apple,position: CGPoint(x: 514,y: 330),velocity: .zero,radius: 1)]
    for step in 1...60 { gentle.setPointer(CGPoint(x: 500+Double(step)*0.2,y: 330)) }
    check(gentle.sliced == 1, "subpixel motion accumulates into a slice at high frame rates")
    var game = FruitGame()
    game.start(seed: 1); game.setPointer(CGPoint(x: 100,y: 300))
    game.fruits = [FlyingFruit(id: 1, kind: .apple, position: CGPoint(x: 500,y: 300), velocity: .zero)]
    game.setPointer(CGPoint(x: 900,y: 300))
    check(game.score == 10 && game.sliced == 1 && game.fruits.isEmpty, "moving blade slices without clicks")
    check(game.pieces.count == 2 && game.drops.count == 9, "slice creates two halves and juice")
    game.setPointer(CGPoint(x: 100,y: 300))
    check(game.score == 10, "same fruit cannot score twice")
    game.fruits = [FlyingFruit(id: 2, kind: .orange, position: CGPoint(x: 400,y: 300), velocity: .zero),
                   FlyingFruit(id: 3, kind: .lime, position: CGPoint(x: 600,y: 300), velocity: .zero)]
    game.setPointer(CGPoint(x: 900,y: 300))
    check(game.sliced == 3 && game.bestCombo == 3 && game.score == 36, "one stroke can combo multiple fruits")
    game.fruits = [FlyingFruit(id: 4, kind: .bomb, position: CGPoint(x: 500,y: 300), velocity: .zero)]
    game.setPointer(CGPoint(x: 100,y: 300))
    check(game.score == 16 && game.bombsHit == 1 && game.combo == 0, "bomb deducts points and breaks combo")
    game.pause(); let remaining = game.remaining
    game.fruits = [FlyingFruit(id: 5, kind: .melon, position: CGPoint(x: 500,y: 300), velocity: .zero)]
    game.setPointer(CGPoint(x: 900,y: 300)); game.update(delta: 5)
    check(game.score == 16 && game.remaining == remaining && game.fruits.count == 1, "paused game cannot slice or advance")
    game.resume(); game.update(delta: 61)
    check(game.phase == .finished && game.remaining == 0, "round ends after sixty seconds")
    game.returnToMenu(); game.setPointer(CGPoint(x: FruitGame.playButton.midX,y: FruitGame.playButton.midY))
    for _ in 0..<60 { game.hoverMenu(delta: 1.0/60, enabled: true) }
    check(game.phase == .playing && game.score == 0, "dwell starts game without nodding")
    game.returnToMenu(); game.hoverMenu(delta: 5, enabled: false)
    check(game.phase == .ready && game.menuProgress == 0, "no dwell activation without active input")
    var first = FruitGame(), second = FruitGame()
    first.start(seed: 7); second.start(seed: 7)
    for _ in 0..<120 { first.update(delta: 0.02); second.update(delta: 0.02) }
    check(first.fruits.map(\.position) == second.fruits.map(\.position), "seeded waves are reproducible")
    check(!first.fruits.isEmpty && first.fruits.contains { $0.position.y < 600 }, "fruit follows an arc into the play field")
    print("PASS: \(checks) fruit slicing, combos, bombs, physics, pause and dwell checks")
}

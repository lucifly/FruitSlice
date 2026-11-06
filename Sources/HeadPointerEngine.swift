import Foundation

func wrappedAngle(_ value: Double) -> Double { atan2(sin(value), cos(value)) }
private let degree = Double.pi / 180

enum NodResult {
    case none, tracking, triggered
    case finished(pitchDelta: Double, yawDelta: Double)
}

/// Detect a short vertical excursion followed by a rebound, even while steering.
/// Fire once at the rebound. Gesture state never gates movement updates.
struct NodDetector {
    private struct Pose { var time: Double; var pitch: Double; var yaw: Double }
    private var history: [Pose] = []
    private var previous: Pose?
    private var candidate: Pose?
    private var peakOffset = 0.0
    private var returnedAt: Double?
    private var cooldownUntil = 0.0
    private var fired = false
    private(set) var minimumDegrees = 4.0
    private(set) var hint = "轻点头并回弹即可发射"

    mutating func configure(minimumDegrees: Double) {
        self.minimumDegrees = min(12, max(2, minimumDegrees))
        reset()
    }
    mutating func reset() {
        let threshold = minimumDegrees
        self = NodDetector()
        minimumDegrees = threshold
    }

    mutating func update(time: Double, pitch: Double, yaw: Double) -> NodResult {
        let current = Pose(time: time, pitch: pitch, yaw: yaw)
        defer { previous = current }
        if let base = candidate {
            let delta = pitch - base.pitch
            if abs(delta) > abs(peakOffset) { peakOffset = delta }
            let speed = previous.map { abs(pitch - $0.pitch) / max(0.001, time - $0.time) } ?? .infinity
            let timedOut = time - base.time > 1.4
            let tooLarge = abs(peakOffset) > 40 * degree
            let turnedAside = abs(wrappedAngle(yaw - base.yaw)) > 22 * degree
            let cancelled = timedOut || tooLarge || turnedAside
            let returning = abs(delta) <= max(1.8, minimumDegrees * 0.5) * degree && speed < 22 * degree
            if returning {
                if returnedAt == nil { returnedAt = time }
            } else { returnedAt = nil }
            let settled = returnedAt.map { time - $0 >= 0.04 } == true && time - base.time >= 0.1
            if cancelled || settled {
                let wasFired = fired
                candidate = nil; returnedAt = nil; history.removeAll(); fired = false
                cooldownUntil = max(cooldownUntil, time + (wasFired ? 0.08 : 0.12))
                if wasFired { hint = "点头已识别" }
                else if tooLarge { hint = "动作过大，轻点头即可" }
                else if turnedAside { hint = "侧转较多，请试着轻点头" }
                else if abs(peakOffset) < minimumDegrees * degree {
                    hint = String(format: "幅度 %.1f°，还差一点（门槛 %.0f°）", abs(peakOffset) / degree, minimumDegrees)
                } else { hint = "请点头后自然回弹" }
                return .finished(pitchDelta: delta, yawDelta: wrappedAngle(yaw - base.yaw))
            }
            let direction = peakOffset >= 0 ? 1.0 : -1.0
            let rebound = abs(peakOffset) - delta * direction
            if !fired && abs(peakOffset) >= minimumDegrees * degree && rebound >= max(0.8, minimumDegrees * 0.2) * degree && time - base.time >= 0.08 {
                fired = true
                cooldownUntil = time + 0.45
                hint = "已识别！自然回正即可"
                return .triggered
            }
            hint = fired ? "已识别！自然回正即可" : String(format: "点头幅度 %.1f° / %.0f°", abs(peakOffset) / degree, minimumDegrees)
            return .tracking
        }
        history.append(current)
        history.removeAll { time - $0.time > 0.24 }
        // A short velocity window tolerates sample jitter, without requiring a
        // stationary pose before every shot. This also works during horizontal aim.
        if time >= cooldownUntil,
           let base = history.last(where: { time - $0.time >= 0.06 }), time > base.time {
            let delta = pitch - base.pitch
            let speed = abs(delta) / (time - base.time)
            let onsetSpeed = (minimumDegrees * 3 + 4) * degree
            if speed >= onsetSpeed && abs(delta) >= 0.65 * degree && abs(wrappedAngle(yaw - base.yaw)) < 6 * degree {
                candidate = Pose(time: time, pitch: base.pitch, yaw: base.yaw)
                peakOffset = delta; returnedAt = nil; fired = false
                history.removeAll()
                hint = String(format: "点头幅度 %.1f° / %.0f°", abs(delta) / degree, minimumDegrees)
                return .tracking
            }
        }
        return .none
    }
}

enum PointerMode: Equatable { case stopped, calibrating, running, paused }
struct PointerOutput { var position: CGPoint; var click: Bool }

struct HeadPointerEngine {
    private(set) var mode: PointerMode = .stopped
    private(set) var message = "戴好耳机后，点击「连接耳机 · 校准」"
    private(set) var source: Int?
    private(set) var lastFresh: Double?
    private(set) var clicks = 0
    private(set) var nodInProgress = false
    var nodEnabled = true
    var halfRangeDegrees = 20.0
    var verticalHalfRangeDegrees: Double?
    var invertX = false
    var invertY = false
    private var started = 0.0
    private var lastTimestamp: Double?
    private var calibration: [(time: Double, orientation: AttitudeRotation)] = []
    private var reference = AttitudeRotation.identity
    private var anchor = CGPoint.zero
    private var latestTarget = CGPoint.zero
    private var bounds = CGRect.zero
    private var nod = NodDetector()
    var nodMinimumDegrees: Double {
        get { nod.minimumDegrees }
        set { nod.configure(minimumDegrees: newValue) }
    }
    var nodHint: String { nod.hint }

    mutating func begin(time: Double, cursor: CGPoint, screen: CGRect) {
        mode = .calibrating; message = "请正视屏幕并保持头部稳定，正在校准…"
        source = nil; lastFresh = nil; lastTimestamp = nil
        started = time; calibration.removeAll(); nod.reset(); nodInProgress = false
        bounds = screen; anchor = cursor; latestTarget = cursor
    }

    mutating func pause(_ reason: String) {
        guard mode == .running || mode == .calibrating else { return }
        mode = .paused; message = reason; nod.reset(); nodInProgress = false
    }
    mutating func stop() { mode = .stopped; message = "已停止"; nod.reset(); nodInProgress = false }
    mutating func tick(time: Double) {
        guard mode == .running || mode == .calibrating else { return }
        if let lastFresh, time - lastFresh > 0.6 { pause("运动数据已停流，请戴好耳机后重新开始") }
        else if lastFresh == nil && time - started > 15 { pause("未收到运动数据，请检查连接和运动权限") }
    }

    mutating func ingest(time: Double, timestamp: Double, source newSource: Int, pitch: Double, yaw: Double, orientation supplied: AttitudeRotation? = nil) -> PointerOutput? {
        guard mode == .running || mode == .calibrating else { return nil }
        guard [time, timestamp, pitch, yaw].allSatisfy(\.isFinite), newSource == 1 || newSource == 2,
              let orientation = (supplied ?? .from(pitch: pitch, yaw: yaw)).normalized else {
            pause("运动数据或来源异常，请重新开始"); return nil
        }
        if let lastFresh, time - lastFresh > 0.6 { pause("采样间隔过长，请重新校准"); return nil }
        if let oldSource = source, oldSource != newSource {
            source = newSource; lastTimestamp = timestamp; lastFresh = time
            nod.reset(); nodInProgress = false
            if mode == .running {
                // AirPods can hand off their single motion stream between buds.
                // Rebase the new coordinate frame without moving the current target.
                reference = orientation; anchor = latestTarget
                return PointerOutput(position: latestTarget, click: false)
            }
            calibration.removeAll(); started = time
        }
        source = newSource
        if let previous = lastTimestamp {
            if timestamp < previous { pause("运动时间戳已重置，请重新校准"); return nil }
            if timestamp == previous { return nil }
        }
        lastTimestamp = timestamp; lastFresh = time
        if mode == .calibrating {
            calibration.append((time, orientation))
            calibration.removeAll { time - $0.time > 0.8 }
            guard time - started >= 2, let first = calibration.first, time - first.time >= 0.65,
                  calibration.allSatisfy({ sample in
                      let q = sample.orientation
                      let dot = abs(q.x*orientation.x + q.y*orientation.y + q.z*orientation.z + q.w*orientation.w)
                      return 2*acos(min(1, dot)) < 2.5 * degree
                  }) else { return nil }
            reference = AttitudeRotation.average(calibration.map(\.orientation))
            mode = .running; message = "耳机已连接 · 转头驾驶与点头发射独立运行"
            return nil
        }

        let angles = (reference.inverse * orientation).steering
        let horizontalRange = max(2, halfRangeDegrees) * degree
        let verticalRange = max(2, verticalHalfRangeDegrees ?? halfRangeDegrees*0.7) * degree
        let target = CGPoint(x: anchor.x - angles.yaw * bounds.width / (2 * horizontalRange) * (invertX ? -1 : 1),
                             y: anchor.y - angles.pitch * bounds.height / (2 * verticalRange) * (invertY ? -1 : 1))
        latestTarget = CGPoint(x: min(bounds.maxX - 1, max(bounds.minX, target.x)), y: min(bounds.maxY - 1, max(bounds.minY, target.y)))
        var fire = false
        if nodEnabled {
            switch nod.update(time: timestamp, pitch: angles.pitch, yaw: angles.yaw) {
            case .triggered: nodInProgress = true; clicks += 1; fire = true
            case .tracking: nodInProgress = true
            case .finished, .none: nodInProgress = false
            }
        } else { nod.reset(); nodInProgress = false }
        // Gesture candidates never freeze movement or rewrite the neutral pose.
        // Smooth once in the render loop, rather than once per callback delivery.
        return PointerOutput(position: latestTarget, click: fire)
    }
}

func runHeadPointerTests() {
    var checks = 0
    func check(_ value: Bool, _ name: String) {
        checks += 1
        if !value { fputs("FAIL: \(name)\n", stderr); exit(1) }
    }
    let screen = CGRect(x: -1000, y: 0, width: 1000, height: 800)
    var engine = HeadPointerEngine()
    engine.begin(time: 0, cursor: CGPoint(x: -500, y: 400), screen: screen)
    for index in 0...110 {
        _ = engine.ingest(time: Double(index) / 50, timestamp: Double(index) / 50, source: 1, pitch: 0, yaw: 179 * degree)
    }
    check(engine.mode == .running, "stable pose calibrates")
    let wrapped = engine.ingest(time: 2.22, timestamp: 2.22, source: 1, pitch: 0, yaw: -179 * degree)
    check(wrapped != nil && abs(wrapped!.position.x + 500) < 60, "yaw wrap does not jump across screen")
    check(engine.ingest(time: 2.23, timestamp: 2.22, source: 1, pitch: 0, yaw: 0) == nil, "duplicate sample cannot move or click")
    _ = engine.ingest(time: 2.24, timestamp: 2.24, source: 2, pitch: 0, yaw: 0)
    check(engine.mode == .running, "source switch rebases without pausing")
    let handedOff = engine.ingest(time: 2.26, timestamp: 2.26, source: 2, pitch: 0, yaw: 0)
    check(handedOff != nil && abs(handedOff!.position.x - wrapped!.position.x) < 0.01, "source switch preserves cursor position")
    engine.begin(time: 3, cursor: CGPoint(x: -500, y: 400), screen: screen)
    _ = engine.ingest(time: 3, timestamp: 3, source: 1, pitch: 0, yaw: 0)
    engine.tick(time: 3.7)
    check(engine.mode == .paused, "silence during calibration pauses")
    engine.begin(time: 5, cursor: CGPoint(x: -500, y: 400), screen: screen)
    engine.tick(time: 21)
    check(engine.mode == .paused, "missing samples time out")
    engine.begin(time: 22, cursor: CGPoint(x: -500, y: 400), screen: screen)
    for index in 0...110 { _ = engine.ingest(time: 22 + Double(index)/50, timestamp: 22 + Double(index)/50, source: 1, pitch: 0, yaw: 0) }
    _ = engine.ingest(time: 24.22, timestamp: 1, source: 1, pitch: 0, yaw: 0)
    check(engine.mode == .paused, "clock reset pauses")

    func gesture(_ points: [Double], yawStep: Double = 0, minimumDegrees: Double = 4, sampleRate: Double = 50) -> (Int, Int) {
        var detector = NodDetector(), clicks = 0, tracked = 0
        detector.configure(minimumDegrees: minimumDegrees)
        for index in 0..<20 { _ = detector.update(time: Double(index)/sampleRate, pitch: 0, yaw: 0) }
        for (index, pitch) in points.enumerated() {
            switch detector.update(time: Double(20 + index)/sampleRate, pitch: pitch * degree, yaw: Double(index) * yawStep * degree) {
            case .tracking: tracked += 1
            case .triggered: clicks += 1
            case .finished: break
            case .none: break
            }
        }
        return (clicks, tracked)
    }
    let nod = [0.0, 1.5, 3, 5, 8, 11, 12, 10, 8, 5, 2, 0] + Array(repeating: 0.0, count: 60)
    check(gesture(nod).0 == 1, "one nod produces exactly one click")
    check(gesture(nod.map { -$0 }).0 == 1, "both sensor pitch signs work")
    check(gesture([0, 0.3, -0.2, 0.4, -0.1, 0]).0 == 0, "jitter does not click")
    check(gesture((0..<50).map { Double($0)/5 }).0 == 0, "slow looking down does not click")
    check(gesture([0, 2, 5, 9, 12] + Array(repeating: 12.0, count: 55)).0 == 0, "holding a tilt does not click")
    check(gesture(nod, yawStep: 4).0 == 0, "large lateral motion rejects nod")
    check(gesture(Array(nod.prefix(12)) + Array(nod.prefix(12)) + Array(repeating: 0, count: 60)).0 == 1, "cooldown rejects a rapid repeated nod")
    check(gesture(Array(nod.prefix(12)) + Array(repeating: 0, count: 20) + Array(nod.prefix(12)) + Array(repeating: 0, count: 35)).0 == 2, "normal consecutive nods are accepted after the shorter cooldown")
    check(gesture(nod).1 > 0, "gesture candidate is reported independently of movement")
    let smallNod = [0.0, 0.8, 1.6, 2.6, 3.6, 4.8, 4.8, 3.6, 2.5, 1, 0] + Array(repeating: 0.0, count: 35)
    check(gesture(smallNod).0 == 1, "small nod triggers the default light profile")
    check(gesture(smallNod, minimumDegrees: 9).0 == 0, "large-gesture profile rejects a small nod")
    check(gesture(smallNod, sampleRate: 25).0 == 1, "light nod also works at 25 Hz")
    check(gesture(smallNod, yawStep: 0.3).0 == 1, "nod works while steering horizontally")
    check(gesture([0, 1, 2, 3, 4.5, 5, 4, 3]).0 == 1, "rebound fires before full return to neutral")
    var moving = NodDetector(), movingClicks = 0
    for index in 0..<20 { _ = moving.update(time: Double(index)/50, pitch: Double(index) * 0.25 * degree, yaw: 0) }
    for (index, pitch) in smallNod.enumerated() {
        if case .triggered = moving.update(time: Double(20 + index)/50, pitch: (4.75 + pitch) * degree, yaw: 0) { movingClicks += 1 }
    }
    check(movingClicks == 1, "nod does not require a prior stationary pose")
    var configured = NodDetector()
    configured.configure(minimumDegrees: 9); configured.reset()
    check(configured.minimumDegrees == 9, "reset preserves selected nod threshold")
    engine = HeadPointerEngine(); engine.nodEnabled = false
    engine.begin(time: 0, cursor: CGPoint(x: -500, y: 400), screen: screen)
    for index in 0...110 { _ = engine.ingest(time: Double(index)/50, timestamp: Double(index)/50, source: 1, pitch: 0, yaw: 0) }
    var point = CGPoint.zero
    for index in 111...150 { point = engine.ingest(time: Double(index)/50, timestamp: Double(index)/50, source: 1, pitch: 0.8, yaw: 0.8)!.position }
    check(screen.contains(point), "negative-coordinate display clamps correctly")
    engine.tick(time: 4)
    check(engine.mode == .paused, "running stream silence pauses")
    engine = HeadPointerEngine()
    engine.begin(time: 0, cursor: CGPoint(x: -500, y: 400), screen: screen)
    for index in 0...130 { _ = engine.ingest(time: Double(index)/50, timestamp: Double(index)/50, source: 1, pitch: 0, yaw: 0) }
    var nodOutput: PointerOutput?
    var lastNodOutput: PointerOutput?
    for (index, pitch) in nod.enumerated() {
        let t = 2.62 + Double(index)/50
        if let output = engine.ingest(time: t, timestamp: t, source: 1, pitch: pitch * degree, yaw: 0) {
            lastNodOutput = output
            if output.click { nodOutput = output }
        }
    }
    check(nodOutput?.click == true && engine.clicks == 1, "complete engine emits one click")
    check(nodOutput.map { abs($0.position.y - 400) > 10 } ?? false, "nod recognition does not freeze steering")
    check(lastNodOutput.map { hypot($0.position.x + 500, $0.position.y - 400) < 1 } ?? false, "finishing nod does not change neutral calibration")
    var batched = HeadPointerEngine()
    batched.begin(time: 0, cursor: CGPoint(x: -500, y: 400), screen: screen)
    for index in 0...130 { _ = batched.ingest(time: Double(index)/50, timestamp: Double(index)/50, source: 1, pitch: 0, yaw: 0) }
    for (index, pitch) in nod.enumerated() {
        _ = batched.ingest(time: 2.62 + Double(index / 4) * 0.08, timestamp: 2.62 + Double(index)/50, source: 1, pitch: pitch * degree, yaw: 0)
    }
    check(batched.clicks == 1, "sensor timestamps preserve nod recognition with batched callbacks")
    var steering = HeadPointerEngine()
    let neutral = AttitudeRotation.from(pitch: 0.3, yaw: 1.4, roll: 0.4)
    steering.begin(time: 0, cursor: CGPoint(x: -500, y: 400), screen: screen)
    for index in 0...130 {
        _ = steering.ingest(time: Double(index)/50, timestamp: Double(index)/50, source: 1, pitch: 0.3, yaw: 1.4, orientation: neutral)
    }
    var movementOutputs = 0, latest = CGPoint.zero
    for index in 0..<100 {
        let time = 2.62 + Double(index)/50
        let pitch = min(0.18, Double(index)*0.01), yaw = min(0.1, Double(index)*0.005)
        if let result = steering.ingest(time: time, timestamp: time, source: 1, pitch: pitch, yaw: yaw,
                                        orientation: neutral * .from(pitch: pitch, yaw: yaw)) {
            movementOutputs += 1; latest = result.position
        }
    }
    check(movementOutputs == 100, "every fresh sample updates steering throughout a false nod candidate")
    check(abs(latest.x - (-500 - 0.1*1000/(40*degree))) < 0.001, "tilted neutral pose maps heading accurately")
    let returnTime = 4.64
    let recentered = steering.ingest(time: returnTime, timestamp: returnTime, source: 1, pitch: 0.3, yaw: 1.4, orientation: neutral)
    check(recentered.map { hypot($0.position.x + 500, $0.position.y - 400) < 0.001 } ?? false, "gesture timeout never rewrites the movement reference")
    var smallRange = HeadPointerEngine()
    smallRange.nodEnabled = false; smallRange.halfRangeDegrees = 8; smallRange.verticalHalfRangeDegrees = 5
    smallRange.begin(time: 0, cursor: CGPoint(x: screen.midX,y: screen.midY), screen: screen)
    for index in 0...130 { _ = smallRange.ingest(time: Double(index)/50, timestamp: Double(index)/50, source: 1, pitch: 0, yaw: 0) }
    let topLeft = smallRange.ingest(time: 2.62, timestamp: 2.62, source: 1, pitch: 5*degree, yaw: 8*degree)
    check(topLeft.map { abs($0.position.x-screen.minX) < 0.001 && abs($0.position.y-screen.minY) < 0.001 } ?? false, "eight degree yaw and five degree pitch reach both near edges")
    let bottomRight = smallRange.ingest(time: 2.64, timestamp: 2.64, source: 1, pitch: -5*degree, yaw: -8*degree)
    check(bottomRight.map { abs($0.position.x-(screen.maxX-1)) < 0.001 && abs($0.position.y-(screen.maxY-1)) < 0.001 } ?? false, "opposite small angles reach far edges symmetrically")
    smallRange.halfRangeDegrees = 3; smallRange.verticalHalfRangeDegrees = 2
    let veryLight = smallRange.ingest(time: 2.66, timestamp: 2.66, source: 1, pitch: 2*degree, yaw: 3*degree)
    check(veryLight.map { abs($0.position.x-screen.minX) < 0.001 && abs($0.position.y-screen.minY) < 0.001 } ?? false, "small custom ranges are not limited by the former eight-degree floor")
    engine.stop()
    check(engine.ingest(time: 5, timestamp: 5, source: 1, pitch: 0, yaw: 0) == nil, "stopped state cannot move or click")
    print("PASS: \(checks) head pointer, calibration, nod, cooldown and pause checks")
}

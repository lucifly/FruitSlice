import Foundation

struct AttitudeRotation {
    var x: Double; var y: Double; var z: Double; var w: Double
    static let identity = AttitudeRotation(x: 0, y: 0, z: 0, w: 1)

    var normalized: AttitudeRotation? {
        let length = sqrt(x*x + y*y + z*z + w*w)
        guard length.isFinite, length > 0.000001 else { return nil }
        return AttitudeRotation(x: x/length, y: y/length, z: z/length, w: w/length)
    }
    var inverse: AttitudeRotation { AttitudeRotation(x: -x, y: -y, z: -z, w: w) }
    static func * (a: AttitudeRotation, b: AttitudeRotation) -> AttitudeRotation {
        AttitudeRotation(x: a.w*b.x + a.x*b.w + a.y*b.z - a.z*b.y,
                         y: a.w*b.y - a.x*b.z + a.y*b.w + a.z*b.x,
                         z: a.w*b.z + a.x*b.y - a.y*b.x + a.z*b.w,
                         w: a.w*b.w - a.x*b.x - a.y*b.y - a.z*b.z)
    }
    static func from(pitch: Double, yaw: Double, roll: Double = 0) -> AttitudeRotation {
        let rz = AttitudeRotation(x: 0, y: 0, z: sin(yaw/2), w: cos(yaw/2))
        let rx = AttitudeRotation(x: sin(pitch/2), y: 0, z: 0, w: cos(pitch/2))
        let ry = AttitudeRotation(x: 0, y: sin(roll/2), z: 0, w: cos(roll/2))
        return rz * rx * ry
    }
    var steering: (pitch: Double, yaw: Double) {
        // Headphone forward is +Y: pitch about X, heading about Z.
        // Derive a direction from the relative rotation, avoiding Euler subtraction.
        (asin(min(1, max(-1, 2*(w*x + y*z)))), atan2(2*(w*z - x*y), 1 - 2*(x*x + z*z)))
    }
    static func average(_ samples: [AttitudeRotation]) -> AttitudeRotation {
        guard let first = samples.first else { return .identity }
        var sum = AttitudeRotation(x: 0, y: 0, z: 0, w: 0)
        for q in samples {
            let sign = first.x*q.x + first.y*q.y + first.z*q.z + first.w*q.w >= 0 ? 1.0 : -1.0
            sum.x += q.x*sign; sum.y += q.y*sign; sum.z += q.z*sign; sum.w += q.w*sign
        }
        return sum.normalized ?? first
    }
}

struct MotionSample {
    var receivedAt: Double
    var timestamp: Double
    var source: Int
    var pitch: Double
    var yaw: Double
    var orientation: AttitudeRotation
}

/// Bounded handoff from the sensor queue to the game loop. No AppKit on that queue.
final class MotionInbox {
    private let lock = NSLock()
    private var samples: [MotionSample] = []
    private var dropped = 0
    func push(_ sample: MotionSample) {
        lock.lock(); defer { lock.unlock() }
        if samples.count == 64 { samples.removeFirst(); dropped += 1 }
        samples.append(sample)
    }
    func drain() -> (samples: [MotionSample], dropped: Int) {
        lock.lock(); defer { lock.unlock() }
        let result = (samples, dropped)
        samples.removeAll(keepingCapacity: true); dropped = 0
        return result
    }
}

/// Render at the display cadence. Only the latest pose is used for movement;
/// every sensor sample still reaches gesture recognition.
struct PointerPresenter {
    private(set) var position = CGPoint(x: 500, y: 310)
    private var target = CGPoint(x: 500, y: 310)
    mutating func reset(_ point: CGPoint) { position = point; target = point }
    mutating func submit(_ point: CGPoint) { target = point }
    mutating func frame(delta: Double) -> CGPoint {
        guard delta.isFinite, delta > 0 else { return position }
        let distance = hypot(target.x - position.x, target.y - position.y)
        guard distance > 0.25 else { return position }
        // Fast response for deliberate movement, more damping near rest.
        let tau = 0.040 - min(1, distance/35) * 0.028
        let alpha = 1 - exp(-min(0.05, delta)/tau)
        position.x += (target.x - position.x) * alpha
        position.y += (target.y - position.y) * alpha
        return position
    }
}

struct MotionTelemetry {
    private var arrivals: [Double] = []
    private var frames: [Double] = []
    private var drawTimes: [(time: Double, duration: Double)] = []
    private var timestamps: [Int: Double] = [:]
    private(set) var newest: Double?
    private(set) var dropped = 0
    mutating func sample(_ sample: MotionSample) {
        if let previous = timestamps[sample.source], previous >= sample.timestamp { return }
        timestamps[sample.source] = sample.timestamp
        newest = sample.receivedAt; arrivals.append(sample.receivedAt)
        arrivals.removeAll { sample.receivedAt - $0 > 1 }
    }
    mutating func rendered(at time: Double, duration: Double = 0) {
        frames.append(time); frames.removeAll { time - $0 > 1 }
        drawTimes.append((time, duration)); drawTimes.removeAll { time - $0.time > 1 }
    }
    var averageDrawMilliseconds: Double { drawTimes.isEmpty ? 0 : drawTimes.reduce(0) { $0 + $1.duration } / Double(drawTimes.count) * 1000 }
    mutating func addDropped(_ count: Int) { dropped += count }
    func description(at time: Double) -> String {
        let hz = arrivals.filter { time - $0 <= 1 }.count
        let fps = frames.filter { time - $0 <= 1 }.count
        let age = newest.map { String(format: "%.0f ms", max(0, time - $0)*1000) } ?? "—"
        return "采样 \(hz) Hz · 画面 \(fps) FPS · 距新数据 \(age)" + (dropped > 0 ? " · 丢弃积压 \(dropped)" : "")
    }
}

func runMotionPipelineTests() {
    var checks = 0
    func check(_ value: Bool, _ name: String) {
        checks += 1
        if !value { fputs("FAIL: \(name)\n", stderr); exit(1) }
    }
    let base = AttitudeRotation.from(pitch: 0.3, yaw: 1.7, roll: 0.4)
    let movement = AttitudeRotation.from(pitch: 0.12, yaw: -0.2, roll: 0.25)
    let relative = base.inverse * (base * movement)
    check(abs(relative.steering.pitch - 0.12) < 0.00001 && abs(relative.steering.yaw + 0.2) < 0.00001, "relative orientation removes tilted neutral pose")
    let negative = AttitudeRotation(x: -base.x, y: -base.y, z: -base.z, w: -base.w)
    let average = AttitudeRotation.average([base, negative])
    check(abs((average.inverse * base).w - 1) < 0.00001, "opposite quaternion signs do not cancel calibration")
    check(AttitudeRotation(x: 0, y: 0, z: 0, w: 0).normalized == nil, "invalid rotation is rejected")
    var presenter = PointerPresenter()
    presenter.reset(CGPoint(x: 100, y: 100)); presenter.submit(CGPoint(x: 200, y: 100))
    let first = presenter.frame(delta: 1.0/60)
    check(first.x > 170 && first.x < 200, "large movement responds on the first frame without overshoot")
    let second = presenter.frame(delta: 1.0/60)
    check(second.x > first.x && second.x < 200, "movement continues between sensor callbacks")
    for _ in 0..<60 { _ = presenter.frame(delta: 1.0/60) }
    check(abs(presenter.position.x - 200) < 0.3, "render smoothing converges accurately")
    let inbox = MotionInbox()
    for index in 0..<100 { inbox.push(MotionSample(receivedAt: Double(index), timestamp: Double(index), source: 1, pitch: 0, yaw: 0, orientation: .identity)) }
    let batch = inbox.drain()
    check(batch.samples.count == 64 && batch.samples.last?.timestamp == 99 && batch.dropped == 36, "overload is bounded and keeps newest motion")
    check(inbox.drain().samples.isEmpty, "draining does not repeat cached samples")
    var telemetry = MotionTelemetry()
    let sample = MotionSample(receivedAt: 1, timestamp: 1, source: 1, pitch: 0, yaw: 0, orientation: .identity)
    telemetry.sample(sample); telemetry.sample(sample); telemetry.rendered(at: 1)
    check(telemetry.description(at: 1).contains("采样 1 Hz") && telemetry.description(at: 3).contains("采样 0 Hz"), "telemetry excludes duplicates and expires stalled input")
    print("PASS: \(checks) relative rotation, render interpolation, queue and telemetry checks")
}

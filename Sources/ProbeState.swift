import Foundation

let probePhases = ["佩戴基线", "盒外手持", "入盒开盖", "入盒合盖", "重新开盖"]

struct PhaseStats {
    var started: Double
    var ended: Double?
    var callbacks = 0
    var fresh = 0
    var duplicates = 0
    var lastFresh: Double?
    var longestGap = 0.0
    var sources = Set<Int>()
    var minPitch = Double.infinity
    var maxPitch = -Double.infinity
    var minYaw = Double.infinity
    var maxYaw = -Double.infinity

    mutating func sample(now: Double, fresh isFresh: Bool, source: Int, pitch: Double, yaw: Double) {
        // Exclude placement transitions and a short burst of queued callbacks.
        guard now - started >= 3 else { return }
        callbacks += 1
        if !isFresh { duplicates += 1; return }
        fresh += 1
        sources.insert(source)
        longestGap = max(longestGap, now - (lastFresh ?? (started + 3)))
        lastFresh = now
        minPitch = min(minPitch, pitch)
        maxPitch = max(maxPitch, pitch)
        minYaw = min(minYaw, yaw)
        maxYaw = max(maxYaw, yaw)
    }

    func summary(now: Double) -> String {
        let end = ended ?? now
        let duration = max(0, end - started - 3)
        guard duration >= 1 else { return "准备中（前 3 秒不计入统计）" }
        let gap = max(longestGap, end - (lastFresh ?? (started + 3)))
        let frequency = Double(fresh) / duration
        let status: String
        if fresh == 0 { status = "未收到时间戳更新" }
        else if gap > 2 { status = "有数据，但存在停流" }
        else if duration < 15 { status = "有新数据，建议观察至少 15 秒" }
        else { status = "观察期间持续更新；请转动盒子核对姿态" }
        let range = fresh > 0 ? String(format: "俯仰范围 %.1f°", (maxPitch - minPitch) * 180 / .pi) : "无姿态范围"
        let sourceText = sources.sorted().map(sensorName).joined(separator: "/")
        return String(format: "%@ · 有效 %.0fs · %d 新样本 / %.1f Hz · 最大间隔 %.1fs · %@ · %@", status, duration, fresh, frequency, gap, range, sourceText.isEmpty ? "来源未知" : sourceText)
    }
}

func sensorName(_ source: Int) -> String {
    switch source { case 1: return "左耳"; case 2: return "右耳"; default: return "未知(\(source))" }
}

struct FreshnessTracker {
    private var timestamps: [Int: Double] = [:]
    mutating func reset() { timestamps.removeAll() }
    mutating func ingest(timestamp: Double, source: Int) -> Bool {
        guard timestamp.isFinite else { return false }
        let previous = timestamps[source]
        timestamps[source] = timestamp
        // A first sample or a clock reset is a reference, not proof of streaming.
        guard let previous else { return false }
        return timestamp > previous
    }
}

func runSelfTests() {
    func check(_ condition: Bool, _ description: String) {
        if !condition { fputs("FAIL: \(description)\n", stderr); exit(1) }
    }
    var tracker = FreshnessTracker()
    check(!tracker.ingest(timestamp: 100, source: 1), "first sample is reference only")
    check(!tracker.ingest(timestamp: 100, source: 1), "cached timestamp is not fresh")
    check(tracker.ingest(timestamp: 100.02, source: 1), "advancing timestamp is fresh")
    check(!tracker.ingest(timestamp: 20, source: 2), "source switch establishes separate reference")
    check(!tracker.ingest(timestamp: 1, source: 1), "clock reset is not fresh")
    check(tracker.ingest(timestamp: 1.02, source: 1), "stream recovers after reset")
    tracker.reset()
    check(!tracker.ingest(timestamp: 200, source: 1), "reconnection clears source references")
    var stats = PhaseStats(started: 0)
    stats.sample(now: 1, fresh: true, source: 1, pitch: 0, yaw: 0)
    check(stats.fresh == 0, "placement grace excludes samples")
    for index in 0..<850 {
        stats.sample(now: 3 + Double(index) / 50, fresh: true, source: 1, pitch: Double(index) / 1000, yaw: 0)
    }
    check(stats.summary(now: 20).contains("持续更新"), "continuous stream recognized")
    check(stats.summary(now: 25).contains("停流"), "silence counts even without callbacks")
    stats.ended = 20
    check(stats.summary(now: 100).contains("持续更新"), "completed phase does not age")
    stats.sample(now: 20, fresh: false, source: 1, pitch: 0, yaw: 0)
    check(stats.duplicates == 1 && stats.fresh == 850, "duplicates do not inflate rate")
    print("PASS: 12 freshness, source switching, grace, continuous-stream and gap checks")
}

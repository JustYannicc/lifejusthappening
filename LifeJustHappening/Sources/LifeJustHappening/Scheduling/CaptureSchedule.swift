import Foundation

/// How often a capture happens, measured in *active* time: minutes where a display is on,
/// the session is unlocked and a human touched the keyboard or mouse recently. Sleep,
/// locked screens and an agent driving the Mac while you're away don't count, so you don't
/// get a burst of photos on wake and nothing fires while you're gone.
struct CaptureSchedule: Codable, Equatable {
    var targetActiveSeconds: TimeInterval
    var accumulatedActiveSeconds: TimeInterval = 0
    /// Attempts in a row where the camera saw nobody. Drives the retry backoff.
    var misses: Int = 0

    static func fresh(
        minMinutes: Int,
        maxMinutes: Int,
        random: (ClosedRange<TimeInterval>) -> TimeInterval = { .random(in: $0) }
    ) -> CaptureSchedule {
        let lower = TimeInterval(min(minMinutes, maxMinutes) * 60)
        let upper = TimeInterval(max(minMinutes, maxMinutes) * 60)
        return CaptureSchedule(targetActiveSeconds: random(lower...upper))
    }

    var isDue: Bool { accumulatedActiveSeconds >= targetActiveSeconds }

    var remainingActiveSeconds: TimeInterval {
        max(0, targetActiveSeconds - accumulatedActiveSeconds)
    }

    var progress: Double {
        guard targetActiveSeconds > 0 else { return 1 }
        return min(1, accumulatedActiveSeconds / targetActiveSeconds)
    }

    mutating func accrue(_ seconds: TimeInterval) {
        accumulatedActiveSeconds += max(0, seconds)
    }

    /// The camera found nobody in frame. Try again after a growing slice of active time
    /// (5, 10, 20… min, capped) instead of starting a whole new interval.
    mutating func deferAfterMiss(base: TimeInterval = 5 * 60, cap: TimeInterval = 40 * 60) {
        misses += 1
        let wait = min(cap, base * pow(2, Double(misses - 1)))
        accumulatedActiveSeconds = max(0, targetActiveSeconds - wait)
    }

    /// Re-rolls the target for a new interval range while keeping the progress made so far.
    func retargeted(minMinutes: Int, maxMinutes: Int) -> CaptureSchedule {
        var next = CaptureSchedule.fresh(minMinutes: minMinutes, maxMinutes: maxMinutes)
        next.accumulatedActiveSeconds = accumulatedActiveSeconds
        return next
    }
}

/// Turns periodic samples into credited active seconds. Gaps longer than `maxCredit`
/// (sleep, app suspension, a stalled main thread) are clamped so they can't count as use.
struct ActiveTimeTracker {
    let maxCredit: TimeInterval
    private(set) var lastSample: Date?

    init(maxCredit: TimeInterval) {
        self.maxCredit = maxCredit
    }

    mutating func sample(at now: Date, isActive: Bool) -> TimeInterval {
        defer { lastSample = now }
        guard isActive, let lastSample else { return 0 }
        return min(max(0, now.timeIntervalSince(lastSample)), maxCredit)
    }

    /// Forget the last sample, e.g. on sleep, so the gap is never credited.
    mutating func reset() {
        lastSample = nil
    }
}

enum PauseState: Codable, Equatable {
    case running
    case paused(until: Date?)

    func isPaused(at now: Date) -> Bool {
        switch self {
        case .running: return false
        case .paused(let until): return until.map { now < $0 } ?? true
        }
    }

    /// A timed pause that has run out is running again.
    func normalized(at now: Date) -> PauseState {
        isPaused(at: now) ? self : .running
    }
}

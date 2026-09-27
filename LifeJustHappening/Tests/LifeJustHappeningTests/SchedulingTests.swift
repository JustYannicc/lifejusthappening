import XCTest

@testable import LifeJustHappening

final class SchedulingTests: XCTestCase {
    func testFreshScheduleDrawsWithinRangeInSeconds() {
        var seen: ClosedRange<TimeInterval>?
        let schedule = CaptureSchedule.fresh(minMinutes: 45, maxMinutes: 60) { range in
            seen = range
            return range.lowerBound
        }
        XCTAssertEqual(seen, 2700...3600)
        XCTAssertEqual(schedule.targetActiveSeconds, 2700)
        XCTAssertEqual(schedule.accumulatedActiveSeconds, 0)
    }

    func testFreshScheduleToleratesSwappedBounds() {
        var seen: ClosedRange<TimeInterval>?
        _ = CaptureSchedule.fresh(minMinutes: 60, maxMinutes: 45) { seen = $0; return $0.lowerBound }
        XCTAssertEqual(seen, 2700...3600)
    }

    func testScheduleBecomesDueOnlyAfterEnoughActiveTime() {
        var schedule = CaptureSchedule(targetActiveSeconds: 90)
        schedule.accrue(60)
        XCTAssertFalse(schedule.isDue)
        XCTAssertEqual(schedule.remainingActiveSeconds, 30)
        schedule.accrue(-100)
        XCTAssertEqual(schedule.accumulatedActiveSeconds, 60, "negative credit is ignored")
        schedule.accrue(30)
        XCTAssertTrue(schedule.isDue)
        XCTAssertEqual(schedule.progress, 1)
    }

    func testRetargetingKeepsProgress() {
        var schedule = CaptureSchedule(targetActiveSeconds: 3600)
        schedule.accrue(1200)
        let next = schedule.retargeted(minMinutes: 10, maxMinutes: 15)
        XCTAssertEqual(next.accumulatedActiveSeconds, 1200)
        XCTAssertTrue((600...900).contains(next.targetActiveSeconds))
        XCTAssertTrue(next.isDue, "shrinking the interval below progress makes it due")
    }

    func testNobodyThereBacksOffInsteadOfRestarting() {
        var schedule = CaptureSchedule(targetActiveSeconds: 3000, accumulatedActiveSeconds: 3000)
        schedule.deferAfterMiss()
        XCTAssertEqual(schedule.remainingActiveSeconds, 300)
        XCTAssertEqual(schedule.misses, 1)
        schedule.accumulatedActiveSeconds = schedule.targetActiveSeconds
        schedule.deferAfterMiss()
        XCTAssertEqual(schedule.remainingActiveSeconds, 600)
        for _ in 0..<5 {
            schedule.accumulatedActiveSeconds = schedule.targetActiveSeconds
            schedule.deferAfterMiss()
        }
        XCTAssertEqual(schedule.remainingActiveSeconds, 2400, "capped at 40 min")
    }

    func testTrackerCreditsOnlyActiveTimeAndClampsGaps() {
        var tracker = ActiveTimeTracker(maxCredit: 60)
        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(tracker.sample(at: start, isActive: true), 0, "first sample has nothing to compare to")
        XCTAssertEqual(tracker.sample(at: start + 30, isActive: true), 30)
        XCTAssertEqual(tracker.sample(at: start + 60, isActive: false), 0, "locked/asleep time isn't credited")
        XCTAssertEqual(tracker.sample(at: start + 8 * 3600, isActive: true), 60, "a night of sleep is clamped")
        tracker.reset()
        XCTAssertEqual(tracker.sample(at: start + 9 * 3600, isActive: true), 0, "reset drops the gap entirely")
    }

    func testTrackerIgnoresClockGoingBackwards() {
        var tracker = ActiveTimeTracker(maxCredit: 60)
        let now = Date()
        _ = tracker.sample(at: now, isActive: true)
        XCTAssertEqual(tracker.sample(at: now - 100, isActive: true), 0)
    }

    func testPauseState() {
        let now = Date()
        XCTAssertFalse(PauseState.running.isPaused(at: now))
        XCTAssertTrue(PauseState.paused(until: nil).isPaused(at: now))
        XCTAssertTrue(PauseState.paused(until: now + 60).isPaused(at: now))
        XCTAssertFalse(PauseState.paused(until: now - 1).isPaused(at: now))
        XCTAssertEqual(PauseState.paused(until: now - 1).normalized(at: now), .running)
        XCTAssertEqual(PauseState.paused(until: nil).normalized(at: now), .paused(until: nil))
    }

    func testActivitySnapshot() {
        let clamshell = ActivitySnapshot(isLidClosed: true, hasActiveDisplay: true, isSessionLocked: false)
        XCTAssertTrue(clamshell.isActive, "clamshell with an external display is still in use")
        XCTAssertNil(clamshell.inactiveReason)

        let locked = ActivitySnapshot(isLidClosed: false, hasActiveDisplay: true, isSessionLocked: true)
        XCTAssertFalse(locked.isActive)
        XCTAssertEqual(locked.inactiveReason, "Screen locked")

        let dark = ActivitySnapshot(isLidClosed: false, hasActiveDisplay: false, isSessionLocked: false)
        XCTAssertFalse(dark.isActive)

        var agentDriving = ActivitySnapshot(isLidClosed: true, hasActiveDisplay: true, isSessionLocked: false)
        agentDriving.secondsSinceHumanInput = 6 * 60
        XCTAssertFalse(agentDriving.isActive, "unlocked and busy, but no human input for 6 min")
        XCTAssertEqual(agentDriving.inactiveReason, "Nobody at the keyboard")
        agentDriving.secondsSinceHumanInput = 30
        XCTAssertTrue(agentDriving.isActive)
        XCTAssertTrue(agentDriving.humanProvablyPresent)
        agentDriving.humanInputVerified = false
        XCTAssertFalse(agentDriving.humanProvablyPresent, "unverified input could be an agent, so check the camera")
    }

    func testOnlyKernelSourcedEventsCountAsHuman() {
        XCTAssertTrue(RealInputMonitor.isHardware(sourcePID: 0))
        XCTAssertFalse(RealInputMonitor.isHardware(sourcePID: 95923), "synthetic events carry the poster's PID")
    }

    func testPreferencesRoundTrip() {
        let suite = "ljh.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)

        XCTAssertEqual(prefs.minIntervalMinutes, 90, "default gap is 1.5 to 3 hours")
        XCTAssertEqual(prefs.maxIntervalMinutes, 180)
        XCTAssertEqual(prefs.pause, .running)
        XCTAssertNil(prefs.schedule)

        let until = Date(timeIntervalSince1970: 2_000_000_000)
        prefs.pause = .paused(until: until)
        prefs.schedule = CaptureSchedule(targetActiveSeconds: 100, accumulatedActiveSeconds: 40)
        prefs.knownCameras = [KnownCamera(id: "a", name: "A", kind: .external, isEnabled: false)]

        let reloaded = Preferences(defaults: defaults)
        XCTAssertEqual(reloaded.pause, .paused(until: until))
        XCTAssertEqual(reloaded.schedule, CaptureSchedule(targetActiveSeconds: 100, accumulatedActiveSeconds: 40))
        XCTAssertEqual(reloaded.knownCameras.first?.isEnabled, false)
    }
}

import XCTest

@testable import LifeJustHappening

@MainActor
final class TimerManagerTests: XCTestCase {
    private var sut: TimerManager!

    override func setUp() {
        super.setUp()
        sut = TimerManager.shared
        sut.stop() // Reset state
    }

    override func tearDown() {
        sut.stop()
        sut = nil
        super.tearDown()
    }

    // MARK: - Start/Stop Tests

    func testInitialState() {
        XCTAssertFalse(sut.isRunning)
        XCTAssertFalse(sut.isPaused)
        XCTAssertNil(sut.nextCaptureTime)
    }

    func testStartSetsRunningState() {
        sut.start()

        XCTAssertTrue(sut.isRunning)
        XCTAssertFalse(sut.isPaused)
        XCTAssertNotNil(sut.nextCaptureTime)
    }

    func testStopClearsState() {
        sut.start()
        sut.stop()

        XCTAssertFalse(sut.isRunning)
        XCTAssertFalse(sut.isPaused)
        XCTAssertNil(sut.nextCaptureTime)
    }

    func testStartIsIdempotent() {
        sut.start()
        let firstCaptureTime = sut.nextCaptureTime
        sut.start() // Second call should be no-op

        XCTAssertEqual(sut.nextCaptureTime, firstCaptureTime)
    }

    // MARK: - Pause/Resume Tests

    func testPauseIndefinitely() {
        sut.start()
        sut.pause()

        XCTAssertTrue(sut.isRunning)
        XCTAssertTrue(sut.isPaused)
        XCTAssertNil(sut.pauseEndTime)
    }

    func testPauseWithDuration() {
        sut.start()
        sut.pause(duration: 1800) // 30 minutes

        XCTAssertTrue(sut.isPaused)
        XCTAssertNotNil(sut.pauseEndTime)

        // Pause end should be ~30 minutes from now
        if let endTime = sut.pauseEndTime {
            let expectedInterval: TimeInterval = 1800
            let tolerance: TimeInterval = 5
            XCTAssertEqual(
                endTime.timeIntervalSinceNow,
                expectedInterval,
                accuracy: tolerance
            )
        }
    }

    func testResumeFromPause() {
        sut.start()
        sut.pause()
        sut.resume()

        XCTAssertTrue(sut.isRunning)
        XCTAssertFalse(sut.isPaused)
    }

    func testPauseRequiresRunning() {
        sut.pause()
        XCTAssertFalse(sut.isPaused) // Should not pause if not running
    }

    func testResumeRequiresRunningAndPaused() {
        sut.resume()
        XCTAssertFalse(sut.isRunning) // Should not change state
    }

    // MARK: - Interval Tests

    func testDefaultIntervals() {
        // Defaults should be 45-60 from UserDefaults or hardcoded
        XCTAssertGreaterThan(sut.minIntervalMinutes, 0)
        XCTAssertGreaterThanOrEqual(sut.maxIntervalMinutes, sut.minIntervalMinutes)
    }

    func testMinIntervalClampedToMax() {
        sut.minIntervalMinutes = 200
        XCTAssertEqual(sut.minIntervalMinutes, sut.maxIntervalMinutes)
    }

    func testScheduledTimeWithinRange() {
        sut.start()

        guard let captureTime = sut.nextCaptureTime else {
            XCTFail("Expected next capture time to be set")
            return
        }

        let interval = captureTime.timeIntervalSinceNow
        let minSeconds = TimeInterval(sut.minIntervalMinutes * 60)
        let maxSeconds = TimeInterval(sut.maxIntervalMinutes * 60)

        // Allow 5 seconds of tolerance for test execution time
        XCTAssertGreaterThanOrEqual(interval, minSeconds - 5)
        XCTAssertLessThanOrEqual(interval, maxSeconds + 5)
    }

    // MARK: - Capture Trigger Tests

    func testOnCaptureTriggerIsWired() {
        var wasCalled = false

        sut.onCaptureTrigger = {
            wasCalled = true
        }

        // Verify the callback is set
        XCTAssertNotNil(sut.onCaptureTrigger)

        // Call it directly to verify wiring
        sut.onCaptureTrigger?()
        XCTAssertTrue(wasCalled)

        // Clean up
        sut.onCaptureTrigger = nil
    }

    // MARK: - Computed Properties Tests

    func testTimeUntilNextCapture() {
        XCTAssertNil(sut.timeUntilNextCapture)

        sut.start()
        XCTAssertNotNil(sut.timeUntilNextCapture)
        if let remaining = sut.timeUntilNextCapture {
            XCTAssertGreaterThan(remaining, 0)
        }
    }

    func testFormattedTimeUntilCapture() {
        XCTAssertEqual(sut.formattedTimeUntilCapture, "--:--")

        sut.start()
        XCTAssertNotEqual(sut.formattedTimeUntilCapture, "--:--")
    }
}

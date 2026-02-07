import XCTest

@testable import LifeJustHappening

@MainActor
final class SettingsManagerTests: XCTestCase {
    private var sut: SettingsManager!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SettingsManagerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        sut = SettingsManager(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        sut = nil
        super.tearDown()
    }

    // MARK: - Interval Tests

    func testDefaultIntervals() {
        // Defaults should be 45-60 minutes
        XCTAssertEqual(sut.minIntervalMinutes, 45)
        XCTAssertEqual(sut.maxIntervalMinutes, 60)
    }

    func testSetIntervalRangeRejectsInvalidRange() {
        let originalMin = sut.minIntervalMinutes
        let originalMax = sut.maxIntervalMinutes

        // Min > Max should be rejected
        sut.setIntervalRange(min: 100, max: 50)
        XCTAssertEqual(sut.minIntervalMinutes, originalMin)
        XCTAssertEqual(sut.maxIntervalMinutes, originalMax)
    }

    func testSetIntervalRangeAcceptsValidRange() {
        sut.setIntervalRange(min: 20, max: 90)
        XCTAssertEqual(sut.minIntervalMinutes, 20)
        XCTAssertEqual(sut.maxIntervalMinutes, 90)

        // Reset
        sut.setIntervalRange(min: 45, max: 60)
    }

    // MARK: - Capture Recording Tests

    func testRecordCaptureIncrementsTotalAndSetsDate() {
        let initialCount = sut.totalPhotosCaptured

        sut.recordCapture()

        XCTAssertEqual(sut.totalPhotosCaptured, initialCount + 1)
        XCTAssertNotNil(sut.lastCaptureDate)
    }

    // MARK: - Pause Tests

    func testPauseCaptureIndefinitely() {
        sut.pauseCapture()

        XCTAssertTrue(sut.isPaused)
        XCTAssertNil(sut.pauseEndTime)
    }

    func testPauseCaptureWithEndTime() {
        let endTime = Date().addingTimeInterval(3600)

        sut.pauseCapture(until: endTime)

        XCTAssertTrue(sut.isPaused)
        XCTAssertNotNil(sut.pauseEndTime)
    }

    func testResumeCapture() {
        sut.pauseCapture()
        XCTAssertTrue(sut.isPaused)

        sut.resumeCapture()
        XCTAssertFalse(sut.isPaused)
        XCTAssertNil(sut.pauseEndTime)
    }
}

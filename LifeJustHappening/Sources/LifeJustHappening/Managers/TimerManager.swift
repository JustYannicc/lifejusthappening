import AppKit
import Combine
import Foundation

/// Keys for UserDefaults persistence
private enum StorageKeys {
    static let isRunning = "TimerManager.isRunning"
    static let isPaused = "TimerManager.isPaused"
    static let pauseEndTime = "TimerManager.pauseEndTime"
    static let nextCaptureTime = "TimerManager.nextCaptureTime"
    static let minIntervalMinutes = "TimerManager.minIntervalMinutes"
    static let maxIntervalMinutes = "TimerManager.maxIntervalMinutes"
}

/// Manages random photo capture timing with proper sleep/wake handling.
///
/// This manager handles scheduling random captures within a configurable interval,
/// properly handles macOS sleep/wake cycles, and supports pause functionality.
@MainActor
final class TimerManager: ObservableObject {
    // MARK: - Singleton

    static let shared = TimerManager()

    // MARK: - Published Properties

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var isPaused: Bool = false
    @Published private(set) var pauseEndTime: Date?
    @Published private(set) var nextCaptureTime: Date?

    @Published var minIntervalMinutes: Int {
        didSet {
            UserDefaults.standard.set(minIntervalMinutes, forKey: StorageKeys.minIntervalMinutes)
            // Ensure min <= max
            if minIntervalMinutes > maxIntervalMinutes {
                maxIntervalMinutes = minIntervalMinutes
            }
        }
    }

    @Published var maxIntervalMinutes: Int {
        didSet {
            UserDefaults.standard.set(maxIntervalMinutes, forKey: StorageKeys.maxIntervalMinutes)
            // Ensure max >= min
            if maxIntervalMinutes < minIntervalMinutes {
                minIntervalMinutes = maxIntervalMinutes
            }
        }
    }

    // MARK: - Private Properties

    private var timerSource: DispatchSourceTimer?
    private var pauseTimerSource: DispatchSourceTimer?
    private var sleepTime: Date?
    private var cancellables = Set<AnyCancellable>()

    /// Callback to execute when a capture should be triggered
    var onCaptureTrigger: (() -> Void)?

    // MARK: - Initialization

    private init() {
        // Load persisted interval settings with defaults
        let savedMin = UserDefaults.standard.integer(forKey: StorageKeys.minIntervalMinutes)
        let savedMax = UserDefaults.standard.integer(forKey: StorageKeys.maxIntervalMinutes)

        self.minIntervalMinutes = savedMin > 0 ? savedMin : 45
        self.maxIntervalMinutes = savedMax > 0 ? savedMax : 60

        setupNotificationObservers()
        restoreState()
    }

    deinit {
        timerSource?.cancel()
        pauseTimerSource?.cancel()
    }

    // MARK: - Public Methods

    /// Starts the timer cycle, scheduling the first capture.
    func start() {
        guard !isRunning else { return }

        isRunning = true
        isPaused = false
        pauseEndTime = nil

        persistState()
        scheduleNextCapture()
    }

    /// Stops the timer completely.
    func stop() {
        isRunning = false
        isPaused = false
        pauseEndTime = nil
        nextCaptureTime = nil

        cancelTimer()
        cancelPauseTimer()
        persistState()
    }

    /// Pauses the timer.
    /// - Parameter duration: If provided, pause for this duration then auto-resume.
    ///                       If nil, pause indefinitely until manually resumed.
    func pause(duration: TimeInterval? = nil) {
        guard isRunning, !isPaused else { return }

        isPaused = true
        cancelTimer()

        if let duration {
            pauseEndTime = Date().addingTimeInterval(duration)
            schedulePauseEnd(after: duration)
        } else {
            pauseEndTime = nil
        }

        persistState()
    }

    /// Pauses the timer for a specific number of hours.
    /// - Parameter hours: Number of hours to pause for.
    func pause(forHours hours: Double) {
        pause(duration: hours * 3600)
    }

    /// Resumes from pause state.
    func resume() {
        guard isRunning, isPaused else { return }

        isPaused = false
        pauseEndTime = nil
        cancelPauseTimer()

        // Check if we missed a capture while paused
        if let scheduledTime = nextCaptureTime, scheduledTime <= Date() {
            triggerCapture()
        } else {
            // Schedule next capture from now
            scheduleNextCapture()
        }

        persistState()
    }

    /// Schedules the next capture with a random interval.
    func scheduleNextCapture() {
        cancelTimer()

        let minSeconds = TimeInterval(minIntervalMinutes * 60)
        let maxSeconds = TimeInterval(maxIntervalMinutes * 60)
        let randomInterval = TimeInterval.random(in: minSeconds...maxSeconds)

        let captureTime = Date().addingTimeInterval(randomInterval)
        nextCaptureTime = captureTime

        persistState()

        scheduleTimer(fireAt: captureTime)
    }

    /// Called when system wakes from sleep. Handles missed captures.
    func handleWakeFromSleep() {
        guard isRunning else { return }

        // Check if pause ended during sleep
        if isPaused, let endTime = pauseEndTime, endTime <= Date() {
            isPaused = false
            pauseEndTime = nil
            cancelPauseTimer()
        }

        guard !isPaused else {
            // Still paused, reschedule pause end timer if needed
            if let endTime = pauseEndTime {
                let remaining = endTime.timeIntervalSinceNow
                if remaining > 0 {
                    schedulePauseEnd(after: remaining)
                } else {
                    // Pause ended during sleep
                    resume()
                }
            }
            return
        }

        // Check if we missed a scheduled capture during sleep
        if let scheduledTime = nextCaptureTime, scheduledTime <= Date() {
            // Capture time has passed - trigger immediately
            triggerCapture()
        } else if let scheduledTime = nextCaptureTime {
            // Reschedule the timer for the remaining time
            scheduleTimer(fireAt: scheduledTime)
        } else {
            // No scheduled time, schedule a new one
            scheduleNextCapture()
        }
    }

    // MARK: - Private Methods

    private func setupNotificationObservers() {
        // Listen for sleep/wake notifications from AppDelegate
        NotificationCenter.default.publisher(for: .systemWillSleep)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleSleep()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .systemDidWake)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleWakeFromSleep()
            }
            .store(in: &cancellables)
    }

    private func handleSleep() {
        sleepTime = Date()
        // Cancel timers - they won't fire accurately during sleep anyway
        cancelTimer()
        cancelPauseTimer()
    }

    private func scheduleTimer(fireAt date: Date) {
        cancelTimer()

        let timerSource = DispatchSource.makeTimerSource(queue: .main)
        self.timerSource = timerSource

        let deadline = DispatchTime.now() + date.timeIntervalSinceNow

        timerSource.schedule(deadline: deadline)
        timerSource.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.timerFired()
            }
        }
        timerSource.resume()
    }

    private func cancelTimer() {
        timerSource?.cancel()
        timerSource = nil
    }

    private func schedulePauseEnd(after interval: TimeInterval) {
        cancelPauseTimer()

        let pauseTimer = DispatchSource.makeTimerSource(queue: .main)
        self.pauseTimerSource = pauseTimer

        let deadline = DispatchTime.now() + interval

        pauseTimer.schedule(deadline: deadline)
        pauseTimer.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.pauseTimerFired()
            }
        }
        pauseTimer.resume()
    }

    private func cancelPauseTimer() {
        pauseTimerSource?.cancel()
        pauseTimerSource = nil
    }

    private func timerFired() {
        guard isRunning, !isPaused else { return }
        triggerCapture()
    }

    private func pauseTimerFired() {
        guard isRunning, isPaused else { return }
        resume()
    }

    private func triggerCapture() {
        // Execute the capture callback
        onCaptureTrigger?()

        // Schedule the next capture
        scheduleNextCapture()
    }

    // MARK: - State Persistence

    private func persistState() {
        let defaults = UserDefaults.standard
        defaults.set(isRunning, forKey: StorageKeys.isRunning)
        defaults.set(isPaused, forKey: StorageKeys.isPaused)
        defaults.set(pauseEndTime, forKey: StorageKeys.pauseEndTime)
        defaults.set(nextCaptureTime, forKey: StorageKeys.nextCaptureTime)
    }

    private func restoreState() {
        let defaults = UserDefaults.standard

        let wasRunning = defaults.bool(forKey: StorageKeys.isRunning)
        let wasPaused = defaults.bool(forKey: StorageKeys.isPaused)
        let savedPauseEndTime = defaults.object(forKey: StorageKeys.pauseEndTime) as? Date
        let savedNextCaptureTime = defaults.object(forKey: StorageKeys.nextCaptureTime) as? Date

        guard wasRunning else { return }

        isRunning = true
        isPaused = wasPaused
        pauseEndTime = savedPauseEndTime
        nextCaptureTime = savedNextCaptureTime

        if wasPaused {
            if let endTime = savedPauseEndTime {
                if endTime <= Date() {
                    // Pause has ended, resume
                    resume()
                } else {
                    // Still paused, schedule end
                    schedulePauseEnd(after: endTime.timeIntervalSinceNow)
                }
            }
            // If indefinite pause, stay paused
        } else if let captureTime = savedNextCaptureTime {
            if captureTime <= Date() {
                // Missed capture while app was closed
                triggerCapture()
            } else {
                // Schedule for remaining time
                scheduleTimer(fireAt: captureTime)
            }
        } else {
            // No scheduled time, start fresh
            scheduleNextCapture()
        }
    }
}

// MARK: - Computed Properties

extension TimerManager {
    /// Time remaining until next capture, or nil if not scheduled.
    var timeUntilNextCapture: TimeInterval? {
        guard let next = nextCaptureTime else { return nil }
        return max(0, next.timeIntervalSinceNow)
    }

    /// Time remaining until pause ends, or nil if not paused or indefinite.
    var timeUntilPauseEnds: TimeInterval? {
        guard let endTime = pauseEndTime else { return nil }
        return max(0, endTime.timeIntervalSinceNow)
    }

    /// Formatted string showing time until next capture.
    var formattedTimeUntilCapture: String {
        guard let remaining = timeUntilNextCapture else { return "--:--" }
        return formatTimeInterval(remaining)
    }

    /// Formatted string showing time until pause ends.
    var formattedTimeUntilPauseEnds: String {
        guard let remaining = timeUntilPauseEnds else { return "Indefinite" }
        return formatTimeInterval(remaining)
    }

    private func formatTimeInterval(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        let seconds = Int(interval) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}

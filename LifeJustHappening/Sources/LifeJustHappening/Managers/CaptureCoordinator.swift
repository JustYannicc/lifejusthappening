import AppKit
import Combine

/// Coordinates the full capture pipeline: TimerManager -> CameraManager -> PhotoStorageManager.
///
/// This is the single source of truth for the capture flow. It owns the timer lifecycle,
/// triggers camera capture when the timer fires, and persists the resulting image.
/// Created by AppDelegate and passed to the UI via environment objects.
@MainActor
final class CaptureCoordinator: ObservableObject {
    // MARK: - Dependencies

    let timerManager: TimerManager
    let cameraManager: CameraManager
    let photoStorageManager: PhotoStorageManager
    let settingsManager: SettingsManager

    // MARK: - Published Properties

    @Published private(set) var lastCaptureDate: Date?
    @Published private(set) var lastError: Error?
    @Published private(set) var isCapturing: Bool = false

    // MARK: - Private Properties

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init() {
        self.timerManager = .shared
        self.cameraManager = CameraManager()
        self.photoStorageManager = .shared
        self.settingsManager = .shared

        wireCapturePipeline()
        syncSettingsToTimer()
    }

    // MARK: - Public Methods

    /// Starts the capture cycle. Call this from AppDelegate on launch.
    func start() {
        timerManager.start()
    }

    /// Stops the capture cycle.
    func stop() {
        timerManager.stop()
    }

    /// Triggers an immediate capture outside the normal timer schedule.
    func captureNow() {
        performCapture()
    }

    /// Pauses capture for an optional duration.
    func pause(duration: TimeInterval? = nil) {
        timerManager.pause(duration: duration)
        settingsManager.pauseCapture(until: duration.map { Date().addingTimeInterval($0) })
    }

    /// Resumes capture from a paused state.
    func resume() {
        timerManager.resume()
        settingsManager.resumeCapture()
    }

    // MARK: - Private Methods

    private func wireCapturePipeline() {
        timerManager.onCaptureTrigger = { [weak self] in
            self?.performCapture()
        }
    }

    private func syncSettingsToTimer() {
        // Sync interval settings from SettingsManager to TimerManager
        settingsManager.$minIntervalMinutes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.timerManager.minIntervalMinutes = value
            }
            .store(in: &cancellables)

        settingsManager.$maxIntervalMinutes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.timerManager.maxIntervalMinutes = value
            }
            .store(in: &cancellables)

        // Sync storage mode changes to PhotoStorageManager so captures
        // use the updated destination immediately (not only after restart).
        settingsManager.$storageMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.photoStorageManager.reloadStorageLocation()
            }
            .store(in: &cancellables)

        settingsManager.$customFolderBookmark
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.photoStorageManager.reloadStorageLocation()
            }
            .store(in: &cancellables)
    }

    private func performCapture() {
        guard !isCapturing else { return }

        isCapturing = true
        lastError = nil

        cameraManager.capturePhoto { [weak self] image in
            guard let self else { return }

            guard let image else {
                self.lastError = self.cameraManager.lastError ?? CameraError.noCameraAvailable
                self.isCapturing = false
                return
            }

            Task {
                do {
                    try await self.photoStorageManager.savePhoto(image: image)
                    self.settingsManager.recordCapture()
                    self.lastCaptureDate = Date()
                    self.lastError = nil
                } catch {
                    self.lastError = error
                }
                self.isCapturing = false
            }
        }
    }
}

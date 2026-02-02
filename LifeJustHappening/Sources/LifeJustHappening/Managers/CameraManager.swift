import AVFoundation
import AppKit
import Combine

// CameraDevice is defined in Models/CameraDevice.swift

/// Camera authorization status wrapper
enum CameraAuthorizationStatus {
    case authorized
    case denied
    case restricted
    case notDetermined

    init(from status: AVAuthorizationStatus) {
        switch status {
        case .authorized:
            self = .authorized
        case .denied:
            self = .denied
        case .restricted:
            self = .restricted
        case .notDetermined:
            self = .notDetermined
        @unknown default:
            self = .notDetermined
        }
    }
}

/// Manages camera discovery, monitoring, and photo capture using AVFoundation
@MainActor
final class CameraManager: NSObject, ObservableObject {
    // MARK: - Published Properties

    @Published private(set) var cameras: [CameraDevice] = []
    @Published private(set) var authorizationStatus: CameraAuthorizationStatus = .notDetermined
    @Published private(set) var isCapturing: Bool = false
    @Published private(set) var lastError: Error?

    // MARK: - Private Properties

    private var captureSession: AVCaptureSession?
    private var photoOutput: AVCapturePhotoOutput?
    private var deviceDiscoverySession: AVCaptureDevice.DiscoverySession?
    private var deviceObserver: NSKeyValueObservation?
    private var photoCaptureCompletion: ((NSImage?) -> Void)?

    /// Camera warmup time in seconds (allows auto-exposure/focus to stabilize)
    private let cameraWarmupTime: TimeInterval = 2.0

    // MARK: - Initialization

    override init() {
        super.init()
        setupDeviceDiscovery()
        updateAuthorizationStatus()
        refreshCameras()
    }

    deinit {
        deviceObserver?.invalidate()
        captureSession?.stopRunning()
        captureSession = nil
        photoOutput = nil
    }

    // MARK: - Public Methods

    /// Returns all available cameras sorted by priority
    func getAvailableCameras() -> [CameraDevice] {
        cameras.sorted { $0.priority < $1.priority }
    }

    /// Returns the highest priority enabled camera, or nil if none available
    func getPreferredCamera() -> CameraDevice? {
        cameras
            .filter { $0.isEnabled }
            .sorted { $0.priority < $1.priority }
            .first
    }

    /// Refreshes the list of available cameras
    func refreshCameras() {
        guard let discoverySession = deviceDiscoverySession else { return }

        let existingCameras = Dictionary(uniqueKeysWithValues: cameras.map { ($0.uniqueID, $0) })
        var newCameras: [CameraDevice] = []

        for (index, device) in discoverySession.devices.enumerated() {
            if let existing = existingCameras[device.uniqueID] {
                // Preserve user settings for existing cameras
                newCameras.append(existing)
            } else {
                // New camera discovered
                let camera = CameraDevice(from: device, priority: index + cameras.count)
                newCameras.append(camera)
            }
        }

        cameras = newCameras.sorted { $0.priority < $1.priority }
    }

    /// Captures a photo from the highest priority enabled camera
    /// - Parameter completion: Called with the captured image, or nil on failure
    func capturePhoto(completion: @escaping (NSImage?) -> Void) {
        guard authorizationStatus == .authorized else {
            lastError = CameraError.notAuthorized
            completion(nil)
            return
        }

        guard let camera = getPreferredCamera() else {
            lastError = CameraError.noCameraAvailable
            completion(nil)
            return
        }

        capturePhoto(from: camera.uniqueID, completion: completion)
    }

    /// Captures a photo from a specific camera
    /// - Parameters:
    ///   - cameraID: The unique ID of the camera to capture from
    ///   - completion: Called with the captured image, or nil on failure
    func capturePhoto(from cameraID: String, completion: @escaping (NSImage?) -> Void) {
        guard !isCapturing else {
            lastError = CameraError.captureInProgress
            completion(nil)
            return
        }

        guard let device = AVCaptureDevice(uniqueID: cameraID) else {
            lastError = CameraError.cameraNotFound
            completion(nil)
            return
        }

        isCapturing = true
        photoCaptureCompletion = completion
        lastError = nil

        Task {
            do {
                try await setupCaptureSession(with: device)
                try await warmupCamera()
                captureImage()
            } catch {
                await MainActor.run {
                    self.lastError = error
                    self.isCapturing = false
                    self.photoCaptureCompletion?(nil)
                    self.photoCaptureCompletion = nil
                    self.stopCaptureSession()
                }
            }
        }
    }

    /// Enables or disables a camera
    /// - Parameters:
    ///   - cameraID: The unique ID of the camera
    ///   - enabled: Whether the camera should be enabled
    func setCamera(_ cameraID: String, enabled: Bool) {
        guard let index = cameras.firstIndex(where: { $0.uniqueID == cameraID }) else { return }
        cameras[index].isEnabled = enabled
    }

    /// Sets the priority for a camera (lower = higher priority)
    /// - Parameters:
    ///   - cameraID: The unique ID of the camera
    ///   - priority: The new priority value
    func setCameraPriority(_ cameraID: String, priority: Int) {
        guard let index = cameras.firstIndex(where: { $0.uniqueID == cameraID }) else { return }
        cameras[index].priority = priority
        cameras.sort { $0.priority < $1.priority }
    }

    /// Moves a camera to a new position in the priority list
    /// - Parameters:
    ///   - cameraID: The unique ID of the camera to move
    ///   - newIndex: The new index position
    func moveCamera(_ cameraID: String, to newIndex: Int) {
        guard let currentIndex = cameras.firstIndex(where: { $0.uniqueID == cameraID }) else { return }

        let camera = cameras.remove(at: currentIndex)
        let insertIndex = min(max(0, newIndex), cameras.count)
        cameras.insert(camera, at: insertIndex)

        // Update priorities based on new positions
        for (index, _) in cameras.enumerated() {
            cameras[index].priority = index
        }
    }

    /// Requests camera authorization
    /// - Parameter completion: Called with the authorization result
    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            Task { @MainActor in
                self?.updateAuthorizationStatus()
                completion(granted)
            }
        }
    }

    /// Checks the current camera authorization status
    func checkAuthorizationStatus() -> CameraAuthorizationStatus {
        CameraAuthorizationStatus(from: AVCaptureDevice.authorizationStatus(for: .video))
    }

    // MARK: - Private Methods

    private func setupDeviceDiscovery() {
        // Discover all video capture devices
        var deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            deviceTypes.append(.external)
        } else {
            deviceTypes.append(.externalUnknown)
        }
        
        deviceDiscoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        )

        // Observe device changes
        deviceObserver = deviceDiscoverySession?.observe(\.devices, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.refreshCameras()
                NotificationCenter.default.post(name: .camerasDidChange, object: nil)
            }
        }
    }

    private func updateAuthorizationStatus() {
        authorizationStatus = checkAuthorizationStatus()
    }

    private func setupCaptureSession(with device: AVCaptureDevice) async throws {
        stopCaptureSession()

        let session = AVCaptureSession()
        session.sessionPreset = .photo

        // Add input
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CameraError.cannotAddInput
        }
        session.addInput(input)

        // Add output
        let output = AVCapturePhotoOutput()
        guard session.canAddOutput(output) else {
            throw CameraError.cannotAddOutput
        }
        session.addOutput(output)

        captureSession = session
        photoOutput = output

        // Start the session
        session.startRunning()
    }

    private func warmupCamera() async throws {
        // Wait for camera to warm up (auto-exposure, auto-focus)
        try await Task.sleep(nanoseconds: UInt64(cameraWarmupTime * 1_000_000_000))
    }

    private func captureImage() {
        guard let photoOutput else {
            lastError = CameraError.outputNotConfigured
            finishCapture(with: nil)
            return
        }

        let settings = AVCapturePhotoSettings()

        // Configure for best quality
        if photoOutput.availablePhotoCodecTypes.contains(.jpeg) {
            settings.flashMode = .off
        }

        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    private func finishCapture(with image: NSImage?) {
        isCapturing = false
        photoCaptureCompletion?(image)
        photoCaptureCompletion = nil
        stopCaptureSession()
    }

    private func stopCaptureSession() {
        captureSession?.stopRunning()
        captureSession = nil
        photoOutput = nil
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraManager: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        Task { @MainActor in
            if let error {
                self.lastError = error
                self.finishCapture(with: nil)
                return
            }

            guard let imageData = photo.fileDataRepresentation(),
                  let image = NSImage(data: imageData) else {
                self.lastError = CameraError.imageConversionFailed
                self.finishCapture(with: nil)
                return
            }

            self.finishCapture(with: image)
        }
    }
}

// MARK: - Error Types

enum CameraError: LocalizedError {
    case notAuthorized
    case noCameraAvailable
    case cameraNotFound
    case captureInProgress
    case cannotAddInput
    case cannotAddOutput
    case outputNotConfigured
    case imageConversionFailed

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Camera access not authorized"
        case .noCameraAvailable:
            return "No enabled camera available"
        case .cameraNotFound:
            return "Specified camera not found"
        case .captureInProgress:
            return "Another capture is already in progress"
        case .cannotAddInput:
            return "Cannot add camera input to capture session"
        case .cannotAddOutput:
            return "Cannot add photo output to capture session"
        case .outputNotConfigured:
            return "Photo output not configured"
        case .imageConversionFailed:
            return "Failed to convert captured data to image"
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let camerasDidChange = Notification.Name("camerasDidChange")
}

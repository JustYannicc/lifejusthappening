import AVFoundation
import CoreGraphics

struct CaptureOutcome {
    enum Result: Equatable {
        case captured(camera: String)
        case skipped(SkipReason)
    }

    enum SkipReason: Equatable {
        case noPermission
        case noUsableCamera(lidClosed: Bool)
        case nobodyThere
        case allCamerasFailed(String)

        var text: String {
            switch self {
            case .noPermission: return "No camera permission"
            case .noUsableCamera(let lidClosed):
                return lidClosed ? "Lid closed and no webcam" : "No enabled camera connected"
            case .nobodyThere: return "Nobody in front of the camera"
            case .allCamerasFailed(let reason): return "Every camera failed: \(reason)"
            }
        }
    }

    let date: Date
    let result: Result
    var thumbnail: CGImage?
}

/// Walks the priority list until a camera sees an actual person, then hands the JPEG
/// (with time, place and camera in its metadata) to the upload queue.
@MainActor
final class CapturePipeline {
    private let registry: CameraRegistry
    private let location: LocationProvider
    private let capturer = PhotoCapturer()
    private let queue: UploadQueue

    init(registry: CameraRegistry, location: LocationProvider, queue: UploadQueue) {
        self.registry = registry
        self.location = location
        self.queue = queue
    }

    /// - Parameter requirePerson: manual "take photo now" skips the presence check.
    func run(isLidClosed: Bool, requirePerson: Bool = true) async -> CaptureOutcome {
        let started = Date()
        registry.refresh()
        guard registry.authorization == .authorized else {
            return CaptureOutcome(date: started, result: .skipped(.noPermission))
        }

        let candidates = registry.candidates(isLidClosed: isLidClosed)
        guard !candidates.isEmpty else {
            return CaptureOutcome(date: started, result: .skipped(.noUsableCamera(lidClosed: isLidClosed)))
        }

        // Start the location lookup while the camera warms up.
        async let place = location.currentLocation()

        var lastFailure: CaptureOutcome.SkipReason?
        var sawNobody = false
        for camera in candidates {
            do {
                let image = try await capturer.capture(deviceID: camera.id)
                if PhotoEncoder.isBlank(image) {
                    lastFailure = .allCamerasFailed("\(camera.name) gave a black frame")
                    continue
                }
                if requirePerson, !PresenceDetector.containsPerson(image) {
                    sawNobody = true
                    continue
                }
                let date = Date()
                let metadata = PhotoMetadata(capturedAt: date, location: await place, cameraName: camera.name)
                guard let jpeg = PhotoEncoder.jpeg(image, metadata: metadata) else {
                    lastFailure = .allCamerasFailed("couldn't encode JPEG")
                    continue
                }
                try await queue.enqueue(jpeg, fileName: PhotoEncoder.fileName(for: date))
                return CaptureOutcome(date: date, result: .captured(camera: camera.name), thumbnail: PhotoEncoder.thumbnail(image))
            } catch {
                lastFailure = .allCamerasFailed("\(camera.name): \(error.localizedDescription)")
            }
        }
        _ = await place
        // A camera that worked but saw an empty room beats a broken one: that's "you're away".
        let reason = sawNobody ? .nobodyThere : (lastFailure ?? .allCamerasFailed("unknown"))
        return CaptureOutcome(date: started, result: .skipped(reason))
    }
}

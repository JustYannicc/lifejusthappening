import AVFoundation
import CoreGraphics

enum CaptureError: LocalizedError {
    case deviceMissing
    case cannotConfigure
    case noImage
    case timedOut

    var errorDescription: String? {
        switch self {
        case .deviceMissing: return "Camera went away"
        case .cannotConfigure: return "Camera refused the capture session"
        case .noImage: return "Camera returned no image"
        case .timedOut: return "Camera took too long"
        }
    }
}

/// One-shot still capture. Each call spins up its own session on a background queue,
/// lets auto-exposure settle, grabs a frame and tears everything down again, so the
/// camera light is only on for a few seconds.
final class PhotoCapturer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "lifejusthappening.capture")

    func capture(deviceID: String, warmup: TimeInterval = 2.5, timeout: TimeInterval = 15) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let shot = OneShot(continuation: continuation, queue: self.queue)
                shot.start(deviceID: deviceID, warmup: warmup, timeout: timeout)
            }
        }
    }
}

private final class OneShot: NSObject, AVCapturePhotoCaptureDelegate {
    private var continuation: CheckedContinuation<CGImage, Error>?
    private let queue: DispatchQueue
    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    /// Keeps the delegate alive until the capture resolves.
    private var retainSelf: OneShot?

    init(continuation: CheckedContinuation<CGImage, Error>, queue: DispatchQueue) {
        self.continuation = continuation
        self.queue = queue
    }

    func start(deviceID: String, warmup: TimeInterval, timeout: TimeInterval) {
        retainSelf = self
        guard let device = AVCaptureDevice(uniqueID: deviceID) else {
            return finish(.failure(CaptureError.deviceMissing))
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            session.sessionPreset = .photo
            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration()
                return finish(.failure(CaptureError.cannotConfigure))
            }
            session.addInput(input)
            session.addOutput(output)
            session.commitConfiguration()
        } catch {
            return finish(.failure(error))
        }

        session.startRunning()
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(.failure(CaptureError.timedOut))
        }
        queue.asyncAfter(deadline: .now() + warmup) { [weak self] in
            guard let self, self.continuation != nil else { return }
            self.output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        queue.async { [self] in
            if let error { return finish(.failure(error)) }
            guard let image = photo.cgImageRepresentation() else { return finish(.failure(CaptureError.noImage)) }
            finish(.success(image))
        }
    }

    private func finish(_ result: Result<CGImage, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        if session.isRunning { session.stopRunning() }
        continuation.resume(with: result)
        retainSelf = nil
    }
}

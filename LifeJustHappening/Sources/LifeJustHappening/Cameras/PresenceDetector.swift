import CoreGraphics
import Vision

/// "Is anyone actually there?" Runs on-device on the captured frame. Faces cover the normal
/// case; the upper-body detector catches you looking down at your phone or turned away.
enum PresenceDetector {
    static func containsPerson(_ image: CGImage) -> Bool {
        let faces = VNDetectFaceRectanglesRequest()
        let bodies = VNDetectHumanRectanglesRequest()
        bodies.upperBodyOnly = true
        do {
            try VNImageRequestHandler(cgImage: image).perform([faces, bodies])
        } catch {
            // If Vision itself breaks, don't throw away a photo over it.
            return true
        }
        return !(faces.results ?? []).isEmpty || !(bodies.results ?? []).isEmpty
    }
}

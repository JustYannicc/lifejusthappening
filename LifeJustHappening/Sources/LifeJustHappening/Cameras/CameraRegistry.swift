import AVFoundation
import Combine

/// Live view of connected cameras merged with the user's persisted priority list.
@MainActor
final class CameraRegistry: ObservableObject {
    @Published private(set) var cameras: [KnownCamera]
    @Published private(set) var connectedIDs: Set<String> = []
    @Published private(set) var authorization: AVAuthorizationStatus

    private let preferences: Preferences
    private let discovery: AVCaptureDevice.DiscoverySession
    private var observation: NSKeyValueObservation?

    init(preferences: Preferences) {
        self.preferences = preferences
        self.cameras = preferences.knownCameras
        self.authorization = AVCaptureDevice.authorizationStatus(for: .video)
        self.discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        observation = discovery.observe(\.devices) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        let discovered = discovery.devices.map { device in
            DiscoveredCamera(id: device.uniqueID, name: device.localizedName, kind: Self.kind(of: device))
        }
        connectedIDs = Set(discovered.map(\.id))
        update(CameraPriority.merge(known: cameras, discovered: discovered))
        authorization = AVCaptureDevice.authorizationStatus(for: .video)
    }

    func candidates(isLidClosed: Bool) -> [KnownCamera] {
        CameraPriority.candidates(known: cameras, connectedIDs: connectedIDs, isLidClosed: isLidClosed)
    }

    func unavailability(of camera: KnownCamera, isLidClosed: Bool) -> CameraUnavailability? {
        CameraPriority.unavailability(of: camera, connectedIDs: connectedIDs, isLidClosed: isLidClosed)
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var next = cameras
        next.move(fromOffsets: source, toOffset: destination)
        update(next)
    }

    func move(_ id: String, by offset: Int) {
        guard let index = cameras.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(0, index + offset), cameras.count - 1)
        guard target != index else { return }
        var next = cameras
        next.swapAt(index, target)
        update(next)
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        guard let index = cameras.firstIndex(where: { $0.id == id }) else { return }
        var next = cameras
        next[index].isEnabled = enabled
        update(next)
    }

    func forget(_ id: String) {
        update(cameras.filter { $0.id != id })
    }

    func requestAccess() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        authorization = AVCaptureDevice.authorizationStatus(for: .video)
        return granted
    }

    private func update(_ next: [KnownCamera]) {
        guard next != cameras else { return }
        cameras = next
        preferences.knownCameras = next
    }

    private static func kind(of device: AVCaptureDevice) -> CameraKind {
        switch device.deviceType {
        case .builtInWideAngleCamera: return .builtIn
        case .continuityCamera: return .continuity
        default: return .external
        }
    }
}

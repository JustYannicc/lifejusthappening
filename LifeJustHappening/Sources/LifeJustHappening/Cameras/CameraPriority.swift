import Foundation

enum CameraKind: String, Codable {
    case builtIn
    case external
    case continuity
}

/// A camera the user has seen at least once. Remembered while unplugged so the
/// priority order survives unplugging your webcam for the day.
struct KnownCamera: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var kind: CameraKind
    var isEnabled: Bool
}

struct DiscoveredCamera: Equatable {
    let id: String
    let name: String
    let kind: CameraKind
}

enum CameraUnavailability: Equatable {
    case disconnected
    case disabled
    case lidClosed
}

/// Pure priority rules. The list order *is* the priority: first usable camera wins.
enum CameraPriority {
    /// Adds newly seen cameras to the bottom of the list, so a webcam you plug in once at a
    /// friend's place never jumps ahead of your own order. Only the very first run seeds a
    /// sensible order (external above built-in). Continuity Camera starts disabled so your
    /// phone doesn't get picked just by being nearby.
    static func merge(known: [KnownCamera], discovered: [DiscoveredCamera]) -> [KnownCamera] {
        var result = known
        var fresh: [KnownCamera] = []
        for camera in discovered {
            if let index = result.firstIndex(where: { $0.id == camera.id }) {
                result[index].name = camera.name
                result[index].kind = camera.kind
            } else {
                fresh.append(KnownCamera(id: camera.id, name: camera.name, kind: camera.kind, isEnabled: camera.kind != .continuity))
            }
        }
        if known.isEmpty {
            let rank: [CameraKind: Int] = [.external: 0, .builtIn: 1, .continuity: 2]
            fresh = fresh.enumerated()
                .sorted { (rank[$0.element.kind]!, $0.offset) < (rank[$1.element.kind]!, $1.offset) }
                .map(\.element)
        }
        return result + fresh
    }

    static func unavailability(
        of camera: KnownCamera,
        connectedIDs: Set<String>,
        isLidClosed: Bool
    ) -> CameraUnavailability? {
        if !camera.isEnabled { return .disabled }
        if !connectedIDs.contains(camera.id) { return .disconnected }
        if camera.kind == .builtIn && isLidClosed { return .lidClosed }
        return nil
    }

    /// Cameras to try, best first. Empty means skip this capture.
    static func candidates(
        known: [KnownCamera],
        connectedIDs: Set<String>,
        isLidClosed: Bool
    ) -> [KnownCamera] {
        known.filter { unavailability(of: $0, connectedIDs: connectedIDs, isLidClosed: isLidClosed) == nil }
    }
}

import CoreLocation
import Foundation

/// One-shot location for the photo's GPS tags. Macs locate via Wi-Fi, which is plenty for
/// "which city/office was I in". Never blocks a capture for long: no fix means no GPS tag.
@MainActor
final class LocationProvider: NSObject, ObservableObject {
    @Published private(set) var authorization: CLAuthorizationStatus

    private let manager = CLLocationManager()
    private var waiters: [CheckedContinuation<CLLocation?, Never>] = []

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var isAuthorized: Bool {
        authorization == .authorizedAlways
    }

    func requestAccess() {
        manager.requestWhenInUseAuthorization()
    }

    func refreshAuthorization() {
        authorization = manager.authorizationStatus
    }

    func currentLocation(timeout: TimeInterval = 8) async -> CLLocation? {
        guard isAuthorized else { return nil }
        if let cached = manager.location, -cached.timestamp.timeIntervalSinceNow < 120 {
            return cached
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
            guard waiters.count == 1 else { return }
            manager.requestLocation()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.resolve(with: nil)
            }
        }
    }

    private func resolve(with location: CLLocation?) {
        // Fall back to a fix from the last hour rather than no location at all.
        let usable = location ?? manager.location.flatMap { -$0.timestamp.timeIntervalSinceNow < 3600 ? $0 : nil }
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: usable) }
    }
}

extension LocationProvider: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let latest = locations.last
        Task { @MainActor in self.resolve(with: latest) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.resolve(with: nil) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.refreshAuthorization() }
    }
}

import Foundation

/// Typed UserDefaults. Only state that has to outlive a launch lives here.
struct Preferences {
    static let intervalBounds = 10...480

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // Key names for min/max match the old app so existing settings carry over.
    var minIntervalMinutes: Int {
        get { defaults.object(forKey: "minIntervalMinutes") as? Int ?? 90 }
        nonmutating set { defaults.set(newValue, forKey: "minIntervalMinutes") }
    }

    var maxIntervalMinutes: Int {
        get { defaults.object(forKey: "maxIntervalMinutes") as? Int ?? 180 }
        nonmutating set { defaults.set(newValue, forKey: "maxIntervalMinutes") }
    }

    var schedule: CaptureSchedule? {
        get { decode("schedule.v2") }
        nonmutating set { encode(newValue, "schedule.v2") }
    }

    var pause: PauseState {
        get { decode("pause.v2") ?? .running }
        nonmutating set { encode(newValue, "pause.v2") }
    }

    var knownCameras: [KnownCamera] {
        get { decode("knownCameras.v2") ?? [] }
        nonmutating set { encode(newValue, "knownCameras.v2") }
    }

    var album: GooglePhotosAlbum? {
        get { decode("googlePhotosAlbum") }
        nonmutating set { encode(newValue, "googlePhotosAlbum") }
    }

    /// IDs (not photos) of the newest few uploads by capture date, for the home screen.
    var recentMedia: [RecentMedia] {
        get { decode("recentMedia") ?? [] }
        nonmutating set { encode(newValue, "recentMedia") }
    }

    var totalCaptured: Int {
        get { defaults.integer(forKey: "totalPhotosCaptured") }
        nonmutating set { defaults.set(newValue, forKey: "totalPhotosCaptured") }
    }

    var lastCaptureDate: Date? {
        get { defaults.object(forKey: "lastCaptureDate") as? Date }
        nonmutating set { defaults.set(newValue, forKey: "lastCaptureDate") }
    }

    private func decode<T: Decodable>(_ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func encode<T: Encodable>(_ value: T?, _ key: String) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }
}

struct RecentMedia: Codable, Equatable {
    let id: String
    let date: Date

    /// Keeps the newest `limit` by capture date, no duplicates.
    static func merge(_ existing: [RecentMedia], with new: [RecentMedia], limit: Int) -> [RecentMedia] {
        var seen = Set<String>()
        return (new + existing)
            .sorted { $0.date > $1.date }
            .filter { seen.insert($0.id).inserted }
            .prefix(limit)
            .map { $0 }
    }

    /// Capture date from our own upload names: ljh_yyyy-MM-dd_HH-mm-ss(-n).jpg
    static func date(fromFileName name: String, timeZone: TimeZone = .current) -> Date? {
        let stem = (name as NSString).deletingPathExtension
        guard stem.hasPrefix("ljh_"), stem.count >= 23 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.date(from: String(stem.dropFirst(4).prefix(19)))
    }
}

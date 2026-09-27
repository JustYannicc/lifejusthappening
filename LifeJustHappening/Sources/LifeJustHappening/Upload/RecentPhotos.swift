import AppKit

/// The last few photos for the home screen, fetched from Google Photos (nothing is kept
/// on disk), plus the album's real photo count.
@MainActor
final class RecentPhotos: ObservableObject {
    struct Thumbnail: Identifiable {
        let id: String
        let image: NSImage
        let date: Date?
    }

    static let count = 4
    static let minimumRefreshGap: TimeInterval = 60

    @Published private(set) var thumbnails: [Thumbnail] = []
    @Published private(set) var albumCount: Int?
    @Published private(set) var isLoading = false

    private let uploader: GooglePhotosUploader
    private let preferences: Preferences
    private var cache: [String: NSImage] = [:]
    private var lastRefresh: Date?

    init(uploader: GooglePhotosUploader, preferences: Preferences) {
        self.uploader = uploader
        self.preferences = preferences
    }

    /// Shows a fresh capture right away, before Google has it.
    func showLocal(_ image: CGImage, date: Date) {
        let local = Thumbnail(id: "local-\(date.timeIntervalSince1970)", image: NSImage(cgImage: image, size: .zero), date: date)
        thumbnails = Array(([local] + thumbnails).prefix(Self.count))
    }

    func refresh(force: Bool = false) {
        guard !isLoading else { return }
        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < Self.minimumRefreshGap { return }
        isLoading = true
        lastRefresh = Date()
        Task {
            defer { isLoading = false }
            async let count = try? uploader.albumCount()
            // Always merge in the newest captures from the last month, so the row shows the
            // newest photos by capture date, not just whatever this install happened to upload.
            if let found = try? await uploader.recentPhotos(limit: Self.count) {
                let seeded = found.compactMap { photo in photo.createdAt.map { RecentMedia(id: photo.id, date: $0) } }
                preferences.recentMedia = RecentMedia.merge(preferences.recentMedia, with: seeded, limit: Self.count)
            }
            let known = preferences.recentMedia
            guard let remote = try? await uploader.photos(ids: known.map(\.id)) else {
                albumCount = await count ?? albumCount
                return
            }
            // Deleted in Google Photos: forget it.
            if remote.count < known.count {
                preferences.recentMedia = known.filter { item in remote.contains { $0.id == item.id } }
            }
            var fresh: [Thumbnail] = []
            for photo in remote {
                if let image = await image(for: photo) {
                    fresh.append(Thumbnail(id: photo.id, image: image, date: photo.createdAt))
                }
            }
            cache = cache.filter { key, _ in remote.contains { $0.id == key } }
            thumbnails = fresh
            albumCount = await count ?? albumCount
        }
    }

    private func image(for photo: GooglePhotosUploader.RemotePhoto) async -> NSImage? {
        if let cached = cache[photo.id] { return cached }
        // Base URLs are unauthenticated for 60 min; =w..-h..-c asks Google for a cropped square.
        guard let url = URL(string: photo.baseURL.absoluteString + "=w240-h240-c"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let image = NSImage(data: data) else { return nil }
        cache[photo.id] = image
        return image
    }
}

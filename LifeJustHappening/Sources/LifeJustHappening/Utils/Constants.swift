import Foundation

/// Application-wide constants
enum Constants {
    // MARK: - App Info

    /// The display name of the application
    static let appName = "lifejusthappening"

    /// The bundle identifier (must match Info.plist)
    static let bundleID = "com.yanniccharlon.lifejusthappening"

    // MARK: - Capture Intervals

    /// Minimum allowed capture interval in minutes
    static let minimumIntervalMinutes = 15

    /// Maximum allowed capture interval in minutes
    static let maximumIntervalMinutes = 120

    /// Default minimum interval in minutes
    static let defaultMinIntervalMinutes = 45

    /// Default maximum interval in minutes
    static let defaultMaxIntervalMinutes = 60

    // MARK: - Photo Settings

    /// Default JPEG compression quality (0.0 - 1.0)
    static let defaultJPEGQuality: CGFloat = 0.85

    /// The name of the album in Photos app (new name)
    static let photosAlbumName = "lifejusthappening"

    /// Legacy album name for backward compatibility (reads from old album too)
    static let legacyPhotosAlbumName = "Life Just Happening"

    /// Default custom folder name inside ~/Documents
    static let defaultFolderName = "lifejusthappening"

    /// File name date format
    static let fileNameDateFormat = "yyyy-MM-dd_HH-mm-ss"

    // MARK: - Menu Bar

    /// SF Symbol names for menu bar icon states
    enum MenuBarIcons {
        static let active = "camera.fill"
        static let paused = "camera"
        static let error = "camera.badge.exclamationmark"
    }
}

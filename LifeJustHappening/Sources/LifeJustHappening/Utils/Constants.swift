import Foundation

/// Application-wide constants
enum Constants {
    // MARK: - App Info
    
    /// The display name of the application
    static let appName = "Life Just Happening"
    
    /// The bundle identifier
    static let bundleID = "ai.anomaly.LifeJustHappening"
    
    // MARK: - Capture Intervals
    
    /// Default capture interval in seconds (5 minutes)
    static let defaultCaptureInterval: TimeInterval = 300
    
    /// Minimum allowed capture interval in seconds (1 minute)
    static let minimumCaptureInterval: TimeInterval = 60
    
    /// Maximum allowed capture interval in seconds (60 minutes)
    static let maximumCaptureInterval: TimeInterval = 3600
    
    // MARK: - Pause Durations
    
    /// Preset pause durations in minutes
    static let pauseDurations: [Int] = [15, 30, 60, 120, 240]
    
    // MARK: - Photo Settings
    
    /// Default JPEG compression quality (0.0 - 1.0)
    static let defaultJPEGQuality: CGFloat = 0.85
    
    /// The name of the album in Photos app
    static let photosAlbumName = "Life Just Happening"
    
    /// File name date format
    static let fileNameDateFormat = "yyyy-MM-dd_HH-mm-ss"
    
    // MARK: - UserDefaults Keys
    
    enum UserDefaultsKeys {
        /// Capture interval in seconds
        static let captureInterval = "captureInterval"
        
        /// Storage location (encoded)
        static let storageLocation = "storageLocation"
        
        /// Custom folder bookmark data
        static let customFolderBookmark = "customFolderBookmark"
        
        /// Enabled camera IDs (array)
        static let enabledCameraIDs = "enabledCameraIDs"
        
        /// Camera priorities (dictionary)
        static let cameraPriorities = "cameraPriorities"
        
        /// Whether to launch at login
        static let launchAtLogin = "launchAtLogin"
        
        /// Whether to show capture notification
        static let showCaptureNotification = "showCaptureNotification"
        
        /// Current app state (encoded)
        static let appState = "appState"
        
        /// Whether onboarding has been completed
        static let onboardingCompleted = "onboardingCompleted"
        
        /// Total photos captured count
        static let totalPhotosCaptured = "totalPhotosCaptured"
        
        /// First capture date
        static let firstCaptureDate = "firstCaptureDate"
    }
    
    // MARK: - Notification Names
    
    enum Notifications {
        /// Posted when capture state changes
        static let captureStateChanged = Notification.Name("captureStateChanged")
        
        /// Posted when a photo is captured
        static let photoCaptured = Notification.Name("photoCaptured")
        
        /// Posted when camera list changes
        static let camerasChanged = Notification.Name("camerasChanged")
        
        /// Posted when settings are updated
        static let settingsChanged = Notification.Name("settingsChanged")
        
        /// Posted when the app should show preferences
        static let showPreferences = Notification.Name("showPreferences")
        
        /// Posted when the app should pause capture
        static let pauseCapture = Notification.Name("pauseCapture")
        
        /// Posted when the app should resume capture
        static let resumeCapture = Notification.Name("resumeCapture")
        
        /// Posted when permissions status changes
        static let permissionsChanged = Notification.Name("permissionsChanged")
    }
    
    // MARK: - Menu Bar
    
    /// SF Symbol names for menu bar icon states
    enum MenuBarIcons {
        static let active = "camera.fill"
        static let paused = "camera"
        static let error = "camera.badge.exclamationmark"
    }
}

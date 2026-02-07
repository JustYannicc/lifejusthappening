import Foundation
import SwiftUI
import Combine

/// Manages persistent app settings using UserDefaults
/// ObservableObject singleton for SwiftUI integration
@MainActor
final class SettingsManager: ObservableObject {
    
    // MARK: - Singleton
    
    static let shared = SettingsManager()
    
    // MARK: - UserDefaults Keys
    
    private enum Keys {
        static let minIntervalMinutes = "minIntervalMinutes"
        static let maxIntervalMinutes = "maxIntervalMinutes"
        static let storageMode = "storageMode"
        static let customFolderBookmark = "customFolderBookmark"
        static let customFolderPath = "customFolderPath"
        static let cameraPriorities = "cameraPriorities"
        static let disabledCameras = "disabledCameras"
        static let launchAtLogin = "launchAtLogin"
        static let lastCaptureDate = "lastCaptureDate"
        static let totalPhotosCaptured = "totalPhotosCaptured"
        static let isPaused = "isPaused"
        static let pauseEndTime = "pauseEndTime"
    }
    
    // MARK: - Default Values
    
    private enum Defaults {
        static let minIntervalMinutes = 45
        static let maxIntervalMinutes = 60
        static let storageMode = StorageMode.photosApp
        static let launchAtLogin = false
        static let totalPhotosCaptured = 0
        static let isPaused = false
    }
    
    // MARK: - Storage Mode Enum
    
    enum StorageMode: String, Codable, CaseIterable {
        case photosApp = "photosApp"
        case customFolder = "customFolder"
        
        var displayName: String {
            switch self {
            case .photosApp: return "Photos App"
            case .customFolder: return "Custom Folder"
            }
        }
    }
    
    // MARK: - UserDefaults Instance
    
    private let defaults: UserDefaults
    
    // MARK: - Published Properties
    
    @Published private(set) var minIntervalMinutes: Int {
        didSet { defaults.set(minIntervalMinutes, forKey: Keys.minIntervalMinutes) }
    }
    
    @Published private(set) var maxIntervalMinutes: Int {
        didSet { defaults.set(maxIntervalMinutes, forKey: Keys.maxIntervalMinutes) }
    }
    
    @Published private(set) var storageMode: StorageMode {
        didSet { defaults.set(storageMode.rawValue, forKey: Keys.storageMode) }
    }
    
    @Published private(set) var customFolderBookmark: Data? {
        didSet { defaults.set(customFolderBookmark, forKey: Keys.customFolderBookmark) }
    }
    
    @Published private(set) var cameraPriorities: [String: Int] {
        didSet { defaults.set(cameraPriorities, forKey: Keys.cameraPriorities) }
    }
    
    @Published private(set) var disabledCameras: [String] {
        didSet { defaults.set(disabledCameras, forKey: Keys.disabledCameras) }
    }
    
    @Published private(set) var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }
    
    @Published private(set) var lastCaptureDate: Date? {
        didSet { defaults.set(lastCaptureDate, forKey: Keys.lastCaptureDate) }
    }
    
    @Published private(set) var totalPhotosCaptured: Int {
        didSet { defaults.set(totalPhotosCaptured, forKey: Keys.totalPhotosCaptured) }
    }
    
    @Published private(set) var isPaused: Bool {
        didSet { defaults.set(isPaused, forKey: Keys.isPaused) }
    }
    
    @Published private(set) var pauseEndTime: Date? {
        didSet { defaults.set(pauseEndTime, forKey: Keys.pauseEndTime) }
    }
    
    // MARK: - Computed Properties
    
    /// Returns a random interval within the configured range
    var randomInterval: TimeInterval {
        let minSeconds = Double(minIntervalMinutes * 60)
        let maxSeconds = Double(maxIntervalMinutes * 60)
        return Double.random(in: minSeconds...maxSeconds)
    }
    
    /// Checks if pause has expired
    var isPauseExpired: Bool {
        guard isPaused, let endTime = pauseEndTime else { return false }
        return Date() >= endTime
    }
    
    /// Returns the effective paused state (considering expiration)
    var effectivelyPaused: Bool {
        isPaused && !isPauseExpired
    }
    
    /// Resolves the custom folder URL from the security-scoped bookmark,
    /// falling back to the stored path if the bookmark cannot be resolved
    /// (e.g. app is not codesigned / not sandboxed).
    var customFolderURL: URL? {
        // Try security-scoped bookmark first
        if let bookmark = customFolderBookmark {
            var isStale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: bookmark,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                
                if isStale {
                    refreshCustomFolderBookmark(from: url)
                }
                
                return url
            } catch {
                print("Failed to resolve bookmark, falling back to stored path: \(error)")
            }
        }
        
        // Fallback: use the stored path string directly
        if let path = defaults.string(forKey: Keys.customFolderPath) {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                return url
            }
        }
        
        return nil
    }
    
    // MARK: - Initialization
    
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        
        // Load values from UserDefaults
        self.minIntervalMinutes = defaults.object(forKey: Keys.minIntervalMinutes) as? Int ?? Defaults.minIntervalMinutes
        self.maxIntervalMinutes = defaults.object(forKey: Keys.maxIntervalMinutes) as? Int ?? Defaults.maxIntervalMinutes
        
        if let storageModeRaw = defaults.string(forKey: Keys.storageMode),
           let mode = StorageMode(rawValue: storageModeRaw) {
            self.storageMode = mode
        } else {
            self.storageMode = Defaults.storageMode
        }
        
        self.customFolderBookmark = defaults.data(forKey: Keys.customFolderBookmark)
        self.cameraPriorities = defaults.dictionary(forKey: Keys.cameraPriorities) as? [String: Int] ?? [:]
        self.disabledCameras = defaults.stringArray(forKey: Keys.disabledCameras) ?? []
        self.launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        self.lastCaptureDate = defaults.object(forKey: Keys.lastCaptureDate) as? Date
        self.totalPhotosCaptured = defaults.integer(forKey: Keys.totalPhotosCaptured)
        self.isPaused = defaults.bool(forKey: Keys.isPaused)
        self.pauseEndTime = defaults.object(forKey: Keys.pauseEndTime) as? Date
        
        // Check if pause has expired on launch
        if isPauseExpired {
            resumeCapture()
        }
    }
    
    // MARK: - Update Methods
    
    func setIntervalRange(min: Int, max: Int) {
        guard min > 0, max > 0, min <= max else {
            print("Invalid interval range: min=\(min), max=\(max)")
            return
        }
        minIntervalMinutes = min
        maxIntervalMinutes = max
    }
    
    func setStorageMode(_ mode: StorageMode) {
        storageMode = mode
    }
    
    func setCustomFolderBookmark(_ bookmark: Data?) {
        customFolderBookmark = bookmark
    }
    
    func setCustomFolder(url: URL) {
        // Always store the plain path as a fallback for non-sandboxed builds
        defaults.set(url.path, forKey: Keys.customFolderPath)
        
        // Try to create a security-scoped bookmark (works when properly codesigned)
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            customFolderBookmark = bookmark
        } catch {
            print("Security-scoped bookmark not available (expected if unsigned): \(error)")
            // The plain path fallback above will be used instead
        }
    }
    
    func setCameraPriority(cameraID: String, priority: Int) {
        var priorities = cameraPriorities
        priorities[cameraID] = priority
        cameraPriorities = priorities
    }
    
    func removeCameraPriority(cameraID: String) {
        var priorities = cameraPriorities
        priorities.removeValue(forKey: cameraID)
        cameraPriorities = priorities
    }
    
    func setDisabledCamera(cameraID: String, disabled: Bool) {
        var cameras = disabledCameras
        if disabled {
            if !cameras.contains(cameraID) {
                cameras.append(cameraID)
            }
        } else {
            cameras.removeAll { $0 == cameraID }
        }
        disabledCameras = cameras
    }
    
    func isCameraDisabled(_ cameraID: String) -> Bool {
        disabledCameras.contains(cameraID)
    }
    
    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLogin = enabled
    }
    
    func recordCapture() {
        lastCaptureDate = Date()
        totalPhotosCaptured += 1
    }
    
    func pauseCapture(until endTime: Date? = nil) {
        isPaused = true
        pauseEndTime = endTime
    }
    
    func resumeCapture() {
        isPaused = false
        pauseEndTime = nil
    }
    
    // MARK: - Reset
    
    func resetToDefaults() {
        minIntervalMinutes = Defaults.minIntervalMinutes
        maxIntervalMinutes = Defaults.maxIntervalMinutes
        storageMode = Defaults.storageMode
        customFolderBookmark = nil
        defaults.removeObject(forKey: Keys.customFolderPath)
        cameraPriorities = [:]
        disabledCameras = []
        launchAtLogin = Defaults.launchAtLogin
        lastCaptureDate = nil
        totalPhotosCaptured = Defaults.totalPhotosCaptured
        isPaused = Defaults.isPaused
        pauseEndTime = nil
    }
    
    // MARK: - Export/Import
    
    struct SettingsExport: Codable {
        let minIntervalMinutes: Int
        let maxIntervalMinutes: Int
        let storageMode: String
        let customFolderBookmark: Data?
        let cameraPriorities: [String: Int]
        let disabledCameras: [String]
        let launchAtLogin: Bool
        let lastCaptureDate: Date?
        let totalPhotosCaptured: Int
        let isPaused: Bool
        let pauseEndTime: Date?
        let exportDate: Date
        let appVersion: String
        
        @MainActor
        init(from manager: SettingsManager) {
            self.minIntervalMinutes = manager.minIntervalMinutes
            self.maxIntervalMinutes = manager.maxIntervalMinutes
            self.storageMode = manager.storageMode.rawValue
            self.customFolderBookmark = manager.customFolderBookmark
            self.cameraPriorities = manager.cameraPriorities
            self.disabledCameras = manager.disabledCameras
            self.launchAtLogin = manager.launchAtLogin
            self.lastCaptureDate = manager.lastCaptureDate
            self.totalPhotosCaptured = manager.totalPhotosCaptured
            self.isPaused = manager.isPaused
            self.pauseEndTime = manager.pauseEndTime
            self.exportDate = Date()
            self.appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        }
    }
    
    func exportSettings() -> Data? {
        let export = SettingsExport(from: self)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        
        do {
            return try encoder.encode(export)
        } catch {
            print("Failed to export settings: \(error)")
            return nil
        }
    }
    
    func exportSettingsToFile(url: URL) throws {
        guard let data = exportSettings() else {
            throw SettingsError.exportFailed
        }
        try data.write(to: url)
    }
    
    func importSettings(from data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        let imported = try decoder.decode(SettingsExport.self, from: data)
        
        minIntervalMinutes = imported.minIntervalMinutes
        maxIntervalMinutes = imported.maxIntervalMinutes
        
        if let mode = StorageMode(rawValue: imported.storageMode) {
            storageMode = mode
        }
        
        customFolderBookmark = imported.customFolderBookmark
        cameraPriorities = imported.cameraPriorities
        disabledCameras = imported.disabledCameras
        launchAtLogin = imported.launchAtLogin
        lastCaptureDate = imported.lastCaptureDate
        totalPhotosCaptured = imported.totalPhotosCaptured
        isPaused = imported.isPaused
        pauseEndTime = imported.pauseEndTime
    }
    
    func importSettingsFromFile(url: URL) throws {
        let data = try Data(contentsOf: url)
        try importSettings(from: data)
    }
    
    // MARK: - Errors
    
    enum SettingsError: LocalizedError {
        case exportFailed
        case importFailed(String)
        
        var errorDescription: String? {
            switch self {
            case .exportFailed:
                return "Failed to export settings"
            case .importFailed(let reason):
                return "Failed to import settings: \(reason)"
            }
        }
    }
    
    // MARK: - Private Helpers
    
    private func refreshCustomFolderBookmark(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        
        do {
            let newBookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            customFolderBookmark = newBookmark
        } catch {
            print("Failed to refresh stale bookmark: \(error)")
        }
    }
}

// MARK: - SwiftUI Bindings

extension SettingsManager {
    /// Creates a binding for minIntervalMinutes
    var minIntervalBinding: Binding<Int> {
        Binding(
            get: { self.minIntervalMinutes },
            set: { self.setIntervalRange(min: $0, max: self.maxIntervalMinutes) }
        )
    }
    
    /// Creates a binding for maxIntervalMinutes
    var maxIntervalBinding: Binding<Int> {
        Binding(
            get: { self.maxIntervalMinutes },
            set: { self.setIntervalRange(min: self.minIntervalMinutes, max: $0) }
        )
    }
    
    /// Creates a binding for storageMode
    var storageModeBinding: Binding<StorageMode> {
        Binding(
            get: { self.storageMode },
            set: { self.setStorageMode($0) }
        )
    }
    
    /// Creates a binding for launchAtLogin
    var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { self.launchAtLogin },
            set: { self.setLaunchAtLogin($0) }
        )
    }
    
    /// Creates a binding for isPaused
    var isPausedBinding: Binding<Bool> {
        Binding(
            get: { self.isPaused },
            set: { newValue in
                if newValue {
                    self.pauseCapture()
                } else {
                    self.resumeCapture()
                }
            }
        )
    }
}

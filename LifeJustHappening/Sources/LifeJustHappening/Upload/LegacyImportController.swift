import AppKit

/// UI-facing wrapper around `LegacyImporter`: folder choice, progress, and auto-resume
/// after offline spells or Google's daily quota.
@MainActor
final class LegacyImportController: ObservableObject {
    static let defaultFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/lifejusthappening", isDirectory: true)
    static let resumeInterval: TimeInterval = 5 * 60
    static let rateLimitResumeInterval: TimeInterval = 30 * 60

    @Published private(set) var progress: LegacyImporter.Progress?
    @Published private(set) var folder: URL?

    private let uploader: PhotoUploading
    private let ledgerURL: URL
    private let defaults: UserDefaults
    private var importer: LegacyImporter?
    private var lastAttempt: Date?

    init(uploader: PhotoUploading, supportDirectory: URL, defaults: UserDefaults = .standard) {
        self.uploader = uploader
        self.ledgerURL = supportDirectory.appendingPathComponent("legacy-import.json")
        self.defaults = defaults
        if let path = defaults.string(forKey: "legacyImportFolder") {
            use(folder: URL(fileURLWithPath: path, isDirectory: true))
        }
    }

    var isFinished: Bool {
        guard let progress else { return false }
        return progress.total > 0 && progress.remaining == 0
    }

    /// Asks for the folder. Picking it is the "yes, upload these" moment.
    func chooseFolderAndStart() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = Self.defaultFolder
        panel.message = "Pick the folder with your old lifejusthappening photos. They'll be uploaded to the album; the files stay where they are."
        panel.prompt = "Upload these"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        defaults.set(url.path, forKey: "legacyImportFolder")
        use(folder: url)
        start()
    }

    /// The user asked for the import and hasn't stopped it. Survives relaunches.
    private var wantsImport: Bool {
        get { defaults.bool(forKey: "legacyImportActive") }
        set { defaults.set(newValue, forKey: "legacyImportActive") }
    }

    func start() {
        guard let importer else { return }
        wantsImport = true
        lastAttempt = Date()
        Task {
            // The controller lives as long as the app; a strong capture is fine here.
            _ = await importer.run { progress in
                await MainActor.run { self.progress = progress }
            }
        }
    }

    func stop() {
        wantsImport = false
        guard let importer else { return }
        Task { await importer.stop() }
    }

    /// Called from the main loop: pick up after a relaunch right away, after a failure every
    /// 5 minutes, after Google's rate limit every half hour.
    func resumeIfNeeded(canUpload: Bool) {
        guard canUpload, wantsImport, let progress, !progress.isRunning, progress.remaining > 0 else { return }
        let wait = progress.failure == nil ? 0 : (progress.isRateLimited ? Self.rateLimitResumeInterval : Self.resumeInterval)
        guard Date().timeIntervalSince(lastAttempt ?? .distantPast) >= wait else { return }
        start()
    }

    private func use(folder: URL) {
        self.folder = folder
        let importer = LegacyImporter(folder: folder, ledgerURL: ledgerURL, uploader: uploader)
        self.importer = importer
        Task {
            let scanned = await importer.scan()
            self.progress = scanned
        }
    }
}

import AppKit
import Combine
import Network

/// Runs the loop: sample activity, credit active time, capture when due, push uploads.
@MainActor
final class CaptureCoordinator: ObservableObject {
    static let tickInterval: TimeInterval = 30
    static let uploadRetryInterval: TimeInterval = 5 * 60

    @Published private(set) var schedule: CaptureSchedule
    @Published private(set) var pause: PauseState
    @Published private(set) var activity: ActivitySnapshot
    @Published private(set) var isCapturing = false
    @Published private(set) var lastOutcome: CaptureOutcome?
    @Published private(set) var uploads = UploadQueue.Report()
    @Published private(set) var isUploading = false
    @Published private(set) var minMinutes: Int
    @Published private(set) var maxMinutes: Int
    @Published private(set) var totalCaptured: Int
    @Published private(set) var lastCaptureDate: Date?

    let cameras: CameraRegistry
    let location: LocationProvider
    let input: RealInputMonitor
    let account: GoogleAccount
    let queue: UploadQueue
    let uploader: GooglePhotosUploader
    let recent: RecentPhotos
    let legacyImport: LegacyImportController
    private let pipeline: CapturePipeline
    private let preferences: Preferences

    private var tracker = ActiveTimeTracker(maxCredit: CaptureCoordinator.tickInterval * 2)
    private var timer: Timer?
    private var lastDrainAttempt: Date?
    private var isOnline = true
    private var pathMonitor: NWPathMonitor?
    private var observers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()

    init(preferences: Preferences = Preferences(), credentials: CredentialStore? = nil, legacyKeychain: Keychain? = Keychain(service: "com.yanniccharlon.lifejusthappening")) {
        self.preferences = preferences
        let minMinutes = preferences.minIntervalMinutes
        let maxMinutes = preferences.maxIntervalMinutes
        self.minMinutes = minMinutes
        self.maxMinutes = maxMinutes
        let saved = preferences.schedule
        let range = TimeInterval(min(minMinutes, maxMinutes) * 60)...TimeInterval(max(minMinutes, maxMinutes) * 60)
        if let saved, range.contains(saved.targetActiveSeconds) {
            self.schedule = saved
        } else {
            // No schedule yet, or the range changed while we weren't running (e.g. new defaults).
            self.schedule = saved?.retargeted(minMinutes: minMinutes, maxMinutes: maxMinutes) ?? .fresh(minMinutes: minMinutes, maxMinutes: maxMinutes)
        }
        self.pause = preferences.pause.normalized(at: Date())
        let location = LocationProvider()
        let input = RealInputMonitor()
        self.location = location
        self.input = input
        self.activity = ActivityMonitor.sample(input: input)
        self.totalCaptured = preferences.totalCaptured
        self.lastCaptureDate = preferences.lastCaptureDate

        let cameras = CameraRegistry(preferences: preferences)
        let account = GoogleAccount(
            store: credentials ?? CredentialStore(fileURL: Self.supportDirectory.appendingPathComponent("google-credentials.json")),
            legacyKeychain: legacyKeychain
        )
        var uploader = GooglePhotosUploader(
            tokens: { force in try await account.validAccessToken(forceRefresh: force) },
            loadAlbum: { await MainActor.run { preferences.album } },
            saveAlbum: { album in await MainActor.run { preferences.album = album } }
        )
        uploader.didCreate = { created in
            let fresh = created.compactMap { item in
                RecentMedia.date(fromFileName: item.fileName).map { RecentMedia(id: item.id, date: $0) }
            }
            await MainActor.run {
                preferences.recentMedia = RecentMedia.merge(preferences.recentMedia, with: fresh, limit: RecentPhotos.count)
            }
        }
        let support = Self.supportDirectory
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let queue = UploadQueue(root: support, uploader: uploader)
        self.cameras = cameras
        self.account = account
        self.queue = queue
        self.uploader = uploader
        self.recent = RecentPhotos(uploader: uploader, preferences: preferences)
        self.legacyImport = LegacyImportController(uploader: uploader, supportDirectory: support, defaults: preferences.defaults)
        self.pipeline = CapturePipeline(registry: cameras, location: location, queue: queue)

        account.importDroppedClient(in: support)

        // Nested observable objects don't propagate changes on their own.
        for child in [cameras.objectWillChange, account.objectWillChange, location.objectWillChange, legacyImport.objectWillChange, recent.objectWillChange] {
            child.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        }
        account.$state.dropFirst().sink { [weak self] state in
            if case .signedIn = state { Task { await self?.drainUploads() } }
        }.store(in: &cancellables)
    }

    static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["LJH_SUPPORT_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lifejusthappening", isDirectory: true)
    }

    // MARK: - Lifecycle

    func start() {
        input.startIfPossible()
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tracker.reset() }
        })
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            })
        }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                self.isOnline = online
                if online, self.uploads.pending > 0 { await self.drainUploads() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "lifejusthappening.path"))
        pathMonitor = monitor

        tick()
        Task { await drainUploads() }
        if account.isSignedIn { recent.refresh(force: true) }
    }

    func stop() {
        timer?.invalidate()
        pathMonitor?.cancel()
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
        preferences.schedule = schedule
    }

    // MARK: - User actions

    /// Manual shots skip the "is anyone there" check: you pressed the button.
    func captureNow() {
        Task { await capture(requirePerson: false) }
    }

    /// Diagnostic: one scheduled-style capture through the real pipeline, no loop, no upload.
    func captureOnceForDiagnostics() async -> CaptureOutcome {
        await pipeline.run(isLidClosed: ActivityMonitor.isLidClosed())
    }

    func pause(for duration: TimeInterval?) {
        setPause(.paused(until: duration.map { Date().addingTimeInterval($0) }))
    }

    func pauseUntilTomorrow() {
        let morning = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 8), matchingPolicy: .nextTime)
        setPause(.paused(until: morning))
    }

    func resume() {
        setPause(.running)
    }

    func setInterval(min newMin: Int, max newMax: Int) {
        let lower = Swift.min(Swift.max(newMin, Preferences.intervalBounds.lowerBound), Preferences.intervalBounds.upperBound)
        let upper = Swift.min(Swift.max(newMax, lower), Preferences.intervalBounds.upperBound)
        guard lower != minMinutes || upper != maxMinutes else { return }
        minMinutes = lower
        maxMinutes = upper
        preferences.minIntervalMinutes = lower
        preferences.maxIntervalMinutes = upper
        updateSchedule(schedule.retargeted(minMinutes: lower, maxMinutes: upper))
    }

    func drainUploads() async {
        guard account.isSignedIn, !isUploading else {
            uploads = await queue.counts()
            return
        }
        isUploading = true
        lastDrainAttempt = Date()
        uploads = await queue.drain()
        isUploading = false
    }

    /// Call after the user grants a permission so it takes effect without a relaunch.
    func refreshPermissions() {
        input.startIfPossible()
        cameras.refresh()
        location.refreshAuthorization()
        tick()
    }

    // MARK: - State for the UI

    var isPaused: Bool { pause.isPaused(at: Date()) }

    var album: GooglePhotosAlbum? { preferences.album }

    /// Anything going up to Google right now, new captures or the old-photo import.
    var isUploadingAnything: Bool { isUploading || legacyImport.progress?.isRunning == true }

    /// Home screen appeared: refresh what's cheap and visible.
    func homeAppeared() {
        refreshPermissions()
        if account.isSignedIn { recent.refresh() }
    }

    /// False when no camera could take a photo right now (clamshell at the office, no webcam).
    var hasUsableCamera: Bool { !cameras.candidates(isLidClosed: activity.isLidClosed).isEmpty }

    // MARK: - Loop

    private func tick() {
        let now = Date()
        if pause != pause.normalized(at: now) { setPause(.running) }

        input.startIfPossible()
        if account.state == .needsClient { account.importDroppedClient(in: Self.supportDirectory) }
        activity = ActivityMonitor.sample(input: input)
        let credit = tracker.sample(at: now, isActive: activity.isActive && !isPaused)
        if credit > 0 {
            var next = schedule
            next.accrue(credit)
            updateSchedule(next)
        }

        if schedule.isDue, !isCapturing, !isPaused, activity.isActive {
            // Only ask Vision "is anyone there" when input can't prove it (stale or agent-driven).
            let requirePerson = !activity.humanProvablyPresent
            Task { await capture(requirePerson: requirePerson) }
        } else if uploads.pending > 0, !isUploading,
                  now.timeIntervalSince(lastDrainAttempt ?? .distantPast) >= Self.uploadRetryInterval {
            Task { await drainUploads() }
        }
        legacyImport.resumeIfNeeded(canUpload: isOnline && account.isSignedIn)
    }

    private func capture(requirePerson: Bool) async {
        guard !isCapturing else { return }
        isCapturing = true
        let outcome = await pipeline.run(isLidClosed: ActivityMonitor.isLidClosed(), requirePerson: requirePerson)
        isCapturing = false
        lastOutcome = outcome
        tracker.reset()

        switch outcome.result {
        case .skipped(.nobodyThere):
            // You stepped away: look again soon-ish instead of waiting a whole interval.
            var next = schedule
            next.deferAfterMiss()
            updateSchedule(next)
        case .skipped:
            // No camera, no permission, broken camera: skip this one, start a fresh interval.
            updateSchedule(.fresh(minMinutes: minMinutes, maxMinutes: maxMinutes))
        case .captured:
            updateSchedule(.fresh(minMinutes: minMinutes, maxMinutes: maxMinutes))
            totalCaptured += 1
            lastCaptureDate = outcome.date
            preferences.totalCaptured = totalCaptured
            preferences.lastCaptureDate = outcome.date
            if let thumbnail = outcome.thumbnail { recent.showLocal(thumbnail, date: outcome.date) }
            await drainUploads()
            if account.isSignedIn { recent.refresh(force: true) }
        }
    }

    private func setPause(_ state: PauseState) {
        pause = state
        preferences.pause = state
        tracker.reset()
        tick()
    }

    private func updateSchedule(_ next: CaptureSchedule) {
        schedule = next
        preferences.schedule = next
    }
}

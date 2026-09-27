import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let coordinator = CaptureCoordinator()
    private let settingsSelection = SettingsSelection()
    private var settingsWindow: NSWindow?
    private var feedbackWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        FeedbackReporter.start()
        if CommandLine.arguments.contains("--capture-once") {
            return runDiagnosticCapture()
        }
        if let index = CommandLine.arguments.firstIndex(of: "--send-test-feedback") {
            let message = CommandLine.arguments.dropFirst(index + 1).first ?? "test feedback from --send-test-feedback"
            let result = FeedbackReporter.send(message: message, tags: coordinator.feedbackTags, context: coordinator.feedbackContext)
            print("feedback: \(result)")
            exit(result == .notConfigured ? 1 : 0)
        }
        if CommandLine.arguments.contains("--check-google") {
            return runGoogleCheck()
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.action = #selector(togglePopover)
        item.button?.target = self
        statusItem = item

        popover.behavior = .transient
        popover.animates = true
        let home = NSHostingController(rootView: MenuContentView(
            coordinator: coordinator,
            openSettings: { [weak self] tab in self?.openSettings(tab) },
            openFeedback: { [weak self] in self?.openFeedback() }
        ))
        home.sizingOptions = .preferredContentSize
        popover.contentViewController = home

        coordinator.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)

        coordinator.start()
        updateIcon()

        // `--sign-in` jumps straight into the Google consent flow (used by setup automation).
        if CommandLine.arguments.contains("--sign-in") {
            Task { await coordinator.account.signIn() }
        }

        // First run (or something essential missing): go straight to the right settings tab.
        if coordinator.cameras.authorization != .authorized {
            openSettings(.permissions)
        } else if !coordinator.account.isSignedIn {
            openSettings(.googlePhotos)
        }
    }

    /// `LJH_SUPPORT_DIR=/tmp/x lifejusthappening --capture-once` takes one photo through the
    /// real camera priority logic, prints what happened, and quits. Handy for checking clamshell.
    private func runDiagnosticCapture() {
        Task {
            let activity = ActivityMonitor.sample(input: coordinator.input)
            print("lid closed: \(activity.isLidClosed), active: \(activity.isActive), human idle: \(Int(activity.secondsSinceHumanInput))s (verified: \(activity.humanInputVerified))")
            print("priority: \(coordinator.cameras.cameras.map { "\($0.name)[\($0.kind.rawValue)]" })")
            let outcome = await coordinator.captureOnceForDiagnostics()
            print("outcome: \(outcome.result)")
            print("outbox: \(await coordinator.queue.counts().pending) file(s) in \(CaptureCoordinator.supportDirectory.path)")
            exit(0)
        }
    }

    /// `lifejusthappening --check-google` proves the Google side works end to end (token
    /// refresh, API enabled, album found or created) without uploading anything.
    private func runGoogleCheck() {
        Task {
            print("account: \(coordinator.account.state)")
            do {
                _ = try await coordinator.account.validAccessToken(forceRefresh: true)
                print("token refresh: ok")
                let album = try await coordinator.uploader.ensureAlbum()
                print("album: \(album.title) \(album.productURL?.absoluteString ?? "")")
                print("album count: \(try await coordinator.uploader.albumCount().map(String.init) ?? "?")")
                let recentIDs = Preferences().recentMedia.map(\.id)
                print("remembered recent ids: \(recentIDs.count)")
                for photo in try await coordinator.uploader.photos(ids: recentIDs) + coordinator.uploader.recentPhotos(limit: 4) {
                    let thumb = URL(string: photo.baseURL.absoluteString + "=w240-h240-c")!
                    let (data, response) = try await URLSession.shared.data(from: thumb)
                    print("  recent: \(photo.createdAt.map { "\($0)" } ?? "?")  thumb HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0), \(data.count) bytes")
                }
                for item in try await coordinator.uploader.albumItems(limit: 3) {
                    let meta = item["mediaMetadata"] as? [String: Any] ?? [:]
                    let photo = meta["photo"] as? [String: Any] ?? [:]
                    print("  \(item["filename"] ?? "?")  taken \(meta["creationTime"] ?? "?")  \(meta["width"] ?? "?")x\(meta["height"] ?? "?")  camera: \(photo["cameraModel"] ?? "-")")
                }
                exit(0)
            } catch {
                print("failed: \(error.localizedDescription)")
                exit(1)
            }
        }
    }

    private func openFeedback() {
        popover.performClose(nil)
        if feedbackWindow == nil {
            let view = FeedbackView(
                send: { [weak self] message in
                    guard let self else { return .notConfigured }
                    return FeedbackReporter.send(message: message, tags: self.coordinator.feedbackTags, context: self.coordinator.feedbackContext)
                },
                close: { [weak self] in self?.feedbackWindow?.close() }
            )
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Send feedback"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            feedbackWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        feedbackWindow?.makeKeyAndOrderFront(nil)
    }

    private func openSettings(_ tab: SettingsTab) {
        popover.performClose(nil)
        settingsSelection.tab = tab
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsView(coordinator: coordinator, selection: settingsSelection)
            ))
            window.title = "lifejusthappening"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
    }

    @objc private func togglePopover() {
        popover.isShown ? popover.performClose(nil) : showPopover()
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        coordinator.cameras.refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let (symbol, tip) = iconState()
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        image?.isTemplate = true
        button.image = image
        button.toolTip = "lifejusthappening: \(tip)"
    }

    private func iconState() -> (String, String) {
        if coordinator.isCapturing { return ("camera.aperture", "Taking a photo") }
        if coordinator.isPaused { return ("pause.circle", "Paused") }
        if coordinator.cameras.authorization == .denied || coordinator.cameras.authorization == .restricted {
            return ("exclamationmark.triangle", "No camera permission")
        }
        if !coordinator.account.isSignedIn || coordinator.uploads.pending > 3 {
            return ("camera.badge.clock", "Photos waiting to upload")
        }
        if coordinator.isUploadingAnything { return ("icloud.and.arrow.up", "Uploading to Google Photos") }
        if !coordinator.activity.isActive { return ("camera", "Waiting") }
        if !coordinator.hasUsableCamera { return ("video.slash", "No camera available, skipping") }
        return ("camera.fill", "Running")
    }
}

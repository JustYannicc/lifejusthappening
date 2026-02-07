import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var firstLaunchWindow: NSWindow?

    // MARK: - Managers

    private let coordinator = CaptureCoordinator()
    private let launchAtLoginManager = LaunchAtLoginManager()

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPopover()
        setupNotificationObservers()
        coordinator.start()

        if launchAtLoginManager.isFirstLaunch {
            showFirstLaunchWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
        removeNotificationObservers()
    }

    // MARK: - Status Item Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem?.button else {
            return
        }

        button.image = NSImage(
            systemSymbolName: "camera.fill",
            accessibilityDescription: Constants.appName
        )
        if let image = button.image {
            image.isTemplate = true
        } else {
            button.title = "ljh"
        }
        button.toolTip = Constants.appName
        button.action = #selector(togglePopover)
        button.target = self
    }

    // MARK: - Popover Setup

    private func setupPopover() {
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 500)
        popover.behavior = .transient
        popover.animates = true

        let contentView = MenuContentView()
            .environmentObject(coordinator.cameraManager)
            .environmentObject(coordinator.timerManager)
            .environmentObject(coordinator.settingsManager)
            .environmentObject(coordinator)

        popover.contentViewController = NSHostingController(rootView: contentView)

        self.popover = popover
    }

    // MARK: - First Launch Window

    private func showFirstLaunchWindow() {
        let firstLaunchView = FirstLaunchView(launchAtLoginManager: launchAtLoginManager)
        let hostingController = NSHostingController(rootView: firstLaunchView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Welcome"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)

        // Bring app to front for the first launch window
        NSApplication.shared.activate(ignoringOtherApps: true)

        self.firstLaunchWindow = window

        // Observe window close to clean up
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(firstLaunchWindowDidClose),
            name: NSWindow.willCloseNotification,
            object: window
        )
    }

    @objc private func firstLaunchWindowDidClose(_ notification: Notification) {
        firstLaunchWindow = nil
        if launchAtLoginManager.isFirstLaunch {
            launchAtLoginManager.skipFirstLaunchSetup()
        }
    }

    // MARK: - Popover Toggle

    @objc private func togglePopover() {
        guard let popover, let button = statusItem?.button else {
            return
        }

        if popover.isShown {
            closePopover()
        } else {
            showPopover(relativeTo: button)
        }
    }

    private func showPopover(relativeTo button: NSStatusBarButton) {
        popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func closePopover() {
        popover?.performClose(nil)
    }

    // MARK: - Notification Observers (Sleep/Wake)

    private func setupNotificationObservers() {
        let notificationCenter = NSWorkspace.shared.notificationCenter

        notificationCenter.addObserver(
            self,
            selector: #selector(handleSleepNotification),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )

        notificationCenter.addObserver(
            self,
            selector: #selector(handleWakeNotification),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        notificationCenter.addObserver(
            self,
            selector: #selector(handleScreensDidSleepNotification),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )

        notificationCenter.addObserver(
            self,
            selector: #selector(handleScreensDidWakeNotification),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
    }

    private func removeNotificationObservers() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func handleSleepNotification(_ notification: Notification) {
        NotificationCenter.default.post(name: .systemWillSleep, object: nil)
    }

    @objc private func handleWakeNotification(_ notification: Notification) {
        NotificationCenter.default.post(name: .systemDidWake, object: nil)
    }

    @objc private func handleScreensDidSleepNotification(_ notification: Notification) {
        NotificationCenter.default.post(name: .screensDidSleep, object: nil)
    }

    @objc private func handleScreensDidWakeNotification(_ notification: Notification) {
        NotificationCenter.default.post(name: .screensDidWake, object: nil)
    }
}

// MARK: - Custom Notification Names

extension Notification.Name {
    static let systemWillSleep = Notification.Name("systemWillSleep")
    static let systemDidWake = Notification.Name("systemDidWake")
    static let screensDidSleep = Notification.Name("screensDidSleep")
    static let screensDidWake = Notification.Name("screensDidWake")
}

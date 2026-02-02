import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var eventMonitor: Any?

    // MARK: - Managers

    private let cameraManager = CameraManager()

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPopover()
        setupNotificationObservers()
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeNotificationObservers()
        removeEventMonitor()
    }

    // MARK: - Status Item Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem?.button else {
            return
        }

        button.image = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: "Life Just Happening")
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
            .environmentObject(cameraManager)

        popover.contentViewController = NSHostingController(rootView: contentView)

        self.popover = popover
    }

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
        setupEventMonitor()
    }

    private func closePopover() {
        popover?.performClose(nil)
        removeEventMonitor()
    }

    // MARK: - Event Monitor (Click Outside Detection)

    private func setupEventMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if self?.popover?.isShown == true {
                self?.closePopover()
            }
        }
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
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

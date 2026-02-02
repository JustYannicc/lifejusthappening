import SwiftUI

@main
struct LifeJustHappeningApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // Set app as accessory (menu bar only, no dock icon)
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        // Menu bar only app - no windows
        Settings {
            EmptyView()
        }
    }
}

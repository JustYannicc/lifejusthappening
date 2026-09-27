import ServiceManagement
import SwiftUI

enum SettingsTab: String, Hashable {
    case general, cameras, googlePhotos, permissions
}

@MainActor
final class SettingsSelection: ObservableObject {
    @Published var tab: SettingsTab = .general
}

struct SettingsView: View {
    @ObservedObject var coordinator: CaptureCoordinator
    @ObservedObject var selection: SettingsSelection

    var body: some View {
        TabView(selection: $selection.tab) {
            Form {
                Section("Timing") { IntervalControls(coordinator: coordinator) }
                Section { LaunchAtLoginToggle() }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }
            .tag(SettingsTab.general)

            Form {
                Section {
                    CameraListView(registry: coordinator.cameras, isLidClosed: coordinator.activity.isLidClosed)
                } footer: {
                    Text("Top to bottom, the first available camera takes the photo. New cameras show up at the bottom; move them up to prefer them. With the lid closed the built-in camera is skipped, and if nothing's left, that photo is skipped.")
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Cameras", systemImage: "web.camera") }
            .tag(SettingsTab.cameras)

            Form {
                GooglePhotosSection(coordinator: coordinator, account: coordinator.account)
            }
            .formStyle(.grouped)
            .tabItem { Label("Google Photos", systemImage: "photo.stack") }
            .tag(SettingsTab.googlePhotos)

            Form {
                PermissionsSection(coordinator: coordinator)
            }
            .formStyle(.grouped)
            .tabItem { Label("Permissions", systemImage: "lock.shield") }
            .tag(SettingsTab.permissions)
        }
        .frame(width: 480, height: 460)
        .onAppear { coordinator.refreshPermissions() }
    }
}

// MARK: - Interval

struct IntervalControls: View {
    @ObservedObject var coordinator: CaptureCoordinator

    var body: some View {
        let bounds = Preferences.intervalBounds
        Stepper(value: Binding(
            get: { coordinator.minMinutes },
            set: { coordinator.setInterval(min: $0, max: max($0, coordinator.maxMinutes)) }
        ), in: bounds, step: 5) {
            LabeledContent("At least", value: "\(coordinator.minMinutes) min")
        }
        Stepper(value: Binding(
            get: { coordinator.maxMinutes },
            set: { coordinator.setInterval(min: min($0, coordinator.minMinutes), max: $0) }
        ), in: bounds, step: 5) {
            LabeledContent("At most", value: "\(coordinator.maxMinutes) min")
        }
        Text("Random gap between photos, counted only while you're actually at the Mac: screen on, unlocked, and you touched the keyboard or mouse in the last 5 minutes. AI agents driving the Mac don't count.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Launch at login

struct LaunchAtLoginToggle: View {
    @State private var isEnabled = SMAppService.mainApp.status == .enabled
    @State private var error: String?

    var body: some View {
        Toggle("Open at login", isOn: Binding(get: { isEnabled }, set: set))
        if let error {
            Text(error)
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            error = nil
        } catch {
            self.error = "Couldn't change it: \(error.localizedDescription). Move the app to /Applications and try again."
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}

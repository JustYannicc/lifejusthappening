import AVFoundation
import CoreLocation
import SwiftUI

/// The macOS permissions the app uses, with their current state.
struct PermissionsSection: View {
    @ObservedObject var coordinator: CaptureCoordinator
    /// Permission state isn't observable, so re-check every couple of seconds while visible.
    @State private var recheck = 0
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Section {
            ForEach(steps) { step in SetupRow(step: step) }
                .id(recheck)
                .onReceive(timer) { _ in
                    coordinator.refreshPermissions()
                    recheck += 1
                }
        } footer: {
            Text("macOS remembers these across updates.")
        }
    }

    private var steps: [SetupStep] {
        let camera = coordinator.cameras.authorization
        let location = coordinator.location.authorization
        return [
            SetupStep(
                id: "camera",
                symbol: "camera",
                title: "Camera",
                detail: "Required. Nothing happens without it.",
                isDone: camera == .authorized,
                action: camera == .notDetermined
                    ? .button("Allow") { Task { _ = await coordinator.cameras.requestAccess() } }
                    : .button("Open Settings") { SystemSettings.open("Privacy_Camera") }
            ),
            SetupStep(
                id: "input",
                symbol: "keyboard",
                title: "Input Monitoring",
                detail: "Tells your typing apart from AI agents driving the Mac, so they don't run the clock while you're away. Only timestamps, never keys.",
                isDone: coordinator.input.hasAccess,
                action: .button("Allow") {
                    coordinator.input.requestAccess()
                    SystemSettings.open("Privacy_ListenEvent")
                }
            ),
            SetupStep(
                id: "location",
                symbol: "location",
                title: "Location",
                detail: "Puts each photo on the map in Google Photos.",
                isDone: coordinator.location.isAuthorized,
                action: location == .notDetermined
                    ? .button("Allow") { coordinator.location.requestAccess() }
                    : .button("Open Settings") { SystemSettings.open("Privacy_LocationServices") }
            ),
        ]
    }
}

private struct SetupStep: Identifiable {
    enum Action {
        case button(String, () -> Void)
    }

    let id: String
    let symbol: String
    let title: String
    let detail: String
    let isDone: Bool
    let action: Action?
}

private struct SetupRow: View {
    let step: SetupStep

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: step.isDone ? "checkmark.circle.fill" : step.symbol)
                .foregroundStyle(step.isDone ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                Text(step.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !step.isDone, case .button(let label, let perform) = step.action {
                Button(label, action: perform)
            }
        }
    }
}

enum SystemSettings {
    static func open(_ privacyAnchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(privacyAnchor)")!)
    }
}

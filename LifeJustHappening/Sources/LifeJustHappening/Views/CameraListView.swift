import SwiftUI

struct CameraListView: View {
    @ObservedObject var registry: CameraRegistry
    let isLidClosed: Bool

    var body: some View {
        if registry.cameras.isEmpty {
            Label("No cameras found", systemImage: "video.slash")
                .foregroundStyle(.secondary)
        } else {
            let nextID = registry.candidates(isLidClosed: isLidClosed).first?.id
            ForEach(Array(registry.cameras.enumerated()), id: \.element.id) { index, camera in
                CameraRow(
                    registry: registry,
                    camera: camera,
                    rank: index + 1,
                    isFirst: index == 0,
                    isLast: index == registry.cameras.count - 1,
                    isNext: camera.id == nextID,
                    unavailability: registry.unavailability(of: camera, isLidClosed: isLidClosed)
                )
            }
        }
    }
}

private struct CameraRow: View {
    @ObservedObject var registry: CameraRegistry
    let camera: KnownCamera
    let rank: Int
    let isFirst: Bool
    let isLast: Bool
    let isNext: Bool
    let unavailability: CameraUnavailability?

    var body: some View {
        HStack(spacing: 10) {
            Text("\(rank)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 12)

            Image(systemName: symbol)
                .foregroundStyle(unavailability == nil ? .primary : .tertiary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(camera.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(unavailability == nil ? .primary : .secondary)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(isNext ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            }

            Spacer(minLength: 4)

            VStack(spacing: 0) {
                Button { registry.move(camera.id, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(isFirst)
                    .help("Higher priority")
                Button { registry.move(camera.id, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(isLast)
                    .help("Lower priority")
            }
            .buttonStyle(.borderless)
            .font(.caption2.weight(.semibold))

            Toggle("Use \(camera.name)", isOn: Binding(
                get: { camera.isEnabled },
                set: { registry.setEnabled(camera.id, $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
        }
        .contextMenu {
            if unavailability == .disconnected {
                Button("Forget \(camera.name)") { registry.forget(camera.id) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(rank). \(camera.name), \(statusText)")
    }

    private var symbol: String {
        switch camera.kind {
        case .builtIn: return "laptopcomputer"
        case .external: return "web.camera"
        case .continuity: return "iphone.gen3"
        }
    }

    private var statusText: String {
        switch unavailability {
        case .disabled: return "Off"
        case .disconnected: return "Not connected · right-click to forget"
        case .lidClosed: return "Skipped, lid is closed"
        case nil: return isNext ? "Takes the next photo" : "Backup"
        }
    }
}

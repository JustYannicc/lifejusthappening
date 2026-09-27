import SwiftUI

/// The popover: the latest photo, what happens next, and two buttons. Everything
/// configurable lives in the Settings window.
struct MenuContentView: View {
    @ObservedObject var coordinator: CaptureCoordinator
    let openSettings: (SettingsTab) -> Void
    var openFeedback: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RecentStrip(coordinator: coordinator, recent: coordinator.recent)
            StatusView(coordinator: coordinator)
            ActionsRow(coordinator: coordinator)
            if let nudge = SetupNudge(coordinator: coordinator) {
                Button { openSettings(nudge.tab) } label: {
                    Label(nudge.text, systemImage: "exclamationmark.circle.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
                .font(.callout)
            }
            Divider()
            FooterRow(coordinator: coordinator, openSettings: openSettings, openFeedback: openFeedback)
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { coordinator.homeAppeared() }
    }
}

/// Only for things that stop the app from doing its job. Nice-to-haves stay in Settings.
private struct SetupNudge {
    let text: String
    let tab: SettingsTab

    @MainActor
    init?(coordinator: CaptureCoordinator) {
        if coordinator.cameras.authorization != .authorized {
            (text, tab) = ("Camera access needed", .permissions)
        } else if !coordinator.account.isSignedIn {
            (text, tab) = ("Google Photos isn't connected, photos are waiting", .googlePhotos)
        } else {
            return nil
        }
    }
}

// MARK: - Recent photos

private struct RecentStrip: View {
    @ObservedObject var coordinator: CaptureCoordinator
    @ObservedObject var recent: RecentPhotos

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let url = coordinator.album?.productURL {
                    Link(destination: url) {
                        HStack(spacing: 2) {
                            Text(recent.albumCount.map { "All \($0.formatted())" } ?? "See all")
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                        }
                        .font(.subheadline)
                    }
                    .help("Open the lifejusthappening album in Google Photos")
                }
            }
            HStack(spacing: 6) {
                ForEach(0..<RecentPhotos.count, id: \.self) { index in
                    tile(at: index)
                }
            }
        }
    }

    @ViewBuilder
    private func tile(at index: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        ZStack {
            shape.fill(.quaternary.opacity(0.6))
            if index == 0, coordinator.isCapturing {
                ProgressView().controlSize(.small)
            } else if index < recent.thumbnails.count {
                let thumb = recent.thumbnails[index]
                Image(nsImage: thumb.image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .help(thumb.date?.formatted(date: .abbreviated, time: .shortened) ?? "")
                    .accessibilityLabel("Photo from \(thumb.date?.formatted() ?? "unknown date")")
            } else if index == 0, !recent.isLoading {
                Image(systemName: "camera.aperture")
                    .foregroundStyle(.tertiary)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(shape)
    }
}

// MARK: - Status

private struct StatusView: View {
    @ObservedObject var coordinator: CaptureCoordinator

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { _ in
            VStack(alignment: .leading, spacing: 4) {
                Text(headline)
                    .font(.headline)
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var headline: String {
        if coordinator.isCapturing { return "Taking a photo…" }
        if case .paused(let until) = coordinator.pause {
            guard let until else { return "Paused" }
            return "Paused until \(until.formatted(date: Calendar.current.isDateInToday(until) ? .omitted : .abbreviated, time: .shortened))"
        }
        if let reason = coordinator.activity.inactiveReason { return "Waiting · \(reason.lowercased())" }
        if !coordinator.hasUsableCamera {
            return coordinator.activity.isLidClosed ? "Skipping · lid closed, no webcam" : "Skipping · no camera"
        }
        if coordinator.schedule.misses > 0 { return "Nobody there, looking again soon" }
        let minutes = max(1, Int((coordinator.schedule.remainingActiveSeconds / 60).rounded()))
        guard minutes >= 60 else { return "Next photo in about \(minutes) min" }
        let rest = (minutes % 60) / 5 * 5
        return "Next photo in about \(minutes / 60) h" + (rest > 0 ? " \(rest) min" : "")
    }

    private var detail: String? {
        guard let outcome = coordinator.lastOutcome else {
            return coordinator.lastCaptureDate.map { "Last photo \($0.formatted(.relative(presentation: .named)))" }
        }
        let ago = outcome.date.formatted(.relative(presentation: .named))
        switch outcome.result {
        case .captured(let camera): return "Last photo \(ago), \(camera)"
        case .skipped(.nobodyThere), .skipped(.noUsableCamera): return nil
        case .skipped(let reason): return "Skipped \(ago): \(reason.text)"
        }
    }
}

// MARK: - Actions

private struct ActionsRow: View {
    @ObservedObject var coordinator: CaptureCoordinator

    var body: some View {
        HStack(spacing: 8) {
            Button {
                coordinator.captureNow()
            } label: {
                Label("Take photo now", systemImage: "camera.fill")
                    .frame(maxWidth: .infinity)
            }
            .disabled(coordinator.isCapturing)

            if coordinator.isPaused {
                Button {
                    coordinator.resume()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Menu {
                    Button("For 30 minutes") { coordinator.pause(for: 30 * 60) }
                    Button("For 1 hour") { coordinator.pause(for: 60 * 60) }
                    Button("For 2 hours") { coordinator.pause(for: 2 * 60 * 60) }
                    Button("Until tomorrow morning") { coordinator.pauseUntilTomorrow() }
                    Divider()
                    Button("Until I resume") { coordinator.pause(for: nil) }
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}

// MARK: - Footer

private struct FooterRow: View {
    @ObservedObject var coordinator: CaptureCoordinator
    let openSettings: (SettingsTab) -> Void
    let openFeedback: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            uploadStatus
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button("Settings…") { openSettings(.general) }
                    .keyboardShortcut(",")
                if let url = coordinator.album?.productURL {
                    Link("Open album in Google Photos", destination: url)
                }
                Button("Send feedback…", action: openFeedback)
                Divider()
                Button("Quit lifejusthappening") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Settings and more")
        }
    }

    @ViewBuilder
    private var uploadStatus: some View {
        let import_ = coordinator.legacyImport.progress
        if let import_, import_.isRunning {
            VStack(alignment: .leading, spacing: 4) {
                Label("Uploading old photos · \(import_.done.formatted()) of \(import_.total.formatted())", systemImage: "icloud.and.arrow.up")
                ProgressView(value: Double(import_.done + import_.rejected), total: Double(max(1, import_.total)))
                    .controlSize(.small)
            }
        } else if !coordinator.account.isSignedIn {
            Label(coordinator.uploads.pending > 0 ? "\(coordinator.uploads.pending) waiting, Google not connected" : "Google Photos not connected",
                  systemImage: "icloud.slash")
        } else if coordinator.isUploading {
            Label("Uploading…", systemImage: "icloud.and.arrow.up")
        } else if coordinator.uploads.pending > 0 {
            Label("\(coordinator.uploads.pending) waiting to upload", systemImage: "arrow.up.circle")
        } else if let import_, import_.remaining > 0, import_.failure != nil {
            Label(import_.isRateLimited
                  ? "Old photos: \(import_.done.formatted()) of \(import_.total.formatted()), Google's limit, retrying in 30 min"
                  : "Old photos: \(import_.done.formatted()) of \(import_.total.formatted()), retrying shortly",
                  systemImage: "clock.arrow.circlepath")
                .help(import_.failure ?? "")
        } else {
            let count = coordinator.recent.albumCount ?? coordinator.totalCaptured
            Label("\(count.formatted()) photos in the album", systemImage: "checkmark.icloud")
        }
    }
}

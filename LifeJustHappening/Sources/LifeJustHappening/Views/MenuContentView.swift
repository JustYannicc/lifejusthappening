import ServiceManagement
import SwiftUI

// MARK: - Storage Type

enum StorageType: String, CaseIterable {
    case photosApp = "Photos App"
    case customFolder = "Custom Folder"
}

// MARK: - Pause State

enum PauseState: Equatable {
    case active
    case pausedIndefinitely
    case pausedUntil(Date)

    var isActive: Bool {
        if case .active = self { return true }
        return false
    }
}

// MARK: - Main Menu Content View

struct MenuContentView: View {
    // MARK: - Environment

    @EnvironmentObject private var cameraManager: CameraManager

    // MARK: - State

    @State private var pauseState: PauseState = .active
    @State private var nextCaptureTime: Date = Date().addingTimeInterval(45 * 60)
    @State private var totalPhotosCaptured: Int = 0

    @State private var minInterval: Double = 45
    @State private var maxInterval: Double = 60

    @State private var storageType: StorageType = .photosApp
    @State private var customFolderPath: String = "~/Pictures/LifeJustHappening"

    @State private var launchAtLogin: Bool = false

    @State private var selectedYear: Int = Calendar.current.component(.year, from: Date())
    @State private var availableYears: [Int] = [2024, 2025, 2026]
    @State private var isGeneratingWrapped: Bool = false
    @State private var wrappedProgress: Double = 0

    // Collapsible section states
    @State private var isTimerExpanded: Bool = false
    @State private var isStorageExpanded: Bool = false
    @State private var isCameraExpanded: Bool = false
    @State private var isWrappedExpanded: Bool = false
    @State private var isAppSettingsExpanded: Bool = false

    // Pause duration picker
    @State private var showPauseDurationPicker: Bool = false
    @State private var pauseDurationMinutes: Int = 30

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusSection
                Divider()
                quickActionsSection
                Divider()
                timerSettingsSection
                Divider()
                storageSettingsSection
                Divider()
                cameraSettingsSection
                Divider()
                wrappedSection
                Divider()
                appSettingsSection
            }
            .padding(16)
        }
        .frame(width: 320)
        .frame(maxHeight: 500)
    }

    // MARK: - Status Section

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Status", systemImage: "info.circle")

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Current:")
                        .foregroundStyle(.secondary)
                    Spacer()
                    statusBadge
                }

                HStack {
                    Text("Next capture:")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(nextCaptureText)
                        .fontWeight(.medium)
                }

                HStack {
                    Text("Photos captured:")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(totalPhotosCaptured)")
                        .fontWeight(.medium)
                }
            }
            .font(.system(.body, design: .rounded))
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch pauseState {
        case .active:
            Label("Active", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .fontWeight(.medium)
        case .pausedIndefinitely:
            Label("Paused", systemImage: "pause.circle.fill")
                .foregroundStyle(.orange)
                .fontWeight(.medium)
        case .pausedUntil(let date):
            Label("Paused until \(date.formatted(date: .omitted, time: .shortened))", systemImage: "pause.circle.fill")
                .foregroundStyle(.orange)
                .fontWeight(.medium)
        }
    }

    private var nextCaptureText: String {
        guard pauseState.isActive else {
            return "—"
        }

        let now = Date()
        let interval = nextCaptureTime.timeIntervalSince(now)

        if interval <= 0 {
            return "any moment"
        }

        let minutes = Int(interval / 60)
        if minutes < 60 {
            return "in \(minutes) min"
        }

        return nextCaptureTime.formatted(date: .omitted, time: .shortened)
    }

    // MARK: - Quick Actions Section

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Quick Actions", systemImage: "bolt.fill")

            HStack(spacing: 10) {
                if pauseState.isActive {
                    Button {
                        showPauseDurationPicker.toggle()
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    if showPauseDurationPicker {
                        Picker("", selection: $pauseDurationMinutes) {
                            Text("30m").tag(30)
                            Text("1h").tag(60)
                            Text("2h").tag(120)
                            Text("\u{221E}").tag(0)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 140)
                        .onChange(of: pauseDurationMinutes) { newValue in
                            if newValue == 0 {
                                pauseState = .pausedIndefinitely
                            } else {
                                pauseState = .pausedUntil(Date().addingTimeInterval(Double(newValue) * 60))
                            }
                            showPauseDurationPicker = false
                        }
                    }
                } else {
                    Button {
                        pauseState = .active
                        showPauseDurationPicker = false
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Button {
                takePhotoNow()
            } label: {
                Label("Take Photo Now", systemImage: "camera.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Timer Settings Section

    private var timerSettingsSection: some View {
        DisclosureGroup(isExpanded: $isTimerExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Min interval")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(minInterval)) min")
                            .monospacedDigit()
                    }
                    .font(.caption)

                    Slider(value: $minInterval, in: 15...120, step: 5) { _ in
                        if minInterval > maxInterval {
                            maxInterval = minInterval
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Max interval")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(maxInterval)) min")
                            .monospacedDigit()
                    }
                    .font(.caption)

                    Slider(value: $maxInterval, in: minInterval...120, step: 5)
                }

                HStack {
                    Spacer()
                    Text("Range: \(Int(minInterval))-\(Int(maxInterval)) minutes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                    Spacer()
                }
            }
            .padding(.top, 8)
        } label: {
            SectionHeader(title: "Timer Settings", systemImage: "timer")
        }
    }

    // MARK: - Storage Settings Section

    private var storageSettingsSection: some View {
        DisclosureGroup(isExpanded: $isStorageExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Storage", selection: $storageType) {
                    ForEach(StorageType.allCases, id: \.self) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.segmented)

                if storageType == .customFolder {
                    HStack {
                        Text(customFolderPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        Button("Change") {
                            selectCustomFolder()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            SectionHeader(title: "Storage", systemImage: "folder.fill")
        }
    }

    // MARK: - Camera Settings Section

    private var cameraSettingsSection: some View {
        DisclosureGroup(isExpanded: $isCameraExpanded) {
            WebcamPriorityView()
                .padding(.top, 8)
        } label: {
            SectionHeader(title: "Camera", systemImage: "camera")
        }
    }

    // MARK: - Wrapped Section

    private var wrappedSection: some View {
        DisclosureGroup(isExpanded: $isWrappedExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Year", selection: $selectedYear) {
                    ForEach(availableYears, id: \.self) { year in
                        Text(String(year)).tag(year)
                    }
                }
                .pickerStyle(.segmented)

                if isGeneratingWrapped {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: wrappedProgress, total: 1.0) {
                            Text("Generating Wrapped...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .progressViewStyle(.linear)

                        Text("\(Int(wrappedProgress * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        generateWrapped()
                    } label: {
                        Label("Generate Wrapped", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.top, 8)
        } label: {
            SectionHeader(title: "Wrapped", systemImage: "sparkles.rectangle.stack")
        }
    }

    // MARK: - App Settings Section

    private var appSettingsSection: some View {
        DisclosureGroup(isExpanded: $isAppSettingsExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        setLaunchAtLogin(newValue)
                    }

                Divider()

                Button(role: .destructive) {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 8)
        } label: {
            SectionHeader(title: "App Settings", systemImage: "gear")
        }
    }

    // MARK: - Actions

    private func takePhotoNow() {
        // Trigger immediate photo capture
        // This would typically call into a capture manager
    }

    private func selectCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder to save photos"

        if panel.runModal() == .OK, let url = panel.url {
            customFolderPath = url.path
        }
    }

    private func generateWrapped() {
        isGeneratingWrapped = true
        wrappedProgress = 0

        // Simulate wrapped generation
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            DispatchQueue.main.async {
                wrappedProgress += 0.05
                if wrappedProgress >= 1.0 {
                    timer.invalidate()
                    isGeneratingWrapped = false
                }
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Handle error silently or log
        }
    }
}

// MARK: - Section Header

struct SectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .foregroundStyle(.primary)
    }
}

// MARK: - Webcam Priority View

struct WebcamPriorityView: View {
    @EnvironmentObject private var cameraManager: CameraManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if cameraManager.cameras.isEmpty {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("No cameras detected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Drag to reorder priority")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(cameraManager.cameras) { camera in
                    CameraRow(camera: camera)
                }
            }

            if cameraManager.authorizationStatus != .authorized {
                HStack {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.red)
                    Text("Camera access required")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Grant") {
                        cameraManager.requestAuthorization { _ in }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.top, 4)
            }
        }
    }
}

// MARK: - Camera Row

struct CameraRow: View {
    let camera: CameraDevice

    @EnvironmentObject private var cameraManager: CameraManager
    @State private var isEnabled: Bool = true

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .font(.caption)

            Image(systemName: camera.isBuiltIn ? "laptopcomputer" : "video.fill")
                .foregroundStyle(.secondary)
                .frame(width: 20)

            Text(camera.localizedName)
                .font(.caption)
                .lineLimit(1)

            Spacer()

            Toggle("", isOn: $isEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .onChange(of: isEnabled) { newValue in
                    cameraManager.setCamera(camera.uniqueID, enabled: newValue)
                }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        .onAppear {
            isEnabled = camera.isEnabled
        }
    }
}

// MARK: - Preview

#Preview {
    MenuContentView()
        .environmentObject(CameraManager())
}

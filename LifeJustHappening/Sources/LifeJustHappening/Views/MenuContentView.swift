import ServiceManagement
import SwiftUI

// MARK: - Main Menu Content View

struct MenuContentView: View {
    // MARK: - Environment

    @EnvironmentObject private var cameraManager: CameraManager
    @EnvironmentObject private var timerManager: TimerManager
    @EnvironmentObject private var settingsManager: SettingsManager
    @EnvironmentObject private var coordinator: CaptureCoordinator

    // MARK: - Local UI State

    @State private var isTimerExpanded: Bool = false
    @State private var isStorageExpanded: Bool = false
    @State private var isCameraExpanded: Bool = false
    @State private var isWrappedExpanded: Bool = false
    @State private var isAppSettingsExpanded: Bool = false

    @State private var showPauseDurationPicker: Bool = false
    @State private var pauseDurationMinutes: Int = 30

    @StateObject private var wrappedManager = WrappedManager.shared

    @State private var selectedYear: Int = Calendar.current.component(.year, from: Date())
    @State private var wrappedProgress: Double = 0
    @State private var isGeneratingWrapped: Bool = false

    @State private var recentPhotos: [PhotoStorageManager.RecentPhoto] = []

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
                    Text("Last capture:")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(lastCaptureText)
                        .fontWeight(.medium)
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
                    Text("\(settingsManager.totalPhotosCaptured)")
                        .fontWeight(.medium)
                }
            }
            .font(.system(.body, design: .rounded))
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if !timerManager.isRunning {
            Label("Stopped", systemImage: "stop.circle.fill")
                .foregroundStyle(.gray)
                .fontWeight(.medium)
        } else if timerManager.isPaused {
            if let endTime = timerManager.pauseEndTime {
                Label(
                    "Paused until \(endTime.formatted(date: .omitted, time: .shortened))",
                    systemImage: "pause.circle.fill"
                )
                .foregroundStyle(.orange)
                .fontWeight(.medium)
            } else {
                Label("Paused", systemImage: "pause.circle.fill")
                    .foregroundStyle(.orange)
                    .fontWeight(.medium)
            }
        } else {
            Label("Active", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .fontWeight(.medium)
        }
    }

    private var lastCaptureText: String {
        guard let lastDate = settingsManager.lastCaptureDate else {
            return "never"
        }

        let interval = Date().timeIntervalSince(lastDate)

        if interval < 60 {
            return "just now"
        }

        if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes) min ago"
        }

        // If it was today, show the time
        if Calendar.current.isDateInToday(lastDate) {
            return "today at \(lastDate.formatted(date: .omitted, time: .shortened))"
        }

        // If it was yesterday
        if Calendar.current.isDateInYesterday(lastDate) {
            return "yesterday at \(lastDate.formatted(date: .omitted, time: .shortened))"
        }

        return lastDate.formatted(date: .abbreviated, time: .shortened)
    }

    private var nextCaptureText: String {
        guard timerManager.isRunning, !timerManager.isPaused else {
            return "\u{2014}"
        }

        guard let nextTime = timerManager.nextCaptureTime else {
            return "scheduling..."
        }

        let interval = nextTime.timeIntervalSince(Date())

        if interval <= 0 {
            return "any moment"
        }

        let minutes = Int(interval / 60)
        if minutes < 60 {
            return "in \(minutes) min"
        }

        return nextTime.formatted(date: .omitted, time: .shortened)
    }

    // MARK: - Quick Actions Section

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Quick Actions", systemImage: "bolt.fill")

            HStack(spacing: 10) {
                if !timerManager.isPaused {
                    Button {
                        showPauseDurationPicker.toggle()
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Pause capture")

                    if showPauseDurationPicker {
                        Picker("Pause duration", selection: $pauseDurationMinutes) {
                            Text("30m").tag(30)
                            Text("1h").tag(60)
                            Text("2h").tag(120)
                            Text("\u{221E}").tag(0)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityLabel("Pause duration")
                        .frame(width: 140)
                        .onChange(of: pauseDurationMinutes) { newValue in
                            if newValue == 0 {
                                coordinator.pause()
                            } else {
                                coordinator.pause(duration: Double(newValue) * 60)
                            }
                            showPauseDurationPicker = false
                        }
                    }
                } else {
                    Button {
                        coordinator.resume()
                        showPauseDurationPicker = false
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Resume capture")
                }
            }

            HStack(spacing: 10) {
                Button {
                    coordinator.captureNow()
                } label: {
                    Label("Take Photo Now", systemImage: "camera.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Take a photo now")

                Button(role: .destructive) {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Quit app")
            }
        }
    }

    // MARK: - Timer Settings Section

    private var timerSettingsSection: some View {
        DisclosureGroup(isExpanded: $isTimerExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                let minBinding = Binding<Double>(
                    get: { Double(settingsManager.minIntervalMinutes) },
                    set: { settingsManager.setIntervalRange(min: Int($0), max: settingsManager.maxIntervalMinutes) }
                )
                let maxBinding = Binding<Double>(
                    get: { Double(settingsManager.maxIntervalMinutes) },
                    set: { settingsManager.setIntervalRange(min: settingsManager.minIntervalMinutes, max: Int($0)) }
                )

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Min interval")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(settingsManager.minIntervalMinutes) min")
                            .monospacedDigit()
                    }
                    .font(.caption)

                    Slider(
                        value: minBinding,
                        in: 15...120,
                        step: 5
                    )
                    .accessibilityLabel("Minimum capture interval")
                    .accessibilityValue("\(settingsManager.minIntervalMinutes) minutes")
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Max interval")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(settingsManager.maxIntervalMinutes) min")
                            .monospacedDigit()
                    }
                    .font(.caption)

                    Slider(
                        value: maxBinding,
                        in: Double(settingsManager.minIntervalMinutes)...120,
                        step: 5
                    )
                    .accessibilityLabel("Maximum capture interval")
                    .accessibilityValue("\(settingsManager.maxIntervalMinutes) minutes")
                }

                HStack {
                    Spacer()
                    Text("Range: \(settingsManager.minIntervalMinutes)-\(settingsManager.maxIntervalMinutes) minutes")
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
                Picker("Storage location", selection: settingsManager.storageModeBinding) {
                    ForEach(SettingsManager.StorageMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Storage location")

                if settingsManager.storageMode == .customFolder {
                    HStack {
                        if let folderURL = settingsManager.customFolderURL {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            Text(folderURL.abbreviatingWithTildeInPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(folderURL.path)
                        } else {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                                .font(.caption)
                            Text("No folder selected")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }

                        Spacer()

                        Button("Change") {
                            selectCustomFolder()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                // Recent photos preview
                recentPhotosPreview
            }
            .padding(.top, 8)
            .onAppear { loadRecentPhotos() }
            .onChange(of: settingsManager.storageMode) { _ in loadRecentPhotos() }
            .onChange(of: settingsManager.totalPhotosCaptured) { _ in loadRecentPhotos() }
        } label: {
            SectionHeader(title: "Storage", systemImage: "folder.fill")
        }
    }

    @ViewBuilder
    private var recentPhotosPreview: some View {
        if !recentPhotos.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recent")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    ForEach(recentPhotos) { photo in
                        Image(nsImage: photo.thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 58, height: 58)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .help(photo.creationDate.formatted(date: .abbreviated, time: .shortened))
                    }

                    Spacer()
                }

                Button {
                    openStorageLocation()
                } label: {
                    Label("See all photos", systemImage: seeAllIcon)
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var seeAllIcon: String {
        settingsManager.storageMode == .photosApp ? "photo.on.rectangle" : "folder"
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
                    ForEach(wrappedManager.availableYears, id: \.self) { year in
                        Text(String(year)).tag(year)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Select year for wrapped video")

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
            .onAppear {
                wrappedManager.refreshAvailableYears()
            }
        } label: {
            SectionHeader(title: "Wrapped", systemImage: "sparkles.rectangle.stack")
        }
    }

    // MARK: - App Settings Section

    private var appSettingsSection: some View {
        DisclosureGroup(isExpanded: $isAppSettingsExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(
                    "Launch at Login",
                    isOn: Binding(
                        get: { settingsManager.launchAtLogin },
                        set: { newValue in
                            setLaunchAtLogin(newValue)
                        }
                    )
                )
                    .accessibilityLabel("Launch at login")

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

    private func loadRecentPhotos() {
        DispatchQueue.global(qos: .userInitiated).async {
            let photos = PhotoStorageManager.shared.fetchRecentPhotos(count: 4)
            DispatchQueue.main.async {
                self.recentPhotos = photos
            }
        }
    }

    private func openStorageLocation() {
        if settingsManager.storageMode == .photosApp {
            // Open Photos app
            NSWorkspace.shared.open(URL(string: "photos://")!)
        } else if let folderURL = settingsManager.customFolderURL {
            // Open the folder in Finder
            NSWorkspace.shared.open(folderURL)
        }
    }

    private func selectCustomFolder() {
        // Close the popover first so the NSOpenPanel can properly become key.
        // Transient popovers auto-dismiss when another window takes focus,
        // which causes the panel response to be lost.
        NSApp.sendAction(#selector(NSPopover.performClose(_:)), to: nil, from: nil)

        // Run on the next run-loop tick so the popover has time to close.
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true
            panel.message = "Select a folder to save photos"
            panel.prompt = "Select Folder"

            // Use runModal so the panel is app-modal and doesn't depend on
            // the now-closed popover for focus.
            let response = panel.runModal()
            if response == .OK, let url = panel.url {
                self.settingsManager.setCustomFolder(url: url)
                self.settingsManager.setStorageMode(.customFolder)
            }
        }
    }

    private func generateWrapped() {
        isGeneratingWrapped = true
        wrappedProgress = 0

        wrappedManager.generateWrapped(
            year: selectedYear,
            progressHandler: { progress in
                Task { @MainActor in
                    self.wrappedProgress = progress
                }
            }
        ) { _, error in
            Task { @MainActor in
                self.isGeneratingWrapped = false
                if let error {
                    self.wrappedProgress = 0
                    print("Wrapped generation failed: \(error.localizedDescription)")
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
            settingsManager.setLaunchAtLogin(enabled)
        } catch {
            print("Failed to update launch at login: \(error.localizedDescription)")
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
                        .accessibilityHidden(true)
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
                        .accessibilityHidden(true)
                    Text("Camera access required")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Grant") {
                        cameraManager.requestAuthorization { _ in }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Grant camera access")
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
                .accessibilityHidden(true)

            Image(systemName: camera.isBuiltIn ? "laptopcomputer" : "video.fill")
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)

            Text(camera.localizedName)
                .font(.caption)
                .lineLimit(1)

            Spacer()

            Toggle("Enable \(camera.localizedName)", isOn: $isEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .onChange(of: isEnabled) { newValue in
                    cameraManager.setCamera(camera.uniqueID, enabled: newValue)
                }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(camera.localizedName), \(isEnabled ? "enabled" : "disabled")")
        .onAppear {
            isEnabled = camera.isEnabled
        }
    }
}

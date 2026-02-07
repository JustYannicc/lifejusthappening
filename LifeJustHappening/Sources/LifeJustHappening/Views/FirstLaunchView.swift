import SwiftUI

/// A view displayed on first launch to welcome the user and offer launch at login setup
struct FirstLaunchView: View {
    @ObservedObject var launchAtLoginManager: LaunchAtLoginManager
    @Environment(\.dismiss) private var dismiss

    @State private var isEnabling = false
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        VStack(spacing: 24) {
            // App icon and title
            VStack(spacing: 12) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.blue)

                Text("Welcome to \(Constants.appName)")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Capture moments automatically at random intervals")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Explanation
            VStack(alignment: .leading, spacing: 16) {
                FeatureRow(
                    icon: "clock",
                    title: "Automatic Random Photos",
                    description: "Captures moments at random intervals throughout the day"
                )

                FeatureRow(
                    icon: "menubar.rectangle",
                    title: "Lives in Your Menu Bar",
                    description: "Stays out of your way until you need it"
                )

                FeatureRow(
                    icon: "power",
                    title: "Launch at Login",
                    description: "Start automatically when you log in to never miss a day"
                )
            }
            .padding(.horizontal)

            Divider()

            // Launch at login prompt
            VStack(spacing: 8) {
                Text("Start \(Constants.appName) automatically?")
                    .font(.headline)

                Text("You can change this later in Settings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Action buttons
            HStack(spacing: 12) {
                Button("Not Now") {
                    skipSetup()
                }
                .buttonStyle(.bordered)

                Button("Enable Launch at Login") {
                    enableLaunchAtLogin()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isEnabling)
            }
        }
        .padding(32)
        .frame(width: 400)
        .alert("Error", isPresented: $showError) {
            Button("OK") {
                skipSetup()
            }
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: - Private Methods

    private func enableLaunchAtLogin() {
        isEnabling = true

        do {
            try launchAtLoginManager.setEnabled(true)
            launchAtLoginManager.markFirstLaunchCompleted()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
            isEnabling = false
        }
    }

    private func skipSetup() {
        launchAtLoginManager.skipFirstLaunchSetup()
        dismiss()
    }
}

// MARK: - Feature Row Component

private struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    FirstLaunchView(launchAtLoginManager: LaunchAtLoginManager())
}

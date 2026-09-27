import SwiftUI
import UniformTypeIdentifiers

struct GooglePhotosSection: View {
    @ObservedObject var coordinator: CaptureCoordinator
    @ObservedObject var account: GoogleAccount

    var body: some View {
        Section {
            switch account.state {
            case .needsClient:
                Text("Uploading needs your own Google Cloud OAuth client. One-time setup, about 5 minutes.")
                    .foregroundStyle(.secondary)
                Link("Open the setup guide", destination: URL(string: "https://github.com/JustYannicc/lifejusthappening/blob/main/docs/google-photos-setup.md")!)
                Button("Import client JSON…") { importClient() }
            case .signedOut:
                Button("Sign in with Google") { Task { await account.signIn() } }
            case .signingIn:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in in your browser")
                    Spacer()
                    Button("Cancel") { account.cancelSignIn() }
                }
            case .signedIn(let email):
                LabeledContent("Account", value: email ?? "Connected")
                uploadStatus
                if let album = coordinator.album, let url = album.productURL {
                    Link(destination: url) {
                        Label("Open \"\(album.title)\" album", systemImage: "photo.stack")
                    }
                }
                LegacyImportRow(controller: coordinator.legacyImport)
            }

            if let error = account.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
        } header: {
            HStack {
                Text("Google Photos")
                Spacer()
                if account.state != .needsClient {
                    Menu {
                        if case .signedIn = account.state {
                            Button("Sign out") { account.signOut() }
                        }
                        Button("Replace OAuth client…") { importClient() }
                        Button("Remove OAuth client", role: .destructive) { account.removeClient() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Google account options")
                }
            }
        }
    }

    @ViewBuilder
    private var uploadStatus: some View {
        let uploads = coordinator.uploads
        HStack {
            if coordinator.isUploading {
                ProgressView().controlSize(.small)
                Text("Uploading…")
            } else if uploads.pending == 0 {
                Label("Everything's uploaded", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("\(uploads.pending) waiting to upload", systemImage: "arrow.up.circle")
                Spacer()
                Button("Retry") { Task { await coordinator.drainUploads() } }
            }
        }
        if let failure = uploads.failure, uploads.pending > 0 || uploads.rejected > 0 {
            Text(failure)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        if uploads.rejected > 0 {
            HStack {
                Text("\(uploads.rejected) rejected by Google")
                    .foregroundStyle(.orange)
                Spacer()
                Button("Show") {
                    NSWorkspace.shared.open(CaptureCoordinator.supportDirectory.appendingPathComponent("Rejected"))
                }
            }
        }
    }

    private func importClient() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Pick the client_secret_….json you downloaded from Google Cloud Console"
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        account.importClient(from: url)
    }
}

// MARK: - Old photos

private struct LegacyImportRow: View {
    @ObservedObject var controller: LegacyImportController

    var body: some View {
        if let progress = controller.progress, controller.folder != nil {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title(progress))
                    Spacer()
                    if progress.isRunning {
                        Button("Stop") { controller.stop() }
                    } else if progress.remaining > 0 {
                        Button("Resume") { controller.start() }
                    }
                }
                if progress.total > 0, !controller.isFinished {
                    ProgressView(value: Double(progress.done + progress.rejected), total: Double(progress.total))
                }
                if let failure = progress.failure, !progress.isRunning {
                    Text("\(failure). Tries again in \(progress.isRateLimited ? "30" : "5") min.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        } else {
            HStack {
                Text("Old photos from before")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Upload a folder…") { controller.chooseFolderAndStart() }
            }
        }
    }

    private func title(_ progress: LegacyImporter.Progress) -> String {
        let done = progress.done.formatted()
        let total = progress.total.formatted()
        if controller.isFinished {
            let rejected = progress.rejected > 0 ? " (\(progress.rejected) refused by Google)" : ""
            return "All \(done) old photos are in the album\(rejected)"
        }
        return progress.isRunning ? "Uploading old photos: \(done) of \(total)" : "Old photos: \(done) of \(total) uploaded"
    }
}


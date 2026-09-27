import Foundation

/// Photos wait here only until Google has them. Nothing is kept once uploaded;
/// this exists so a photo taken on a train without wifi isn't lost.
actor UploadQueue {
    struct Report: Equatable {
        var uploaded = 0
        var pending = 0
        var rejected = 0
        var failure: String?
    }

    private let outbox: URL
    private let rejectedDir: URL
    private let uploader: PhotoUploading
    private var isDraining = false

    init(root: URL, uploader: PhotoUploading) {
        self.outbox = root.appendingPathComponent("Outbox", isDirectory: true)
        self.rejectedDir = root.appendingPathComponent("Rejected", isDirectory: true)
        self.uploader = uploader
        for dir in [outbox, rejectedDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    func enqueue(_ data: Data, fileName: String) throws {
        var url = outbox.appendingPathComponent(fileName)
        var suffix = 1
        while FileManager.default.fileExists(atPath: url.path) {
            let base = (fileName as NSString).deletingPathExtension
            url = outbox.appendingPathComponent("\(base)-\(suffix).jpg")
            suffix += 1
        }
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func counts() -> Report {
        Report(pending: files(in: outbox).count, rejected: files(in: rejectedDir).count)
    }

    /// Uploads oldest first in batches. Stops at the first transient failure so we retry
    /// later in order instead of hammering a dead connection.
    func drain(batchSize: Int = 10) async -> Report {
        guard !isDraining else { return counts() }
        isDraining = true
        defer { isDraining = false }

        var report = Report()
        var files = files(in: outbox)
        while !files.isEmpty {
            let chunk = Array(files.prefix(batchSize))
            files.removeFirst(chunk.count)
            let loaded = chunk.compactMap { url in (try? Data(contentsOf: url)).map { (url, $0) } }
            do {
                let results = try await uploader.upload(loaded.map { UploadItem(data: $0.1, fileName: $0.0.lastPathComponent) })
                for ((url, _), result) in zip(loaded, results) {
                    switch result {
                    case .uploaded:
                        try? FileManager.default.removeItem(at: url)
                        report.uploaded += 1
                    case .rejected(let reason):
                        try? FileManager.default.moveItem(at: url, to: rejectedDir.appendingPathComponent(url.lastPathComponent))
                        report.failure = UploadError.rejected(reason).localizedDescription
                    }
                }
            } catch {
                report.failure = error.localizedDescription
                break
            }
        }
        let now = counts()
        report.pending = now.pending
        report.rejected = now.rejected
        return report
    }

    var rejectedFolder: URL { rejectedDir }

    private func files(in dir: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return contents
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

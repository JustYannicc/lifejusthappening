import Foundation

/// Uploads the old `~/Documents/lifejusthappening/Moment dd-MM-yyyy at HH-mm.jpg` archive into
/// the same album. Those files have no EXIF date, so the time from the filename is stamped in
/// (losslessly) first, otherwise Google would file 9k photos under the upload day.
///
/// Resumable: a ledger records what's done, so quitting, going offline or hitting Google's
/// daily quota just means it picks up where it stopped. Originals are never touched.
actor LegacyImporter {
    struct Progress: Equatable {
        var total = 0
        var done = 0
        var rejected = 0
        var isRunning = false
        var failure: String?
        var isRateLimited = false

        var remaining: Int { max(0, total - done - rejected) }
    }

    private struct Ledger: Codable {
        var uploaded: Set<String> = []
        var rejected: [String: String] = [:]
    }

    let folder: URL
    private let ledgerURL: URL
    private let uploader: PhotoUploading
    private var ledger: Ledger
    private var stopRequested = false
    /// Seconds to wait before retrying a transiently failed batch.
    var retryDelays: [UInt64] = [10, 60, 180]
    private(set) var progress = Progress()

    func setRetryDelays(_ delays: [UInt64]) {
        retryDelays = delays
    }

    init(folder: URL, ledgerURL: URL, uploader: PhotoUploading) {
        self.folder = folder
        self.ledgerURL = ledgerURL
        self.uploader = uploader
        self.ledger = (try? JSONDecoder().decode(Ledger.self, from: Data(contentsOf: ledgerURL))) ?? Ledger()
    }

    func scan() -> Progress {
        let files = photoFiles()
        progress.total = files.count
        progress.done = files.filter { ledger.uploaded.contains($0.lastPathComponent) }.count
        progress.rejected = files.filter { ledger.rejected[$0.lastPathComponent] != nil }.count
        return progress
    }

    func stop() {
        stopRequested = true
    }

    func run(batchSize: Int = GooglePhotosUploader.maxBatch, onProgress: @Sendable @escaping (Progress) async -> Void) async -> Progress {
        guard !progress.isRunning else { return progress }
        stopRequested = false
        _ = scan()
        progress.isRunning = true
        progress.failure = nil
        progress.isRateLimited = false
        await onProgress(progress)

        var pending = photoFiles().filter {
            !ledger.uploaded.contains($0.lastPathComponent) && ledger.rejected[$0.lastPathComponent] == nil
        }
        while !pending.isEmpty, !stopRequested {
            let chunk = Array(pending.prefix(batchSize))
            pending.removeFirst(chunk.count)
            let prepared = chunk.compactMap { url in Self.prepare(url).map { (url, $0) } }
            do {
                let results = try await uploadWithRetry(prepared.map(\.1))
                for ((url, _), result) in zip(prepared, results) {
                    switch result {
                    case .uploaded:
                        ledger.uploaded.insert(url.lastPathComponent)
                        progress.done += 1
                    case .rejected(let reason):
                        ledger.rejected[url.lastPathComponent] = reason
                        progress.rejected += 1
                    }
                }
                saveLedger()
            } catch {
                Log.upload.error("old-photo import stopped at \(self.progress.done): \(error.localizedDescription, privacy: .public)")
                progress.failure = error.localizedDescription
                if case UploadError.rateLimited = error { progress.isRateLimited = true }
                break
            }
            await onProgress(progress)
        }
        progress.isRunning = false
        await onProgress(progress)
        return progress
    }

    /// Network blips and Google 5xx happen over a 9k-photo import. Retry a batch a few times
    /// (10 s, 1 min, 3 min) before giving up; rate limits give up right away.
    private func uploadWithRetry(_ items: [UploadItem]) async throws -> [UploadItemResult] {
        let delays = retryDelays
        var attempt = 0
        while true {
            do {
                return try await uploader.upload(items)
            } catch UploadError.transient(let reason) where attempt < delays.count && !stopRequested {
                Log.upload.info("batch failed (\(reason, privacy: .public)), retry \(attempt + 1) in \(delays[attempt])s")
                try? await Task.sleep(nanoseconds: delays[attempt] * 1_000_000_000)
                attempt += 1
            }
        }
    }

    /// The old script named files by local wall-clock minute. When the file's creation time
    /// lands within a few minutes after that (true for ~96% of the archive), it's the real
    /// capture instant with seconds, so use it. Otherwise the file was copied or written late,
    /// and the filename minute is the truth. No travel clusters showed up in the archive, so
    /// the wall clock is read in the Mac's time zone (Europe/Zurich).
    static func captureDate(of url: URL, timeZone: TimeZone = .current) -> Date? {
        let name = url.deletingPathExtension().lastPathComponent
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "'Moment' dd-MM-yyyy 'at' HH-mm"
        let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
        guard let named = formatter.date(from: name) else { return created }
        return refine(named: named, created: created)
    }

    static func refine(named: Date, created: Date?) -> Date {
        guard let created else { return named }
        let lag = created.timeIntervalSince(named)
        return (0..<(5 * 60)).contains(lag) ? created : named
    }

    static func prepare(_ url: URL) -> UploadItem? {
        guard let data = try? Data(contentsOf: url), let date = captureDate(of: url) else { return nil }
        let stamped = PhotoEncoder.stamp(jpeg: data, metadata: PhotoMetadata(capturedAt: date)) ?? data
        return UploadItem(data: stamped, fileName: PhotoEncoder.fileName(for: date))
    }

    private func photoFiles() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return contents
            .filter { ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .sorted { (Self.captureDate(of: $0) ?? .distantPast) < (Self.captureDate(of: $1) ?? .distantPast) }
    }

    private func saveLedger() {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        try? data.write(to: ledgerURL, options: .atomic)
    }
}

import AppKit
import AVFoundation
import Combine
import Photos

// MARK: - Wrapped Configuration

/// Configuration options for video generation
struct WrappedConfiguration {
    var resolution: CGSize
    var frameRate: Int
    var photoDuration: TimeInterval
    var videoCodec: AVVideoCodecType
    var videoBitRate: Int

    static let defaultHD = WrappedConfiguration(
        resolution: CGSize(width: 1920, height: 1080),
        frameRate: 30,
        photoDuration: 0.5,
        videoCodec: .h264,
        videoBitRate: 10_000_000
    )

    static let default4K = WrappedConfiguration(
        resolution: CGSize(width: 3840, height: 2160),
        frameRate: 30,
        photoDuration: 0.5,
        videoCodec: .h264,
        videoBitRate: 35_000_000
    )

    /// Number of frames to display each photo
    var framesPerPhoto: Int {
        Int(photoDuration * Double(frameRate))
    }
}

// MARK: - Wrapped Error

enum WrappedError: LocalizedError {
    case noPhotosFound
    case noStorageLocationConfigured
    case photoLibraryAccessDenied
    case folderAccessLost
    case cannotCreateAssetWriter(Error)
    case cannotCreatePixelBuffer
    case cannotCreateCGImage
    case videoWritingFailed(Error)
    case cancelled
    case outputDirectoryNotWritable
    case invalidConfiguration

    var errorDescription: String? {
        switch self {
        case .noPhotosFound:
            return "No photos found for the selected year."
        case .noStorageLocationConfigured:
            return "No storage location has been configured. Please select a storage location in settings."
        case .photoLibraryAccessDenied:
            return "Photo library access was denied. Please grant access in System Settings > Privacy & Security > Photos."
        case .folderAccessLost:
            return "Access to the selected folder has been lost. Please select the folder again."
        case .cannotCreateAssetWriter(let error):
            return "Failed to create video writer: \(error.localizedDescription)"
        case .cannotCreatePixelBuffer:
            return "Failed to create pixel buffer for video frame."
        case .cannotCreateCGImage:
            return "Failed to convert image for video encoding."
        case .videoWritingFailed(let error):
            return "Video writing failed: \(error.localizedDescription)"
        case .cancelled:
            return "Video generation was cancelled."
        case .outputDirectoryNotWritable:
            return "The output directory is not writable."
        case .invalidConfiguration:
            return "Invalid video configuration."
        }
    }
}

// MARK: - Photo Item

/// Represents a photo with its metadata for wrapped generation
private struct PhotoItem {
    let url: URL?
    let asset: PHAsset?
    let creationDate: Date

    var year: Int {
        Calendar.current.component(.year, from: creationDate)
    }
}

// MARK: - Wrapped Manager

/// Manages year-end video compilation generation from captured photos
@MainActor
final class WrappedManager: ObservableObject {
    // MARK: - Singleton

    static let shared = WrappedManager()

    // MARK: - Published Properties

    @Published private(set) var isGenerating: Bool = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var availableYears: [Int] = []
    @Published private(set) var lastError: Error?

    // MARK: - Configuration

    var configuration: WrappedConfiguration = .defaultHD

    // MARK: - Private Properties

    private let photoStorageManager: PhotoStorageManager
    private var cancellationRequested: Bool = false
    private var currentTask: Task<Void, Never>?

    // MARK: - Constants

    private enum Constants {
        static let albumName = "Life Just Happening"
        static let supportedImageExtensions = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif"]
    }

    // MARK: - Initialization

    init(photoStorageManager: PhotoStorageManager = .shared) {
        self.photoStorageManager = photoStorageManager
    }

    // MARK: - Public Methods

    /// Scans the photo storage to find which years have photos available
    /// - Returns: Array of years sorted in descending order (most recent first)
    func getAvailableYears() async -> [Int] {
        let photos = await fetchAllPhotos()
        let years = Set(photos.map(\.year))
        let sortedYears = years.sorted(by: >)

        await MainActor.run {
            self.availableYears = sortedYears
        }

        return sortedYears
    }

    /// Refreshes the available years list
    func refreshAvailableYears() {
        Task {
            _ = await getAvailableYears()
        }
    }

    /// Generates a wrapped video for the specified year
    /// - Parameters:
    ///   - year: The year to generate the wrapped for
    ///   - outputURL: Optional custom output URL. If nil, user will be prompted to select location.
    ///   - progressHandler: Optional callback for progress updates (0-1)
    ///   - completion: Called with the output URL on success, or error on failure
    func generateWrapped(
        year: Int,
        outputURL: URL? = nil,
        progressHandler: ((Double) -> Void)? = nil,
        completion: @escaping (URL?, Error?) -> Void
    ) {
        guard !isGenerating else {
            completion(nil, WrappedError.cancelled)
            return
        }

        isGenerating = true
        progress = 0
        cancellationRequested = false
        lastError = nil

        currentTask = Task {
            do {
                // Determine output URL
                let finalOutputURL: URL
                if let outputURL {
                    finalOutputURL = outputURL
                } else {
                    guard let selectedURL = await selectOutputLocation(year: year) else {
                        throw WrappedError.cancelled
                    }
                    finalOutputURL = selectedURL
                }

                // Fetch photos for the year
                let photos = await fetchPhotosForYear(year)

                guard !photos.isEmpty else {
                    throw WrappedError.noPhotosFound
                }

                // Generate video
                let resultURL = try await generateVideo(
                    from: photos,
                    outputURL: finalOutputURL,
                    progressHandler: { [weak self] progress in
                        Task { @MainActor in
                            self?.progress = progress
                            progressHandler?(progress)
                        }
                    }
                )

                await MainActor.run {
                    self.isGenerating = false
                    self.progress = 1.0
                    completion(resultURL, nil)
                }
            } catch {
                await MainActor.run {
                    self.isGenerating = false
                    self.lastError = error
                    completion(nil, error)
                }
            }
        }
    }

    /// Async version of generateWrapped
    func generateWrapped(
        year: Int,
        outputURL: URL? = nil,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            generateWrapped(
                year: year,
                outputURL: outputURL,
                progressHandler: progressHandler
            ) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: error ?? WrappedError.cancelled)
                }
            }
        }
    }

    /// Cancels ongoing video generation
    func cancelGeneration() {
        cancellationRequested = true
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: - Private Methods - Photo Fetching

    private func fetchAllPhotos() async -> [PhotoItem] {
        guard let location = photoStorageManager.getCurrentStorageLocation() else {
            return []
        }

        switch location {
        case .photosApp:
            return await fetchPhotosFromPhotosApp()
        case .customFolder(let url):
            return fetchPhotosFromFolder(url)
        }
    }

    private func fetchPhotosForYear(_ year: Int) async -> [PhotoItem] {
        let allPhotos = await fetchAllPhotos()
        return allPhotos
            .filter { $0.year == year }
            .sorted { $0.creationDate < $1.creationDate }
    }

    private func fetchPhotosFromPhotosApp() async -> [PhotoItem] {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)

        guard status == .authorized || status == .limited else {
            // Request access
            let newStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            guard newStatus == .authorized || newStatus == .limited else {
                return []
            }
            return await fetchPhotosFromAlbum()
        }

        return await fetchPhotosFromAlbum()
    }

    private func fetchPhotosFromAlbum() async -> [PhotoItem] {
        // Fetch the "Life Just Happening" album
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "title = %@", Constants.albumName)
        let collections = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .any,
            options: fetchOptions
        )

        guard let album = collections.firstObject else {
            return []
        }

        // Fetch assets from the album
        let assetFetchOptions = PHFetchOptions()
        assetFetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let assets = PHAsset.fetchAssets(in: album, options: assetFetchOptions)

        var photos: [PhotoItem] = []
        assets.enumerateObjects { asset, _, _ in
            if let creationDate = asset.creationDate {
                photos.append(PhotoItem(url: nil, asset: asset, creationDate: creationDate))
            }
        }

        return photos
    }

    private func fetchPhotosFromFolder(_ folderURL: URL) -> [PhotoItem] {
        guard folderURL.startAccessingSecurityScopedResource() else {
            return []
        }

        defer {
            folderURL.stopAccessingSecurityScopedResource()
        }

        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.creationDateKey, .contentTypeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var photos: [PhotoItem] = []

        for case let fileURL as URL in enumerator {
            let pathExtension = fileURL.pathExtension.lowercased()
            guard Constants.supportedImageExtensions.contains(pathExtension) else {
                continue
            }

            // Get creation date from file metadata or file attributes
            let creationDate = getImageCreationDate(from: fileURL) ?? (try? fileManager.attributesOfItem(atPath: fileURL.path)[.creationDate] as? Date) ?? Date()

            photos.append(PhotoItem(url: fileURL, asset: nil, creationDate: creationDate))
        }

        return photos
    }

    private func getImageCreationDate(from url: URL) -> Date? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any],
              let exifDict = properties[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let dateString = exifDict[kCGImagePropertyExifDateTimeOriginal as String] as? String else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: dateString)
    }

    // MARK: - Private Methods - Output Location

    private func selectOutputLocation(year: Int) async -> URL? {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let savePanel = NSSavePanel()
                savePanel.allowedContentTypes = [.mpeg4Movie]
                savePanel.nameFieldStringValue = "Life Just Happening \(year).mp4"
                savePanel.canCreateDirectories = true
                savePanel.title = "Save Wrapped Video"
                savePanel.message = "Choose where to save your \(year) wrapped video"

                let response = savePanel.runModal()

                if response == .OK {
                    continuation.resume(returning: savePanel.url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Private Methods - Video Generation

    private func generateVideo(
        from photos: [PhotoItem],
        outputURL: URL,
        progressHandler: @escaping (Double) -> Void
    ) async throws -> URL {
        // Remove existing file if present
        try? FileManager.default.removeItem(at: outputURL)

        // Setup asset writer
        let assetWriter: AVAssetWriter
        do {
            assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw WrappedError.cannotCreateAssetWriter(error)
        }

        // Video settings
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: configuration.videoCodec,
            AVVideoWidthKey: Int(configuration.resolution.width),
            AVVideoHeightKey: Int(configuration.resolution.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: configuration.videoBitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false

        // Pixel buffer adaptor
        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: Int(configuration.resolution.width),
            kCVPixelBufferHeightKey as String: Int(configuration.resolution.height)
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )

        guard assetWriter.canAdd(writerInput) else {
            throw WrappedError.invalidConfiguration
        }

        assetWriter.add(writerInput)

        guard assetWriter.startWriting() else {
            throw WrappedError.videoWritingFailed(assetWriter.error ?? NSError(domain: "WrappedManager", code: -1))
        }

        assetWriter.startSession(atSourceTime: .zero)

        // Process photos
        let totalPhotos = photos.count
        var currentFrame = 0
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(configuration.frameRate))

        for (index, photo) in photos.enumerated() {
            // Check for cancellation
            if cancellationRequested {
                assetWriter.cancelWriting()
                throw WrappedError.cancelled
            }

            // Load image
            guard let image = await loadImage(from: photo) else {
                continue
            }

            // Scale image to target resolution
            guard let scaledImage = scaleImage(image, to: configuration.resolution) else {
                continue
            }

            // Create pixel buffer
            guard let pixelBuffer = createPixelBuffer(from: scaledImage, size: configuration.resolution) else {
                continue
            }

            // Write frames for this photo
            for _ in 0..<configuration.framesPerPhoto {
                if cancellationRequested {
                    assetWriter.cancelWriting()
                    throw WrappedError.cancelled
                }

                // Wait for writer to be ready
                while !writerInput.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 10_000_000) // 10ms
                }

                let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(currentFrame))
                adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
                currentFrame += 1
            }

            // Update progress
            let currentProgress = Double(index + 1) / Double(totalPhotos)
            progressHandler(currentProgress)
        }

        // Finish writing
        writerInput.markAsFinished()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            assetWriter.finishWriting {
                continuation.resume()
            }
        }

        if assetWriter.status == .failed {
            throw WrappedError.videoWritingFailed(assetWriter.error ?? NSError(domain: "WrappedManager", code: -1))
        }

        return outputURL
    }

    // MARK: - Private Methods - Image Processing

    private func loadImage(from photo: PhotoItem) async -> NSImage? {
        if let url = photo.url {
            // Load from file URL
            if url.startAccessingSecurityScopedResource() {
                defer { url.stopAccessingSecurityScopedResource() }
                return NSImage(contentsOf: url)
            }
            return NSImage(contentsOf: url)
        } else if let asset = photo.asset {
            // Load from Photos library
            return await loadImageFromAsset(asset)
        }

        return nil
    }

    private func loadImageFromAsset(_ asset: PHAsset) async -> NSImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isSynchronous = false
            options.isNetworkAccessAllowed = true

            let targetSize = CGSize(
                width: configuration.resolution.width,
                height: configuration.resolution.height
            )

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                if let nsImage = image {
                    continuation.resume(returning: nsImage)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func scaleImage(_ image: NSImage, to targetSize: CGSize) -> NSImage? {
        let aspectRatio = image.size.width / image.size.height
        let targetAspectRatio = targetSize.width / targetSize.height

        var scaledSize: CGSize

        if aspectRatio > targetAspectRatio {
            // Image is wider - fit to width
            scaledSize = CGSize(
                width: targetSize.width,
                height: targetSize.width / aspectRatio
            )
        } else {
            // Image is taller - fit to height
            scaledSize = CGSize(
                width: targetSize.height * aspectRatio,
                height: targetSize.height
            )
        }

        // Create a new image with the target size (with letterboxing/pillarboxing)
        let newImage = NSImage(size: targetSize)
        newImage.lockFocus()

        // Fill background with black
        NSColor.black.setFill()
        NSRect(origin: .zero, size: targetSize).fill()

        // Draw scaled image centered
        let x = (targetSize.width - scaledSize.width) / 2
        let y = (targetSize.height - scaledSize.height) / 2
        let destRect = NSRect(x: x, y: y, width: scaledSize.width, height: scaledSize.height)

        image.draw(
            in: destRect,
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0
        )

        newImage.unlockFocus()

        return newImage
    }

    private func createPixelBuffer(from image: NSImage, size: CGSize) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?

        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32ARGB,
            attributes as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            return nil
        }

        // Get CGImage from NSImage
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(origin: .zero, size: size))

        return buffer
    }
}

// MARK: - Computed Properties

extension WrappedManager {
    /// Estimated video duration in seconds for a given photo count
    func estimatedDuration(photoCount: Int) -> TimeInterval {
        TimeInterval(photoCount) * configuration.photoDuration
    }

    /// Formatted duration string
    func formattedDuration(photoCount: Int) -> String {
        let duration = estimatedDuration(photoCount: photoCount)
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60

        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }
}

import AppKit
import Photos

// StorageLocation is defined in Models/StorageLocation.swift

// MARK: - Photo Storage Error

enum PhotoStorageError: LocalizedError {
    case noStorageLocationConfigured
    case photoLibraryAccessDenied
    case albumCreationFailed
    case imageConversionFailed
    case fileSaveFailed(Error)
    case folderAccessLost
    case bookmarkResolutionFailed

    var errorDescription: String? {
        switch self {
        case .noStorageLocationConfigured:
            return "No storage location has been configured. Please select a storage location in settings."
        case .photoLibraryAccessDenied:
            return "Photo library access was denied. Please grant access in System Settings > Privacy & Security > Photos."
        case .albumCreationFailed:
            return "Failed to create the '\(Constants.photosAlbumName)' album in Photos."
        case .imageConversionFailed:
            return "Failed to convert the image to JPEG format."
        case .fileSaveFailed(let error):
            return "Failed to save the photo: \(error.localizedDescription)"
        case .folderAccessLost:
            return "Access to the selected folder has been lost. Please select the folder again."
        case .bookmarkResolutionFailed:
            return "Failed to resolve the saved folder location. Please select the folder again."
        }
    }
}

// MARK: - Photo Storage Manager

final class PhotoStorageManager: ObservableObject {
    static let shared = PhotoStorageManager()

    // MARK: - Constants

    private enum StorageConstants {
        static let albumName = Constants.photosAlbumName
        static let legacyAlbumName = Constants.legacyPhotosAlbumName
        static let folderBookmarkKey = "customFolderBookmark"
        static let folderPathKey = "customFolderPath"
        static let storageModeKey = "storageMode"
        static let jpegCompressionQuality: CGFloat = 0.95
    }

    // MARK: - Published Properties

    @Published private(set) var currentLocation: StorageLocation?
    @Published private(set) var photoLibraryAuthorizationStatus: PHAuthorizationStatus = .notDetermined

    // MARK: - Private Properties

    private let userDefaults: UserDefaults
    private var cachedAlbum: PHAssetCollection?

    private var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    // MARK: - Initialization

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        loadStorageLocation()
        updatePhotoLibraryAuthorizationStatus()
    }

    // MARK: - Public Methods

    /// Reloads the storage location from UserDefaults.
    /// Call this whenever SettingsManager's storage mode or custom folder bookmark changes
    /// so that captures use the up-to-date destination.
    func reloadStorageLocation() {
        loadStorageLocation()
    }

    /// Returns the current storage location
    func getCurrentStorageLocation() -> StorageLocation? {
        currentLocation
    }

    /// Saves a photo to the configured storage location
    func savePhoto(image: NSImage, completion: @escaping (Bool, Error?) -> Void) {
        guard let location = currentLocation else {
            completion(false, PhotoStorageError.noStorageLocationConfigured)
            return
        }

        switch location {
        case .photosApp:
            saveToPhotosApp(image: image, completion: completion)
        case .customFolder(let url):
            saveToCustomFolder(image: image, folderURL: url, completion: completion)
        }
    }

    /// Async version of savePhoto
    func savePhoto(image: NSImage) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            savePhoto(image: image) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? PhotoStorageError.imageConversionFailed)
                }
            }
        }
    }

    /// Requests access to the Photos library with addOnly permission.
    /// Returns true if access was granted.
    ///
    /// - Important: Always prefer ``requestPhotoLibraryAccess()`` (the async version).
    ///   The synchronous variant has been removed because it blocked the main
    ///   thread via a semaphore.
    func requestPhotoLibraryAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        await MainActor.run {
            photoLibraryAuthorizationStatus = status
        }

        let granted = status == .authorized || status == .limited

        if granted {
            await MainActor.run {
                setStorageMode(.photosApp)
            }
        }

        return granted
    }

    /// Shows a folder picker and sets the selected folder as storage location.
    /// Uses async panel presentation to avoid blocking the UI.
    @MainActor
    func selectCustomFolder() async {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.canCreateDirectories = true
        openPanel.prompt = "Select Folder"
        openPanel.message = "Choose a folder to save your photos"

        let response = await openPanel.begin()
        guard response == .OK, let selectedURL = openPanel.url else {
            return
        }

        saveSecurityScopedBookmark(for: selectedURL)
        setStorageMode(.customFolder(selectedURL))
    }

    /// Sets the storage mode to Photos app
    func usePhotosApp() {
        setStorageMode(.photosApp)
    }

    /// Clears the current storage location
    func clearStorageLocation() {
        currentLocation = nil
        userDefaults.removeObject(forKey: StorageConstants.storageModeKey)
        userDefaults.removeObject(forKey: StorageConstants.folderBookmarkKey)
        userDefaults.removeObject(forKey: StorageConstants.folderPathKey)
    }

    // MARK: - Private Methods - Storage Mode

    private func setStorageMode(_ location: StorageLocation) {
        currentLocation = location

        switch location {
        case .photosApp:
            userDefaults.set("photosApp", forKey: StorageConstants.storageModeKey)
            userDefaults.removeObject(forKey: StorageConstants.folderBookmarkKey)
            userDefaults.removeObject(forKey: StorageConstants.folderPathKey)
        case .customFolder:
            userDefaults.set("customFolder", forKey: StorageConstants.storageModeKey)
        }
    }

    private func loadStorageLocation() {
        guard let mode = userDefaults.string(forKey: StorageConstants.storageModeKey) else {
            currentLocation = nil
            return
        }

        switch mode {
        case "photosApp":
            currentLocation = .photosApp
        case "customFolder":
            if let folderURL = resolveCustomFolderURL() {
                currentLocation = .customFolder(folderURL)
            } else {
                currentLocation = nil
            }
        default:
            currentLocation = nil
        }
    }

    private func updatePhotoLibraryAuthorizationStatus() {
        photoLibraryAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    }

    // MARK: - Private Methods - Security Scoped Bookmarks

    private func saveSecurityScopedBookmark(for url: URL) {
        // Always store the plain path as a fallback
        userDefaults.set(url.path, forKey: StorageConstants.folderPathKey)
        
        // Try to create a security-scoped bookmark (works when properly codesigned)
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            userDefaults.set(bookmarkData, forKey: StorageConstants.folderBookmarkKey)
        } catch {
            print("Security-scoped bookmark not available (expected if unsigned): \(error)")
        }
    }

    /// Resolves the custom folder URL, trying security-scoped bookmark first
    /// then falling back to the stored path string.
    private func resolveCustomFolderURL() -> URL? {
        // Try security-scoped bookmark first
        if let bookmarkData = userDefaults.data(forKey: StorageConstants.folderBookmarkKey) {
            do {
                var isStale = false
                let url = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )

                if isStale {
                    saveSecurityScopedBookmark(for: url)
                }

                return url
            } catch {
                print("Failed to resolve bookmark, falling back to stored path: \(error)")
            }
        }

        // Fallback: use the stored path string directly
        if let path = userDefaults.string(forKey: StorageConstants.folderPathKey),
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        return nil
    }

    // MARK: - Private Methods - Photos App Storage

    private func saveToPhotosApp(image: NSImage, completion: @escaping (Bool, Error?) -> Void) {
        guard photoLibraryAuthorizationStatus == .authorized || photoLibraryAuthorizationStatus == .limited else {
            // Try to request access
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
                self?.photoLibraryAuthorizationStatus = status
                if status == .authorized || status == .limited {
                    self?.performPhotosSave(image: image, completion: completion)
                } else {
                    DispatchQueue.main.async {
                        completion(false, PhotoStorageError.photoLibraryAccessDenied)
                    }
                }
            }
            return
        }

        performPhotosSave(image: image, completion: completion)
    }

    private func performPhotosSave(image: NSImage, completion: @escaping (Bool, Error?) -> Void) {
        guard let imageData = image.jpegData(compressionQuality: StorageConstants.jpegCompressionQuality) else {
            DispatchQueue.main.async {
                completion(false, PhotoStorageError.imageConversionFailed)
            }
            return
        }

        // Create a temporary file for the image
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")

        do {
            try imageData.write(to: tempURL)
        } catch {
            DispatchQueue.main.async {
                completion(false, PhotoStorageError.fileSaveFailed(error))
            }
            return
        }

        PHPhotoLibrary.shared().performChanges { [weak self] in
            guard let self else { return }

            // Create the image asset
            let creationRequest = PHAssetCreationRequest.forAsset()
            creationRequest.addResource(with: .photo, fileURL: tempURL, options: nil)

            // Get or create the album and add the photo to it
            if let album = self.fetchOrCreateAlbum() {
                guard let albumChangeRequest = PHAssetCollectionChangeRequest(for: album),
                      let assetPlaceholder = creationRequest.placeholderForCreatedAsset else {
                    return
                }
                albumChangeRequest.addAssets([assetPlaceholder] as NSFastEnumeration)
            }
        } completionHandler: { success, error in
            // Clean up temp file
            try? FileManager.default.removeItem(at: tempURL)

            DispatchQueue.main.async {
                if success {
                    completion(true, nil)
                } else {
                    completion(false, error ?? PhotoStorageError.albumCreationFailed)
                }
            }
        }
    }

    private func fetchOrCreateAlbum() -> PHAssetCollection? {
        // Check cache first
        if let cached = cachedAlbum {
            return cached
        }

        // Fetch existing album
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "title = %@ OR title = %@", StorageConstants.albumName, StorageConstants.legacyAlbumName)
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: fetchOptions)

        if let existingAlbum = collections.firstObject {
            cachedAlbum = existingAlbum
            return existingAlbum
        }

        // Create new album synchronously within the change block
        // Note: This is called within performChanges, so we need to handle this differently
        var albumPlaceholder: PHObjectPlaceholder?

        do {
            try PHPhotoLibrary.shared().performChangesAndWait {
                let createAlbumRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: StorageConstants.albumName)
                albumPlaceholder = createAlbumRequest.placeholderForCreatedAssetCollection
            }
        } catch {
            print("Failed to create album: \(error)")
            return nil
        }

        // Fetch the newly created album
        guard let placeholder = albumPlaceholder else {
            return nil
        }

        let newAlbumFetch = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [placeholder.localIdentifier],
            options: nil
        )

        let newAlbum = newAlbumFetch.firstObject
        cachedAlbum = newAlbum
        return newAlbum
    }

    // MARK: - Private Methods - Custom Folder Storage

    private func saveToCustomFolder(image: NSImage, folderURL: URL, completion: @escaping (Bool, Error?) -> Void) {
        let hasSecurityScopeAccess = folderURL.startAccessingSecurityScopedResource()
        if isSandboxed && !hasSecurityScopeAccess {
            DispatchQueue.main.async {
                completion(false, PhotoStorageError.folderAccessLost)
            }
            return
        }

        defer {
            if hasSecurityScopeAccess {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        guard let imageData = image.jpegData(compressionQuality: StorageConstants.jpegCompressionQuality) else {
            DispatchQueue.main.async {
                completion(false, PhotoStorageError.imageConversionFailed)
            }
            return
        }

        let filename = generateFilename()
        let fileURL = folderURL.appendingPathComponent(filename)

        do {
            try imageData.write(to: fileURL)
            DispatchQueue.main.async {
                completion(true, nil)
            }
        } catch {
            DispatchQueue.main.async {
                completion(false, PhotoStorageError.fileSaveFailed(error))
            }
        }
    }

    private func generateFilename() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd-MM-yyyy 'at' HH-mm"
        let dateString = dateFormatter.string(from: Date())
        return "Moment \(dateString).jpg"
    }

    // MARK: - Recent Photos

    /// Represents a recent photo with its thumbnail and creation date
    struct RecentPhoto: Identifiable {
        let id = UUID()
        let thumbnail: NSImage
        let creationDate: Date
        let url: URL?
    }

    /// Fetches the most recent photos from the current storage location
    /// - Parameter count: Maximum number of photos to return
    /// - Returns: Array of recent photos sorted newest-first
    func fetchRecentPhotos(count: Int = 4) -> [RecentPhoto] {
        guard let location = currentLocation else { return [] }

        switch location {
        case .photosApp:
            return fetchRecentFromPhotosApp(count: count)
        case .customFolder(let url):
            return fetchRecentFromFolder(url, count: count)
        }
    }

    private func fetchRecentFromFolder(_ folderURL: URL, count: Int) -> [RecentPhoto] {
        let hasAccess = folderURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { folderURL.stopAccessingSecurityScopedResource() }
        }

        let fileManager = FileManager.default
        let supportedExtensions = Set(["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif"])

        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return []
        }

        var files: [(url: URL, date: Date)] = []
        for case let fileURL as URL in enumerator {
            guard supportedExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
            let date = (try? fileURL.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
            files.append((fileURL, date))
        }

        // Sort newest first and take the requested count
        files.sort { $0.date > $1.date }
        let recent = files.prefix(count)

        return recent.compactMap { file in
            guard let image = NSImage(contentsOf: file.url) else { return nil }
            let thumb = image.scaled(toFit: NSSize(width: 80, height: 80))
            return RecentPhoto(thumbnail: thumb, creationDate: file.date, url: file.url)
        }
    }

    private func fetchRecentFromPhotosApp(count: Int) -> [RecentPhoto] {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return [] }

        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(
            format: "title = %@ OR title = %@",
            StorageConstants.albumName,
            StorageConstants.legacyAlbumName
        )
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: fetchOptions)
        guard collections.count > 0 else { return [] }

        // Gather assets from all matching albums
        var allAssets: [PHAsset] = []
        var seenIDs = Set<String>()

        let assetOptions = PHFetchOptions()
        assetOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        assetOptions.fetchLimit = count

        collections.enumerateObjects { album, _, stop in
            let assets = PHAsset.fetchAssets(in: album, options: assetOptions)
            assets.enumerateObjects { asset, _, _ in
                if !seenIDs.contains(asset.localIdentifier) {
                    seenIDs.insert(asset.localIdentifier)
                    allAssets.append(asset)
                }
            }
            if allAssets.count >= count {
                stop.pointee = true
            }
        }

        // Sort newest first and limit
        allAssets.sort { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        let limited = allAssets.prefix(count)

        return limited.compactMap { asset in
            let options = PHImageRequestOptions()
            options.isSynchronous = true
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast

            var result: RecentPhoto?
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 80, height: 80),
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                if let image {
                    result = RecentPhoto(
                        thumbnail: image,
                        creationDate: asset.creationDate ?? Date(),
                        url: nil
                    )
                }
            }
            return result
        }
    }
}

// NSImage.jpegData extension is defined in Utils/Extensions.swift

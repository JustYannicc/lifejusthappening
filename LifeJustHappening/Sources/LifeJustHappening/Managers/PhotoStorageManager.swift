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
            return "Failed to create the 'Life Just Happening' album in Photos."
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

    private enum Constants {
        static let albumName = "Life Just Happening"
        static let folderBookmarkKey = "customFolderBookmark"
        static let storageModeKey = "storageMode"
        static let jpegCompressionQuality: CGFloat = 0.95
    }

    // MARK: - Published Properties

    @Published private(set) var currentLocation: StorageLocation?
    @Published private(set) var photoLibraryAuthorizationStatus: PHAuthorizationStatus = .notDetermined

    // MARK: - Private Properties

    private let userDefaults: UserDefaults
    private var cachedAlbum: PHAssetCollection?

    // MARK: - Initialization

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        loadStorageLocation()
        updatePhotoLibraryAuthorizationStatus()
    }

    // MARK: - Public Methods

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

    /// Requests access to the Photos library with addOnly permission
    /// Returns true if access was granted
    @discardableResult
    func requestPhotoLibraryAccess() -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var granted = false

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            granted = status == .authorized || status == .limited
            self?.photoLibraryAuthorizationStatus = status
            semaphore.signal()
        }

        semaphore.wait()

        if granted {
            setStorageMode(.photosApp)
        }

        return granted
    }

    /// Async version of requestPhotoLibraryAccess
    func requestPhotoLibraryAccessAsync() async -> Bool {
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

    /// Shows a folder picker and sets the selected folder as storage location
    func selectCustomFolder() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.canCreateDirectories = true
        openPanel.prompt = "Select Folder"
        openPanel.message = "Choose a folder to save your photos"

        guard openPanel.runModal() == .OK, let selectedURL = openPanel.url else {
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
        userDefaults.removeObject(forKey: Constants.storageModeKey)
        userDefaults.removeObject(forKey: Constants.folderBookmarkKey)
    }

    // MARK: - Private Methods - Storage Mode

    private func setStorageMode(_ location: StorageLocation) {
        currentLocation = location

        switch location {
        case .photosApp:
            userDefaults.set("photosApp", forKey: Constants.storageModeKey)
            userDefaults.removeObject(forKey: Constants.folderBookmarkKey)
        case .customFolder:
            userDefaults.set("customFolder", forKey: Constants.storageModeKey)
        }
    }

    private func loadStorageLocation() {
        guard let mode = userDefaults.string(forKey: Constants.storageModeKey) else {
            currentLocation = nil
            return
        }

        switch mode {
        case "photosApp":
            currentLocation = .photosApp
        case "customFolder":
            if let folderURL = resolveSecurityScopedBookmark() {
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
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            userDefaults.set(bookmarkData, forKey: Constants.folderBookmarkKey)
        } catch {
            print("Failed to create security-scoped bookmark: \(error)")
        }
    }

    private func resolveSecurityScopedBookmark() -> URL? {
        guard let bookmarkData = userDefaults.data(forKey: Constants.folderBookmarkKey) else {
            return nil
        }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                // Bookmark is stale, try to create a new one
                saveSecurityScopedBookmark(for: url)
            }

            return url
        } catch {
            print("Failed to resolve security-scoped bookmark: \(error)")
            return nil
        }
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
        guard let imageData = image.jpegData(compressionQuality: Constants.jpegCompressionQuality) else {
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
        fetchOptions.predicate = NSPredicate(format: "title = %@", Constants.albumName)
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
                let createAlbumRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: Constants.albumName)
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
        guard folderURL.startAccessingSecurityScopedResource() else {
            DispatchQueue.main.async {
                completion(false, PhotoStorageError.folderAccessLost)
            }
            return
        }

        defer {
            folderURL.stopAccessingSecurityScopedResource()
        }

        guard let imageData = image.jpegData(compressionQuality: Constants.jpegCompressionQuality) else {
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
}

// NSImage.jpegData extension is defined in Utils/Extensions.swift

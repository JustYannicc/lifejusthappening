import Foundation

/// Defines where captured photos should be stored
enum StorageLocation: Codable, Hashable {
    /// Store photos in the system Photos app
    case photosApp
    
    /// Store photos in a custom folder at the specified URL
    case customFolder(URL)
    
    // MARK: - Codable
    
    private enum CodingKeys: String, CodingKey {
        case type
        case url
    }
    
    private enum LocationType: String, Codable {
        case photosApp
        case customFolder
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(LocationType.self, forKey: .type)
        
        switch type {
        case .photosApp:
            self = .photosApp
        case .customFolder:
            let url = try container.decode(URL.self, forKey: .url)
            self = .customFolder(url)
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        switch self {
        case .photosApp:
            try container.encode(LocationType.photosApp, forKey: .type)
        case .customFolder(let url):
            try container.encode(LocationType.customFolder, forKey: .type)
            try container.encode(url, forKey: .url)
        }
    }
}

// MARK: - Helper Properties

extension StorageLocation {
    /// Human-readable name for the storage location
    var displayName: String {
        switch self {
        case .photosApp:
            return "Photos App"
        case .customFolder(let url):
            return url.lastPathComponent
        }
    }
    
    /// Whether this location is the Photos app
    var isPhotosApp: Bool {
        if case .photosApp = self {
            return true
        }
        return false
    }
    
    /// The URL for custom folder storage, nil for Photos app
    var folderURL: URL? {
        if case .customFolder(let url) = self {
            return url
        }
        return nil
    }
}

import AppKit
import Foundation

// MARK: - Date+RelativeTime

extension Date {
    /// Returns a human-readable relative time string (e.g., "in 45 minutes")
    var relativeTimeString: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: self, relativeTo: Date())
    }
    
    /// Returns a short relative time string (e.g., "45 min")
    var shortRelativeTimeString: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: self, relativeTo: Date())
    }
    
    /// Returns time remaining as components (hours, minutes, seconds)
    var timeRemaining: (hours: Int, minutes: Int, seconds: Int)? {
        let interval = self.timeIntervalSince(Date())
        guard interval > 0 else { return nil }
        
        let totalSeconds = Int(interval)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        
        return (hours, minutes, seconds)
    }
}

// MARK: - NSImage+JPEG

extension NSImage {
    /// Converts the image to JPEG data with the specified compression quality
    /// - Parameter quality: Compression quality from 0.0 (max compression) to 1.0 (best quality)
    /// - Returns: JPEG data, or nil if conversion fails
    func jpegData(compressionQuality quality: CGFloat = 0.85) -> Data? {
        guard let tiffData = tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        
        return bitmapRep.representation(
            using: .jpeg,
            properties: [.compressionFactor: quality]
        )
    }
    
    /// Converts the image to PNG data
    /// - Returns: PNG data, or nil if conversion fails
    func pngData() -> Data? {
        guard let tiffData = tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        
        return bitmapRep.representation(using: .png, properties: [:])
    }
    
    /// Returns the image scaled to fit within the specified size while maintaining aspect ratio
    func scaled(toFit targetSize: NSSize) -> NSImage {
        let widthRatio = targetSize.width / size.width
        let heightRatio = targetSize.height / size.height
        let ratio = min(widthRatio, heightRatio)
        
        let newSize = NSSize(
            width: size.width * ratio,
            height: size.height * ratio
        )
        
        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        draw(
            in: NSRect(origin: .zero, size: newSize),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 1.0
        )
        newImage.unlockFocus()
        
        return newImage
    }
}

// MARK: - URL+SecurityScoped

extension URL {
    /// Creates a security-scoped bookmark for the URL
    /// - Returns: Bookmark data, or nil if creation fails
    func createSecurityScopedBookmark() -> Data? {
        do {
            return try bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            print("Failed to create security-scoped bookmark: \(error)")
            return nil
        }
    }
    
    /// Resolves a security-scoped bookmark to a URL
    /// - Parameter bookmarkData: The bookmark data to resolve
    /// - Returns: A tuple containing the resolved URL and whether the bookmark is stale
    static func resolveSecurityScopedBookmark(_ bookmarkData: Data) -> (url: URL, isStale: Bool)? {
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return (url, isStale)
        } catch {
            print("Failed to resolve security-scoped bookmark: \(error)")
            return nil
        }
    }
    
    /// Starts accessing the security-scoped resource
    /// - Returns: true if access was granted, false otherwise
    @discardableResult
    func startSecurityScopedAccess() -> Bool {
        startAccessingSecurityScopedResource()
    }
    
    /// Stops accessing the security-scoped resource
    func stopSecurityScopedAccess() {
        stopAccessingSecurityScopedResource()
    }
    
    /// Executes a closure with security-scoped access to the URL
    /// - Parameter body: The closure to execute with access
    /// - Returns: The result of the closure
    func withSecurityScopedAccess<T>(_ body: () throws -> T) rethrows -> T {
        let didStart = startSecurityScopedAccess()
        defer {
            if didStart {
                stopSecurityScopedAccess()
            }
        }
        return try body()
    }
}

// MARK: - TimeInterval+Formatting

extension TimeInterval {
    /// Returns a human-readable string for the interval (e.g., "5 minutes")
    var formattedDuration: String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.maximumUnitCount = 2
        return formatter.string(from: self) ?? "\(Int(self)) seconds"
    }
    
    /// Returns minutes as an integer
    var minutes: Int {
        Int(self / 60)
    }
    
    /// Creates a TimeInterval from minutes
    static func minutes(_ minutes: Int) -> TimeInterval {
        TimeInterval(minutes * 60)
    }
    
    /// Creates a TimeInterval from hours
    static func hours(_ hours: Int) -> TimeInterval {
        TimeInterval(hours * 3600)
    }
}

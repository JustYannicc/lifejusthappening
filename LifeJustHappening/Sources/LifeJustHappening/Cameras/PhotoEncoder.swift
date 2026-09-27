import CoreGraphics
import CoreLocation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Everything we know about a shot besides the pixels.
struct PhotoMetadata {
    var capturedAt: Date
    var timeZone: TimeZone = .current
    var location: CLLocation?
    var cameraName: String?
}

enum PhotoEncoder {
    /// JPEG with capture time, place and camera baked into EXIF/GPS/TIFF. Google Photos reads
    /// DateTimeOriginal for the timeline and the GPS block for the map, so photos that sat in
    /// the outbox while offline still land at the right time and place.
    static func jpeg(_ image: CGImage, metadata: PhotoMetadata, quality: Double = 0.88) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        var properties = properties(for: metadata)
        properties[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Adds metadata to an existing JPEG without re-encoding the pixels.
    static func stamp(jpeg: Data, metadata: PhotoMetadata) -> Data? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let type = CGImageSourceGetType(source) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else { return nil }
        let tags = CGImageMetadataCreateMutable()
        for (dictionary, values) in properties(for: metadata) {
            guard let values = values as? [CFString: Any] else { continue }
            for (key, value) in values {
                CGImageMetadataSetValueMatchingImageProperty(tags, dictionary, key, value as CFTypeRef)
            }
        }
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: tags,
            kCGImageDestinationMergeMetadata: true,
        ]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else { return nil }
        return output as Data
    }

    static func properties(for metadata: PhotoMetadata) -> [CFString: Any] {
        let stamp = exifDate(metadata.capturedAt, timeZone: metadata.timeZone)
        let offset = exifOffset(metadata.capturedAt, timeZone: metadata.timeZone)
        var tiff: [CFString: Any] = [
            kCGImagePropertyTIFFDateTime: stamp,
            kCGImagePropertyTIFFSoftware: "lifejusthappening",
        ]
        if let camera = metadata.cameraName {
            tiff[kCGImagePropertyTIFFModel] = camera
        }
        var properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: stamp,
                kCGImagePropertyExifDateTimeDigitized: stamp,
                kCGImagePropertyExifOffsetTimeOriginal: offset,
                kCGImagePropertyExifOffsetTimeDigitized: offset,
            ],
            kCGImagePropertyTIFFDictionary: tiff,
        ]
        if let location = metadata.location {
            properties[kCGImagePropertyGPSDictionary] = gps(location)
        }
        return properties
    }

    static func gps(_ location: CLLocation) -> [CFString: Any] {
        let utc = TimeZone(identifier: "UTC")!
        var gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: abs(location.coordinate.latitude),
            kCGImagePropertyGPSLatitudeRef: location.coordinate.latitude >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude: abs(location.coordinate.longitude),
            kCGImagePropertyGPSLongitudeRef: location.coordinate.longitude >= 0 ? "E" : "W",
            kCGImagePropertyGPSDateStamp: format(location.timestamp, "yyyy:MM:dd", utc),
            kCGImagePropertyGPSTimeStamp: format(location.timestamp, "HH:mm:ss", utc),
        ]
        if location.horizontalAccuracy >= 0 {
            gps[kCGImagePropertyGPSHPositioningError] = location.horizontalAccuracy
        }
        if location.verticalAccuracy >= 0 {
            gps[kCGImagePropertyGPSAltitude] = abs(location.altitude)
            gps[kCGImagePropertyGPSAltitudeRef] = location.altitude >= 0 ? 0 : 1
        }
        return gps
    }

    /// Mean luma in 0...1 from a tiny grayscale downsample.
    static func meanBrightness(_ image: CGImage) -> Double {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return 1 }
        return Double(pixels.reduce(0) { $0 + Int($1) }) / Double(pixels.count * 255)
    }

    /// Pure black: privacy shutter closed, lid shut on the camera, or a camera that "worked"
    /// without delivering frames (~0.002). Late-night shots lit only by the screen sit around
    /// 0.007 in the old archive and are kept.
    static func isBlank(_ image: CGImage) -> Bool {
        meanBrightness(image) < 0.005
    }

    static func thumbnail(_ image: CGImage, maxPixelSize: Int = 320) -> CGImage? {
        let scale = Double(maxPixelSize) / Double(max(image.width, image.height))
        guard scale < 1 else { return image }
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func fileName(for date: Date, timeZone: TimeZone = .current) -> String {
        "ljh_\(format(date, "yyyy-MM-dd_HH-mm-ss", timeZone)).jpg"
    }

    private static func exifDate(_ date: Date, timeZone: TimeZone) -> String {
        format(date, "yyyy:MM:dd HH:mm:ss", timeZone)
    }

    private static func format(_ date: Date, _ pattern: String, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    private static func exifOffset(_ date: Date, timeZone: TimeZone) -> String {
        let seconds = timeZone.secondsFromGMT(for: date)
        let sign = seconds < 0 ? "-" : "+"
        let minutes = abs(seconds) / 60
        return String(format: "%@%02d:%02d", sign, minutes / 60, minutes % 60)
    }
}

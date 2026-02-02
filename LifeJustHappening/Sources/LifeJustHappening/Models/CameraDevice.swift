import AVFoundation
import Foundation

/// Represents a camera device available for capture
struct CameraDevice: Identifiable, Codable, Hashable {
    /// Unique identifier for the camera (AVCaptureDevice.uniqueID)
    let id: String
    
    /// Human-readable name of the camera (AVCaptureDevice.localizedName)
    let name: String
    
    /// Whether this is a built-in camera (FaceTime, iSight, etc.)
    let isBuiltIn: Bool
    
    /// Whether the camera is currently connected/available
    var isConnected: Bool
    
    /// Whether the user has enabled this camera for capture
    var isEnabled: Bool
    
    /// Priority for capture order (lower = higher priority)
    var priority: Int
    
    // Computed properties for compatibility with AVCaptureDevice naming
    var uniqueID: String { id }
    var localizedName: String { name }
    
    init(
        id: String,
        name: String,
        isBuiltIn: Bool,
        isConnected: Bool = true,
        isEnabled: Bool = true,
        priority: Int = 0
    ) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.isConnected = isConnected
        self.isEnabled = isEnabled
        self.priority = priority
    }
    
    /// Initialize from uniqueID and localizedName (compatibility initializer)
    init(uniqueID: String, localizedName: String, isBuiltIn: Bool, isEnabled: Bool = true, priority: Int = 0) {
        self.id = uniqueID
        self.name = localizedName
        self.isBuiltIn = isBuiltIn
        self.isConnected = true
        self.isEnabled = isEnabled
        self.priority = priority
    }
    
    /// Initialize from AVCaptureDevice
    init(from device: AVCaptureDevice, priority: Int = 0) {
        self.id = device.uniqueID
        self.name = device.localizedName
        self.isBuiltIn = device.deviceType == .builtInWideAngleCamera
        self.isConnected = true
        self.isEnabled = true
        self.priority = priority
    }
}

extension CameraDevice {
    /// Display name with connection status indicator
    var displayName: String {
        if isConnected {
            return name
        } else {
            return "\(name) (Disconnected)"
        }
    }
    
    /// Whether this camera should be used for capture
    var shouldCapture: Bool {
        isConnected && isEnabled
    }
}

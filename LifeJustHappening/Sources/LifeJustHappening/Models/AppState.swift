import Foundation

/// Represents the current capture state of the application
enum AppState: Codable, Hashable {
    /// Actively capturing photos at the configured interval
    case active
    
    /// Capture is paused indefinitely
    case paused
    
    /// Capture is paused until a specific time
    case pausedUntil(Date)
    
    // MARK: - Codable
    
    private enum CodingKeys: String, CodingKey {
        case type
        case resumeDate
    }
    
    private enum StateType: String, Codable {
        case active
        case paused
        case pausedUntil
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(StateType.self, forKey: .type)
        
        switch type {
        case .active:
            self = .active
        case .paused:
            self = .paused
        case .pausedUntil:
            let date = try container.decode(Date.self, forKey: .resumeDate)
            self = .pausedUntil(date)
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        switch self {
        case .active:
            try container.encode(StateType.active, forKey: .type)
        case .paused:
            try container.encode(StateType.paused, forKey: .type)
        case .pausedUntil(let date):
            try container.encode(StateType.pausedUntil, forKey: .type)
            try container.encode(date, forKey: .resumeDate)
        }
    }
}

// MARK: - Helper Properties

extension AppState {
    /// Human-readable text describing the current state
    var displayText: String {
        switch self {
        case .active:
            return "Active"
        case .paused:
            return "Paused"
        case .pausedUntil(let date):
            return "Paused until \(date.relativeTimeString)"
        }
    }
    
    /// Whether capture is currently active
    var isActive: Bool {
        if case .active = self {
            return true
        }
        return false
    }
    
    /// Whether capture is paused (either indefinitely or temporarily)
    var isPaused: Bool {
        switch self {
        case .active:
            return false
        case .paused, .pausedUntil:
            return true
        }
    }
    
    /// The resume date if paused until a specific time, nil otherwise
    var resumeDate: Date? {
        if case .pausedUntil(let date) = self {
            return date
        }
        return nil
    }
    
    /// Checks if a timed pause has expired and capture should resume
    var shouldResume: Bool {
        if case .pausedUntil(let date) = self {
            return Date() >= date
        }
        return false
    }
}

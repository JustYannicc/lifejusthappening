import CoreGraphics
import Foundation
import IOKit

/// What the Mac is doing right now, as far as capturing is concerned.
struct ActivitySnapshot: Equatable {
    /// No human input for this long means you've walked away, even if an agent is busy.
    static let presenceWindow: TimeInterval = 5 * 60

    /// The lid is shut. With an external display that's clamshell mode: the Mac is in use
    /// but the built-in camera is staring at the keyboard.
    var isLidClosed: Bool
    /// At least one display is on and drawable.
    var hasActiveDisplay: Bool
    /// Screen locked, or another user has the console.
    var isSessionLocked: Bool
    /// Seconds since the last keyboard/mouse input from a human.
    var secondsSinceHumanInput: TimeInterval = 0
    /// Whether that number ignores agent input (needs Input Monitoring).
    var humanInputVerified: Bool = true

    /// Real hardware input this recent proves you're at the Mac, so the camera doesn't
    /// need to find your face (dark room, hand over your face, looking down).
    var humanProvablyPresent: Bool {
        humanInputVerified && secondsSinceHumanInput < 60
    }

    var isActive: Bool {
        hasActiveDisplay && !isSessionLocked && secondsSinceHumanInput < Self.presenceWindow
    }

    var inactiveReason: String? {
        if isSessionLocked { return "Screen locked" }
        if !hasActiveDisplay { return "Display asleep" }
        if secondsSinceHumanInput >= Self.presenceWindow { return "Nobody at the keyboard" }
        return nil
    }
}

/// Polls the system instead of tracking notifications, so there's no state to drift.
enum ActivityMonitor {
    static func sample(input: RealInputMonitor) -> ActivitySnapshot {
        let human = input.secondsSinceHumanInput()
        return ActivitySnapshot(
            isLidClosed: isLidClosed(),
            hasActiveDisplay: activeDisplayCount() > 0,
            isSessionLocked: isSessionLocked(),
            secondsSinceHumanInput: human.seconds,
            humanInputVerified: human.verified
        )
    }

    static func isLidClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? Bool) ?? false
    }

    private static func activeDisplayCount() -> UInt32 {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return 1 }
        return count
    }

    private static func isSessionLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        let locked = session["CGSSessionScreenIsLocked"] as? Bool ?? false
        let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool ?? true
        return locked || !onConsole
    }
}

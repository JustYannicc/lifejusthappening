import CoreGraphics
import Foundation

/// Tracks the last keyboard/mouse input that came from actual hardware.
///
/// Computer-use agents post synthetic events, and those reset every system idle timer
/// (both `CGEventSource` idle and the kernel's HIDIdleTime, checked on macOS 27). The one
/// reliable tell is the event's source PID: hardware input arrives with PID 0, anything an
/// app posts carries that app's PID. Reading it needs a listen-only event tap, which needs
/// the Input Monitoring permission. Without it we fall back to the fooled idle timer.
final class RealInputMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var lastHardwareInput = Date()
    private var tap: CFMachPort?
    private var thread: Thread?

    var hasAccess: Bool { CGPreflightListenEventAccess() }
    var isRunning: Bool { lock.withLock { tap != nil } }

    /// Shows the system prompt (first time) or does nothing if already decided.
    @discardableResult
    func requestAccess() -> Bool { CGRequestListenEventAccess() }

    /// Seconds since the last human input. `verified` is false when we can't tell humans
    /// from agents because the tap isn't running.
    func secondsSinceHumanInput() -> (seconds: TimeInterval, verified: Bool) {
        if isRunning {
            return (lock.withLock { Date().timeIntervalSince(lastHardwareInput) }, true)
        }
        let any = CGEventType(rawValue: ~0)!
        return (CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: any), false)
    }

    /// Starts the tap if we have access and it isn't running yet. Safe to call repeatedly.
    func startIfPossible() {
        guard !isRunning, hasAccess else { return }
        let thread = Thread { [weak self] in self?.runTap() }
        thread.name = "lifejusthappening.input-tap"
        thread.qualityOfService = .utility
        self.thread = thread
        thread.start()
    }

    fileprivate func noteHardwareInput() {
        lock.withLock { lastHardwareInput = Date() }
    }

    fileprivate func reenable() {
        lock.withLock { tap }.map { CGEvent.tapEnable(tap: $0, enable: true) }
    }

    private func runTap() {
        let types: [CGEventType] = [
            .keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .scrollWheel, .mouseMoved, .leftMouseDragged,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: inputTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }

        lock.withLock { self.tap = tap }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        CFRunLoopRun()
    }

    static func isHardware(sourcePID: Int64) -> Bool {
        sourcePID == 0
    }
}

private func inputTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<RealInputMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        monitor.reenable()
    default:
        if RealInputMonitor.isHardware(sourcePID: event.getIntegerValueField(.eventSourceUnixProcessID)) {
            monitor.noteHardwareInput()
        }
    }
    return Unmanaged.passUnretained(event)
}

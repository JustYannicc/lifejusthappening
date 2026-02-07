import Foundation
import ServiceManagement

/// Manages launch at login functionality using SMAppService (macOS 13+)
@MainActor
final class LaunchAtLoginManager: ObservableObject {
    // MARK: - Published Properties

    @Published private(set) var isEnabled: Bool = false
    @Published private(set) var lastError: Error?

    // MARK: - Private Properties

    private let hasCompletedFirstLaunchKey = "hasCompletedFirstLaunch"

    private var isRunningFromApplicationsFolder: Bool {
        let appPath = Bundle.main.bundleURL.path
        return appPath.hasPrefix("/Applications/") || appPath.hasPrefix("/System/Applications/")
    }

    // MARK: - Computed Properties

    /// Whether this is the first launch of the app
    var isFirstLaunch: Bool {
        !UserDefaults.standard.bool(forKey: hasCompletedFirstLaunchKey)
    }

    // MARK: - Initialization

    init() {
        refreshStatus()
    }

    // MARK: - Public Methods

    /// Refreshes the current launch at login status from the system
    func refreshStatus() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Enables or disables launch at login
    /// - Parameter enabled: Whether launch at login should be enabled
    /// - Throws: An error if the operation fails
    func setEnabled(_ enabled: Bool) throws {
        lastError = nil

        if enabled, !isRunningFromApplicationsFolder {
            throw LaunchAtLoginError.requiresApplicationsInstall
        }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshStatus()
        } catch {
            lastError = error
            throw LaunchAtLoginError.operationFailed(underlying: error)
        }
    }

    /// Returns the current status from the system
    func getStatus() -> SMAppService.Status {
        SMAppService.mainApp.status
    }

    /// Marks first launch as completed
    func markFirstLaunchCompleted() {
        UserDefaults.standard.set(true, forKey: hasCompletedFirstLaunchKey)
    }

    /// Resets first launch status (useful for testing)
    func resetFirstLaunchStatus() {
        UserDefaults.standard.removeObject(forKey: hasCompletedFirstLaunchKey)
    }

    /// Attempts to enable launch at login and marks first launch as completed
    /// - Returns: Whether the operation was successful
    @discardableResult
    func enableOnFirstLaunch() -> Bool {
        guard isFirstLaunch else { return false }

        do {
            try setEnabled(true)
            markFirstLaunchCompleted()
            return true
        } catch {
            lastError = error
            return false
        }
    }

    /// Skips enabling launch at login and marks first launch as completed
    func skipFirstLaunchSetup() {
        markFirstLaunchCompleted()
    }
}

// MARK: - Error Types

enum LaunchAtLoginError: LocalizedError {
    case operationFailed(underlying: Error)
    case notSupported
    case requiresApplicationsInstall

    var errorDescription: String? {
        switch self {
        case .operationFailed(let underlying):
            let description = underlying.localizedDescription
            if description.localizedCaseInsensitiveContains("operation not permitted") {
                return "Launch at login requires the app to be installed in /Applications and properly signed. Move the app to /Applications, open it once from there, then try again."
            }
            return "Failed to update launch at login: \(description)"
        case .notSupported:
            return "Launch at login is not supported on this system"
        case .requiresApplicationsInstall:
            return "Launch at login is only available when the app is installed in /Applications."
        }
    }
}

// MARK: - SMAppService.Status Extension

extension SMAppService.Status: @retroactive CustomStringConvertible {
    public var description: String {
        switch self {
        case .notRegistered:
            return "Not Registered"
        case .enabled:
            return "Enabled"
        case .requiresApproval:
            return "Requires Approval"
        case .notFound:
            return "Not Found"
        @unknown default:
            return "Unknown"
        }
    }

    /// Whether the status indicates the service is effectively enabled
    var isEffectivelyEnabled: Bool {
        self == .enabled
    }

    /// Whether the status requires user action in System Settings
    var requiresUserAction: Bool {
        self == .requiresApproval
    }
}

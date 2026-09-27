import Foundation

/// What a feedback report carries besides your message. State only: no photos, no
/// coordinates, no tokens.
extension CaptureCoordinator {
    var feedbackTags: [String: String] {
        [
            "paused": String(isPaused),
            "active": String(activity.isActive),
            "lid_closed": String(activity.isLidClosed),
            "google": account.isSignedIn ? "signed_in" : "\(account.state)",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
    }

    var feedbackContext: [String: Any] {
        var context: [String: Any] = [
            "schedule": [
                "target_min": Int(schedule.targetActiveSeconds / 60),
                "accumulated_min": Int(schedule.accumulatedActiveSeconds / 60),
                "misses": schedule.misses,
            ],
            "interval_min": [minMinutes, maxMinutes],
            "pause": "\(pause)",
            "activity": [
                "display_on": activity.hasActiveDisplay,
                "locked": activity.isSessionLocked,
                "human_idle_s": Int(activity.secondsSinceHumanInput),
                "human_input_verified": activity.humanInputVerified,
            ],
            "cameras": cameras.cameras.map { camera in
                [
                    "name": camera.name,
                    "kind": camera.kind.rawValue,
                    "enabled": camera.isEnabled,
                    "unavailable": cameras.unavailability(of: camera, isLidClosed: activity.isLidClosed).map { "\($0)" } ?? "no",
                ] as [String: Any]
            },
            "permissions": [
                "camera": "\(cameras.authorization.rawValue)",
                "input_monitoring": input.hasAccess,
                "location": location.isAuthorized,
            ],
            "uploads": [
                "pending": uploads.pending,
                "rejected": uploads.rejected,
                "last_failure": uploads.failure ?? "",
                "uploading": isUploading,
            ],
            "total_captured": totalCaptured,
            "album_count": recent.albumCount ?? -1,
        ]
        if let outcome = lastOutcome {
            context["last_outcome"] = ["date": outcome.date.ISO8601Format(), "result": "\(outcome.result)"]
        }
        if let legacy = legacyImport.progress {
            context["old_photo_import"] = [
                "done": legacy.done,
                "total": legacy.total,
                "rejected": legacy.rejected,
                "running": legacy.isRunning,
                "rate_limited": legacy.isRateLimited,
                "failure": legacy.failure ?? "",
            ]
        }
        return context
    }
}

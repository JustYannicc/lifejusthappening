import Foundation
import OSLog
import Sentry

/// Sentry: user feedback + crash reports, only when build-app.sh baked a DSN into Info.plist.
/// No tracing, no screenshots, no default PII. Never location coordinates or tokens.
/// Offline sends are cached by the SDK and go out on the next launch.
enum FeedbackReporter {
    static var dsn: String? {
        (Bundle.main.object(forInfoDictionaryKey: "SentryDSN") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    static var isConfigured: Bool { dsn != nil }

    static func start() {
        guard let dsn else { return }
        SentrySDK.start { options in
            options.dsn = dsn
            options.releaseName = "lifejusthappening@\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")"
            options.environment = "production"
            options.sendDefaultPii = false
            options.tracesSampleRate = nil
            options.enableAppHangTracking = false
            options.debug = ProcessInfo.processInfo.environment["LJH_SENTRY_DEBUG"] == "1"
        }
        Log.upload.info("sentry initialised")
    }

    enum Result: Equatable {
        case notConfigured
        case sent(delivered: Bool)
    }

    /// `context` is a plain dictionary of app state (see `CaptureCoordinator.debugContext`).
    static func send(message: String, tags: [String: String], context: [String: Any]) -> Result {
        guard isConfigured else { return .notConfigured }
        let log = Attachment(data: Data(recentLog().utf8), filename: "recent-log.txt", contentType: "text/plain")
        SentrySDK.configureScope { scope in
            for (key, value) in tags { scope.setTag(value: value, key: key) }
            scope.setContext(value: context, key: "lifejusthappening")
        }
        let feedback = SentryFeedback(
            message: message.trimmingCharacters(in: .whitespacesAndNewlines),
            name: Host.current().localizedName,
            email: nil,
            source: .custom,
            attachments: [log]
        )
        SentrySDK.capture(feedback: feedback)
        SentrySDK.flush(timeout: 5)
        Log.upload.info("feedback sent, \(message.count) chars")
        return .sent(delivered: true)
    }

    /// Last ~300 lines this process logged under our subsystem.
    static func recentLog(limit: Int = 300) -> String {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
              let entries = try? store.getEntries(
                  at: store.position(timeIntervalSinceEnd: -24 * 3600),
                  matching: NSPredicate(format: "subsystem == %@", "com.yanniccharlon.lifejusthappening")
              ) else { return "(log unavailable)" }
        let lines = entries.compactMap { $0 as? OSLogEntryLog }.map { entry in
            "\(entry.date.ISO8601Format()) [\(entry.category)] \(entry.composedMessage)"
        }
        return lines.suffix(limit).joined(separator: "\n")
    }
}

import os

/// `log show --predicate 'subsystem == "com.yanniccharlon.lifejusthappening"' --info`
enum Log {
    static let upload = Logger(subsystem: "com.yanniccharlon.lifejusthappening", category: "upload")
    static let capture = Logger(subsystem: "com.yanniccharlon.lifejusthappening", category: "capture")
}

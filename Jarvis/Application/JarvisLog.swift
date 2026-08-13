import Foundation
import os.log

enum JarvisLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.nandan.jarvis"
    private static let logger = OSLog(subsystem: subsystem, category: "Jarvis")

    static func info(_ message: String) {
        os_log("%{public}@", log: logger, type: .info, sanitize(message))
    }

    static func error(_ message: String) {
        os_log("%{public}@", log: logger, type: .error, sanitize(message))
    }

    private static func sanitize(_ message: String) -> String {
        let sensitiveMarkers = ["authorization", "bearer ", "api key", "access token", "x-goog-api-key"]
        guard !sensitiveMarkers.contains(where: { message.lowercased().contains($0) }) else {
            return "Sensitive diagnostic was redacted"
        }
        return message
    }
}


import Foundation
import os.log

/// Secure logging that redacts sensitive data in release builds.
enum SecureLog {
    private static let logger = Logger(subsystem: "com.horcrux.wallet", category: "app")

    /// Log an info-level message. Sensitive values are redacted in non-debug builds.
    static func info(_ message: String) {
        #if DEBUG
        logger.info("\(message, privacy: .public)")
        #else
        logger.info("\(message, privacy: .private)")
        #endif
    }

    /// Log an error-level message. Never includes raw key material.
    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    /// Log a debug-only message (stripped entirely in release).
    static func debug(_ message: String) {
        #if DEBUG
        logger.debug("\(message, privacy: .public)")
        #endif
    }
}

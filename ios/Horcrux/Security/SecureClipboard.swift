import UIKit

/// Clipboard security — copies sensitive data with auto-expiration.
enum SecureClipboard {

    /// Copy text to clipboard with automatic clearing after `expireSeconds`.
    /// Default: 60 seconds.
    static func copy(_ text: String, expireSeconds: TimeInterval = 60) {
        UIPasteboard.general.string = text

        // Schedule clipboard clearing
        let expirationItem = [UIPasteboard.general.changeCount]
        DispatchQueue.main.asyncAfter(deadline: .now() + expireSeconds) {
            // Only clear if clipboard hasn't been changed since our copy
            if UIPasteboard.general.changeCount == expirationItem[0] {
                UIPasteboard.general.string = ""
            }
        }
    }

    /// Clear clipboard immediately.
    static func clear() {
        UIPasteboard.general.string = ""
    }
}

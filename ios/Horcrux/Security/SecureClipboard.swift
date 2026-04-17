import UIKit

/// Clipboard security — copies sensitive data with auto-expiration.
enum SecureClipboard {

    /// Default clipboard expiration time.
    static let defaultExpireSeconds: TimeInterval = 60

    /// Copy text to clipboard with automatic clearing after `expireSeconds`.
    /// Uses UIPasteboard expiration API for background safety (no Timer/GCD needed).
    /// Also emits a global toast + haptic so the user gets immediate confirmation.
    static func copy(_ text: String, expireSeconds: TimeInterval = defaultExpireSeconds, toast: String = "已复制") {
        let items: [[String: String]] = [["public.utf8-plain-text": text]]
        let options: [UIPasteboard.OptionsKey: Any] = [
            .expirationDate: Date().addingTimeInterval(expireSeconds)
        ]
        UIPasteboard.general.setItems(items, options: options)
        Task { @MainActor in
            Haptics.selection()
            CopyFeedback.showToast(toast)
        }
    }

    /// Clear clipboard immediately.
    static func clear() {
        UIPasteboard.general.string = ""
    }
}

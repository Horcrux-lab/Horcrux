import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Stable, unique device identity used across MPC ceremonies (DKG + signing).
///
/// **Why this exists.** iOS 16+ returns a generic "iPhone" string from
/// `UIDevice.current.name` for third-party apps (a privacy change). When two
/// of the user's physical phones (or two simulators during dev testing) both
/// report "iPhone", several things break:
///   - `SignPresenceDTO.deviceName` collides → the presence filter in
///     `CreateShardViewModel` can't distinguish "me" from "peer".
///   - `firstIndex(of: UIDevice.current.name)` in DKG participant lists
///     picks the wrong party index (both devices think they are party 0).
///   - Invite / joined-cosigner UIs show a list of indistinguishable
///     "iPhone / iPhone / iPhone" rows.
///
/// This helper derives a persistent per-install UUID (stored in
/// `UserDefaults`; survives app restarts, rotated only on uninstall) and
/// exposes a short, stable display name. A user-set nickname from Settings
/// always wins over both.
enum DeviceIdentity {
    private static let udKey = "com.horcrux.deviceId.v1"
    private static let nicknameKey = "deviceNickname"

    /// Stable installation-scoped UUID. Persisted in `UserDefaults`; lazily
    /// minted on first read. Used as the unique participant key in MPC
    /// ceremonies (room presence, participant indices, etc.).
    static var stableId: String {
        if let existing = UserDefaults.standard.string(forKey: udKey),
           !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: udKey)
        return fresh
    }

    /// Short 8-char suffix derived from `stableId`, for display only.
    /// Example: `"7F3A9B21"`.
    static var shortId: String {
        let hex = stableId.replacingOccurrences(of: "-", with: "")
        return String(hex.prefix(8)).uppercased()
    }

    /// Human-readable identifier for this device, shown in invite / joined
    /// cosigner / device list UIs and included in every presence message.
    ///
    /// Priority:
    ///   1. User-set nickname from Settings (`deviceNickname`) — respected
    ///      verbatim if non-empty.
    ///   2. `{model}-{shortId}` — e.g. `"iPhone-7F3A9B21"`. Always unique
    ///      across two installs of the app even when iOS masks the system
    ///      device name.
    static var displayName: String {
        if let nick = UserDefaults.standard.string(forKey: nicknameKey),
           !nick.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nick
        }
        #if canImport(UIKit)
        let model = UIDevice.current.model
        return "\(model)-\(shortId)"
        #else
        return "Device-\(shortId)"
        #endif
    }

    /// Split a `displayName` string into its friendly label part and short-id
    /// suffix for two-line display in device lists. Works on both the
    /// auto-generated `"iPhone-7F3A9B21"` form and on user nicknames that
    /// don't contain an 8-hex suffix (in which case `shortId` is `nil`).
    ///
    /// Examples:
    ///   - `"iPhone-7F3A9B21"` → `("iPhone", "7F3A9B21")`
    ///   - `"iPad-ABCDEF01"`   → `("iPad", "ABCDEF01")`
    ///   - `"Bill's Phone"`    → `("Bill's Phone", nil)` — nickname, no id
    static func split(_ displayName: String) -> (label: String, shortId: String?) {
        guard let dashRange = displayName.range(of: "-", options: .backwards) else {
            return (displayName, nil)
        }
        let tail = displayName[dashRange.upperBound...]
        let isShortId = tail.count == 8 && tail.allSatisfy { c in
            c.isHexDigit && (c.isNumber || c.isUppercase)
        }
        if isShortId {
            let label = String(displayName[..<dashRange.lowerBound])
            return (label.isEmpty ? displayName : label, String(tail))
        }
        return (displayName, nil)
    }
}

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
}

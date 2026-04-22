import Foundation

/// Centralized configuration for the relay server.
///
/// By default, Horcrux uses the official relay (`wss://relay.horcrux.app`)
/// in Release builds, and a local dev relay in Debug builds. Users can
/// opt into a custom relay URL from Settings → Relay Server, and the
/// `HORCRUX_RELAY_URL` environment variable overrides everything (handy
/// for scheme-level pointing during integration tests).
enum RelayConfig {
    /// Default official relay endpoint used by Release builds. Uses
    /// `wss://` (TLS over port 443) so it traverses corporate / carrier
    /// proxies that only allow outbound 443.
    static let officialURL = "wss://relay.horcrux.app"

    /// Fallback for local development (simulator on host machine).
    /// Matches the port `cargo run -p horcrux-relay` binds to by default.
    static let localDevelopmentURL = "ws://localhost:3210"

    static let useCustomKey = "horcrux_relay_custom_enabled"
    static let customURLKey = "horcrux_relay_url"

    /// Whether the user has opted into a custom relay.
    static var useCustom: Bool {
        get { UserDefaults.standard.bool(forKey: useCustomKey) }
        set { UserDefaults.standard.set(newValue, forKey: useCustomKey) }
    }

    /// Effective relay URL based on build config and user preference.
    ///
    /// Resolution order (first match wins):
    /// 1. User-chosen custom relay (Settings → Relay Server).
    /// 2. `HORCRUX_RELAY_URL` scheme environment variable.
    /// 3. Build-config default:
    ///    - Debug   → `localDevelopmentURL` (ws://localhost:3210)
    ///    - Release → `officialURL` (wss://relay.horcrux.app)
    static var effectiveURL: String {
        if useCustom,
           let data = try? KeychainManager.shared.retrieve(key: customURLKey),
           let url = String(data: data, encoding: .utf8), !url.isEmpty {
            return url
        }
        if let override = ProcessInfo.processInfo.environment["HORCRUX_RELAY_URL"],
           !override.isEmpty {
            return override
        }
        #if DEBUG
        return localDevelopmentURL
        #else
        return officialURL
        #endif
    }

    /// Saves a custom relay URL (and enables custom mode).
    static func setCustom(_ url: String) throws {
        try KeychainManager.shared.store(key: customURLKey, data: Data(url.utf8))
        useCustom = true
    }

    /// Resets to the default (official or dev) relay.
    static func resetToDefault() {
        useCustom = false
    }
}

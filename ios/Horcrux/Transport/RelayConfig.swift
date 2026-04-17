import Foundation

/// Centralized configuration for the relay server.
///
/// By default, Horcrux uses the official relay (`wss://relay.horcrux.app`).
/// Users can opt into a custom relay URL from Settings.
enum RelayConfig {
    /// Default official relay endpoint.
    /// TODO: replace with real production host once deployed.
    static let officialURL = "wss://relay.horcrux.app"

    /// Fallback for local development (simulator on host machine).
    static let localDevelopmentURL = "ws://localhost:3210"

    static let useCustomKey = "horcrux_relay_custom_enabled"
    static let customURLKey = "horcrux_relay_url"

    /// Whether the user has opted into a custom relay.
    static var useCustom: Bool {
        get { UserDefaults.standard.bool(forKey: useCustomKey) }
        set { UserDefaults.standard.set(newValue, forKey: useCustomKey) }
    }

    /// Effective relay URL based on user preference.
    static var effectiveURL: String {
        if useCustom,
           let data = try? KeychainManager.shared.retrieve(key: customURLKey),
           let url = String(data: data, encoding: .utf8), !url.isEmpty {
            return url
        }
        #if DEBUG
        // In debug builds on simulator, prefer local dev relay if reachable.
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

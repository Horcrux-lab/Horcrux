import Foundation
import SwiftUI

/// Handles `horcrux://` deep links for session joining, signing, and transaction details.
///
/// URL Scheme:
///   horcrux://sign?session=<SESSION_ID>
///   horcrux://join?session=<SESSION_ID>
///   horcrux://tx?hash=<TX_HASH>
///   horcrux://receive?address=<ADDRESS>&chain=<CHAIN>

enum DeepLink: Equatable {
    case joinSession(sessionId: String)
    case transactionDetail(txHash: String)
    case receive(address: String, chain: String?)
}

@MainActor
final class DeepLinkRouter: ObservableObject {
    static let shared = DeepLinkRouter()

    /// Sensitive links (e.g. `joinSession`) park here until the user
    /// explicitly confirms. A phishing page can open `horcrux://join?...`
    /// to try to pull the wallet into an attacker's ceremony — the
    /// confirmation dialog is the user-presence gate that blocks silent
    /// auto-join. See audit finding M7.
    @Published var pendingConfirmation: DeepLink?

    /// Activated links — either confirmed by the user or non-sensitive
    /// navigation (transactionDetail / receive) that bypasses confirmation.
    @Published var pendingLink: DeepLink?
    @Published var selectedTab: Int = 0

    private init() {}

    func handle(_ link: DeepLink) {
        switch link {
        case .joinSession:
            // Require explicit user confirmation before auto-joining a
            // signing / DKG ceremony from an external URL.
            pendingConfirmation = link
            selectedTab = 0
        case .transactionDetail, .receive:
            // Read-only navigation — safe to auto-activate.
            pendingLink = link
            selectedTab = 0
        }
    }

    /// Promote the pending confirmation to an active link (user tapped
    /// "Continue"). Callers should immediately route off `pendingLink`.
    func confirmPending() {
        guard let link = pendingConfirmation else { return }
        pendingConfirmation = nil
        pendingLink = link
    }

    /// Discard the pending confirmation (user tapped "Cancel" or dismissed).
    func cancelPending() {
        pendingConfirmation = nil
    }

    func parseURL(_ url: URL) -> DeepLink? {
        guard url.scheme == "horcrux" else { return nil }

        let host = url.host ?? ""
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        func param(_ name: String) -> String? {
            queryItems.first(where: { $0.name == name })?.value
        }

        switch host {
        case "sign", "join":
            guard let sessionId = param("session"), !sessionId.isEmpty else { return nil }
            return .joinSession(sessionId: sessionId)

        case "tx":
            guard let hash = param("hash"), !hash.isEmpty else { return nil }
            return .transactionDetail(txHash: hash)

        case "receive":
            guard let address = param("address"), !address.isEmpty else { return nil }
            return .receive(address: address, chain: param("chain"))

        default:
            SecureLog.warning("Unknown deep link host: \(host)")
            return nil
        }
    }

    func consumePendingLink() -> DeepLink? {
        let link = pendingLink
        pendingLink = nil
        return link
    }
}

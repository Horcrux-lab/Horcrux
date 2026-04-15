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

    @Published var pendingLink: DeepLink?
    @Published var selectedTab: Int = 0

    private init() {}

    func handle(_ link: DeepLink) {
        pendingLink = link

        switch link {
        case .joinSession:
            // Navigate to signing tab (index 0 = Wallet, but we'll handle via overlay)
            selectedTab = 0
        case .transactionDetail:
            selectedTab = 0
        case .receive:
            selectedTab = 0
        }
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

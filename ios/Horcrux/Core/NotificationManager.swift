import Foundation
import UserNotifications

/// Manages local push notifications for signing requests and transaction updates.
final class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    @Published private(set) var isAuthorized = false

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - Authorization

    func requestAuthorization() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            await MainActor.run { isAuthorized = granted }
        } catch {
            SecureLog.warning("Notification auth failed: \(error.localizedDescription)")
        }
    }

    func checkAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        await MainActor.run {
            isAuthorized = settings.authorizationStatus == .authorized
        }
    }

    // MARK: - Signing Request Notification

    func notifySigningRequest(sessionId: String, from peerName: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = "Signing Request"
        content.body = peerName.map { "\($0) is requesting your signature" }
            ?? "A peer is requesting your signature"
        content.sound = .default
        content.categoryIdentifier = "SIGNING_REQUEST"
        content.userInfo = ["action": "sign", "sessionId": sessionId]

        let request = UNNotificationRequest(
            identifier: "signing-\(sessionId)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                SecureLog.warning("Failed to schedule signing notification: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Transaction Confirmed Notification

    func notifyTransactionConfirmed(txHash: String, chain: String) {
        let content = UNMutableNotificationContent()
        content.title = "Transaction Confirmed"
        let shortHash = String(txHash.prefix(10)) + "..." + String(txHash.suffix(6))
        content.body = "\(chain) transaction \(shortHash) has been confirmed on-chain"
        content.sound = .default
        content.userInfo = ["action": "tx_detail", "txHash": txHash]

        let request = UNNotificationRequest(
            identifier: "tx-confirmed-\(txHash)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Keygen Complete Notification

    func notifyKeygenComplete(walletName: String) {
        let content = UNMutableNotificationContent()
        content.title = "Key Generation Complete"
        content.body = "Wallet \"\(walletName)\" has been created successfully"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "keygen-\(walletName)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show notifications even when app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        return [.banner, .sound]
    }

    /// Handle notification tap
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let action = userInfo["action"] as? String else { return }

        await MainActor.run {
            switch action {
            case "sign":
                if let sessionId = userInfo["sessionId"] as? String {
                    DeepLinkRouter.shared.handle(.joinSession(sessionId: sessionId))
                }
            case "tx_detail":
                if let txHash = userInfo["txHash"] as? String {
                    DeepLinkRouter.shared.handle(.transactionDetail(txHash: txHash))
                }
            default:
                break
            }
        }
    }
}

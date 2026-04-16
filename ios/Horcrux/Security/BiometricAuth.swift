import Foundation
import LocalAuthentication

/// Biometric authentication (Face ID / Touch ID) for app unlock.
final class BiometricAuth: @unchecked Sendable {
    static let shared = BiometricAuth()
    private init() {}

    enum BiometricType {
        case faceID, touchID, none
    }

    var availableType: BiometricType {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .none
        }
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        default: return .none
        }
    }

    func authenticate(reason: String = "Unlock Horcrux to access your key shards") async -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = ""

        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
        } catch {
            return false
        }
    }
}

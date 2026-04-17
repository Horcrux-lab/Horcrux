import UIKit

/// Shared haptic feedback helpers.
///
/// Web3 wallets live or die by how "physical" their critical actions feel —
/// users are moving money, and tactile confirmations build trust. Keep usage
/// targeted: success on completion, warning on destructive confirmation,
/// error on failure. Avoid peppering every tap.
enum Haptics {
    static func success() {
        let g = UINotificationFeedbackGenerator()
        g.prepare()
        g.notificationOccurred(.success)
    }

    static func warning() {
        let g = UINotificationFeedbackGenerator()
        g.prepare()
        g.notificationOccurred(.warning)
    }

    static func error() {
        let g = UINotificationFeedbackGenerator()
        g.prepare()
        g.notificationOccurred(.error)
    }

    static func tap() {
        let g = UIImpactFeedbackGenerator(style: .light)
        g.prepare()
        g.impactOccurred()
    }

    static func selection() {
        let g = UISelectionFeedbackGenerator()
        g.prepare()
        g.selectionChanged()
    }
}

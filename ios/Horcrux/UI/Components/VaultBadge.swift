import SwiftUI

/// Flat square badge used by Vault Mode in place of the circular
/// `WalletAvatarView`. Shows a two-letter monogram on a neutral card
/// fill, with a small corner dot that encodes vault health.
///
/// Keep this component visually distinct from `WalletAvatarView` —
/// Vault Mode intentionally trades the consumer "identicon" look for
/// something that reads more like a row in an ops console.
struct VaultBadge: View {

    let monogram: String
    let health: VaultDisplay.Health

    /// 36×36 is the smallest size that still fits two wide ASCII
    /// letters at the 15pt weight we use for the monogram, with
    /// the status dot overhanging the corner cleanly.
    var size: CGFloat = 36

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(red: 0.11, green: 0.13, blue: 0.20))                    // #1C2134 neutral fill
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
                .frame(width: size, height: size)

            Text(monogram)
                .font(.system(size: size * 0.42, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.92))
                .frame(width: size, height: size)
                .allowsTightening(true)
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            // Status dot — sits slightly outside the badge corner so it
            // reads even when the row is dense.
            Circle()
                .fill(dotColor)
                .frame(width: size * 0.28, height: size * 0.28)
                .overlay(
                    Circle()
                        .stroke(HorcruxTheme.deepBlack, lineWidth: 2)
                )
                .offset(x: size * 0.14, y: -size * 0.14)
                .accessibilityHidden(true)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
    }

    private var dotColor: Color {
        switch health {
        case .healthy:  return HorcruxTheme.successGreen
        case .degraded: return HorcruxTheme.warningAmber
        case .stale:    return HorcruxTheme.dangerRed
        case .idle:     return Color.white.opacity(0.25)
        }
    }

    private var accessibilityText: String {
        let state: String
        switch health {
        case .healthy:  state = NSLocalizedString("vaultMode.health.healthy",  value: "healthy",         comment: "")
        case .degraded: state = NSLocalizedString("vaultMode.health.degraded", value: "needs attention", comment: "")
        case .stale:    state = NSLocalizedString("vaultMode.health.stale",    value: "stale",           comment: "")
        case .idle:     state = NSLocalizedString("vaultMode.health.idle",     value: "idle",            comment: "")
        }
        return "\(monogram), \(state)"
    }
}

#Preview {
    HStack(spacing: 16) {
        VaultBadge(monogram: "TR", health: .healthy)
        VaultBadge(monogram: "OP", health: .degraded)
        VaultBadge(monogram: "CO", health: .stale)
        VaultBadge(monogram: "AR", health: .idle)
    }
    .padding(40)
    .background(HorcruxTheme.deepBlack)
}

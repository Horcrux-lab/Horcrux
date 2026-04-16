import SwiftUI

/// Circular progress ring used during DKG and signing ceremonies.
struct ProgressRing: View {
    let progress: Double
    var lineWidth: CGFloat = 8
    var color: Color = HorcruxTheme.accentPurple
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.15), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    AngularGradient(
                        colors: [HorcruxTheme.accentPurple, HorcruxTheme.accentBlue, HorcruxTheme.accentCyan],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: progress)

            Text("\(Int(progress * 100))%")
                .font(.title2.bold().monospacedDigit())
                .foregroundStyle(.white)
        }
    }
}

/// Badge showing t-of-n threshold.
struct ShardStatusBadge: View {
    let threshold: UInt16
    let total: UInt16

    var body: some View {
        Text("\(threshold)/\(total)")
            .font(.caption2.bold().monospacedDigit())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(HorcruxTheme.accentPurple.opacity(0.2))
                    .overlay(Capsule().stroke(HorcruxTheme.accentPurple.opacity(0.3), lineWidth: 0.5))
            )
            .foregroundStyle(HorcruxTheme.accentCyan)
    }
}

/// Chain logo icon.
struct ChainIcon: View {
    let chain: Chain
    var size: CGFloat = 32
    @ScaledMetric private var scaledSize: CGFloat = 32

    init(chain: Chain, size: CGFloat = 32) {
        self.chain = chain
        self.size = size
        self._scaledSize = ScaledMetric(wrappedValue: size)
    }

    var body: some View {
        Image(systemName: chain.iconName)
            .font(.system(size: scaledSize * 0.45, weight: .semibold))
            .frame(width: scaledSize, height: scaledSize)
            .background(
                Circle()
                    .fill(chain.color.opacity(0.15))
                    .overlay(Circle().stroke(chain.color.opacity(0.3), lineWidth: 0.5))
            )
            .foregroundStyle(chain.color)
    }
}

// MARK: - PIN Dot Indicator

struct PINDotsView: View {
    let length: Int
    let filled: Int
    var dotSize: CGFloat = 14

    var body: some View {
        HStack(spacing: 12) {
            ForEach(0..<length, id: \.self) { index in
                Circle()
                    .fill(index < filled ? HorcruxTheme.accentPurple : Color.white.opacity(0.15))
                    .frame(width: dotSize, height: dotSize)
                    .overlay(
                        Circle()
                            .stroke(index < filled ? HorcruxTheme.accentPurple.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1)
                    )
                    .shadow(color: index < filled ? HorcruxTheme.accentPurple.opacity(0.5) : .clear, radius: 4)
                    .animation(.spring(response: 0.3), value: filled)
            }
        }
    }
}

// MARK: - Animated Shield Logo

struct AnimatedShieldLogo: View {
    var size: CGFloat = 80
    @State private var glowPulse = false

    var body: some View {
        ZStack {
            // Glow ring
            Circle()
                .fill(
                    RadialGradient(
                        colors: [HorcruxTheme.accentPurple.opacity(0.3), .clear],
                        center: .center,
                        startRadius: size * 0.3,
                        endRadius: size * 0.8
                    )
                )
                .frame(width: size * 1.6, height: size * 1.6)
                .scaleEffect(glowPulse ? 1.1 : 0.9)
                .animation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true), value: glowPulse)

            // Shield icon
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: size, weight: .thin))
                .foregroundStyle(HorcruxTheme.shieldGradient)
                .shadow(color: HorcruxTheme.accentPurple.opacity(0.5), radius: 12)
        }
        .onAppear { glowPulse = true }
    }
}

// MARK: - Vault Settings Row

struct VaultSettingsRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    var subtitle: String? = nil

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 32, height: 32)
                .background(iconColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(HorcruxTheme.subtleText)
                }
            }
        }
    }
}

// MARK: - Empty State View

struct VaultEmptyState: View {
    let icon: String
    let title: String
    let subtitle: String
    var iconSize: CGFloat = 56

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .thin))
                .foregroundStyle(
                    LinearGradient(
                        colors: [HorcruxTheme.accentPurple.opacity(0.6), HorcruxTheme.accentBlue.opacity(0.3)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            VStack(spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(HorcruxTheme.subtleText)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

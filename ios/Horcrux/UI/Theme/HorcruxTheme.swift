import SwiftUI

/// Design tokens for the Horcrux app — "Vault" dark-tech design system.
enum HorcruxTheme {

    // MARK: - Brand Colors

    static let accentColor = Color("AccentColor", bundle: nil)
    static let primaryColor = Color(red: 0.35, green: 0.55, blue: 1.0)

    // Core palette
    static let deepBlack = Color(red: 0.04, green: 0.05, blue: 0.10)       // #0A0E1A
    static let darkNavy  = Color(red: 0.07, green: 0.09, blue: 0.15)       // #111827
    static let cardSurface = Color(red: 0.10, green: 0.12, blue: 0.20)     // #1A1F33
    static let cardBorder = Color.white.opacity(0.08)
    static let hairline = Color.white.opacity(0.06)                        // divider lines on dark surfaces
    static let subtleText = Color.white.opacity(0.5)

    // Accents
    static let accentPurple = Color(red: 0.49, green: 0.23, blue: 0.93)    // #7C3AED
    static let accentBlue   = Color(red: 0.15, green: 0.39, blue: 0.92)    // #2563EB
    static let accentCyan   = Color(red: 0.06, green: 0.82, blue: 0.88)    // #10D0E0
    static let successGreen = Color(red: 0.16, green: 0.84, blue: 0.44)    // #29D770
    static let warningAmber = Color(red: 1.00, green: 0.72, blue: 0.10)    // #FFB81A
    static let dangerRed    = Color(red: 0.96, green: 0.26, blue: 0.35)    // #F54259

    // MARK: - Gradients

    static let backgroundGradient = LinearGradient(
        colors: [deepBlack, darkNavy],
        startPoint: .top,
        endPoint: .bottom
    )

    static let accentGradient = LinearGradient(
        colors: [accentPurple, accentBlue],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let glowGradient = LinearGradient(
        colors: [accentPurple.opacity(0.6), accentBlue.opacity(0.3), .clear],
        startPoint: .top,
        endPoint: .bottom
    )

    static let shieldGradient = LinearGradient(
        colors: [accentPurple, accentCyan],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: - Dimensions

    static let cornerRadius: CGFloat = 16
    static let cardPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 24

    // MARK: - Shadows

    static let glowShadow = Color.purple.opacity(0.25)
    static let softShadow  = Color.black.opacity(0.4)
}

// MARK: - Glass Card Modifier

struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = HorcruxTheme.cornerRadius
    var padding: CGFloat = HorcruxTheme.cardPadding

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(HorcruxTheme.cardSurface.opacity(0.7))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .stroke(HorcruxTheme.cardBorder, lineWidth: 1)
                    )
            )
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = HorcruxTheme.cornerRadius, padding: CGFloat = HorcruxTheme.cardPadding) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius, padding: padding))
    }
}

// MARK: - Gradient Button Style

struct GradientButtonStyle: ButtonStyle {
    var isEnabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                Group {
                    if isEnabled {
                        HorcruxTheme.accentGradient
                    } else {
                        LinearGradient(colors: [Color.gray.opacity(0.3), Color.gray.opacity(0.2)], startPoint: .leading, endPoint: .trailing)
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: isEnabled ? HorcruxTheme.glowShadow : .clear, radius: configuration.isPressed ? 4 : 8, y: 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.3), value: configuration.isPressed)
    }
}

// MARK: - Dark Page Background

struct DarkBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(HorcruxTheme.backgroundGradient.ignoresSafeArea())
            .preferredColorScheme(.dark)
    }
}

extension View {
    func darkBackground() -> some View {
        modifier(DarkBackground())
    }
}

// MARK: - Section Header Style

struct VaultSectionHeader: View {
    let title: String
    let icon: String?

    init(_ title: String, icon: String? = nil) {
        self.title = title
        self.icon = icon
    }

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HorcruxTheme.accentPurple)
            }
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(HorcruxTheme.subtleText)
                .textCase(.uppercase)
                .tracking(1.2)
        }
    }
}

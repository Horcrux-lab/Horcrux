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
        Group {
            if UIImage(named: chain.assetName) != nil {
                Image(chain.assetName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: scaledSize * 0.72, height: scaledSize * 0.72)
                    .clipShape(Circle())
            } else {
                Image(systemName: chain.iconName)
                    .font(.system(size: scaledSize * 0.45, weight: .semibold))
                    .foregroundStyle(chain.color)
            }
        }
        .frame(width: scaledSize, height: scaledSize)
        .background(
            Circle()
                .fill(chain.color.opacity(0.15))
                .overlay(Circle().stroke(chain.color.opacity(0.3), lineWidth: 0.5))
        )
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

/// Unified PIN input: 6 dots visible, SecureField invisible but functional.
/// Tapping the dot row focuses the field. Optionally auto-submits at `length`.
/// Matches iOS-native passcode UX (Coinbase / Rainbow pattern).
struct PinDotsField: View {
    @Binding var pin: String
    var length: Int = 6
    var autoSubmit: Bool = true
    var onComplete: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            // Invisible input receiving keyboard
            SecureField("", text: $pin)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($focused)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .onChange(of: pin) { _, newValue in
                    let digits = newValue.filter(\.isNumber)
                    let clipped = String(digits.prefix(length))
                    if clipped != newValue { pin = clipped; return }
                    if autoSubmit && clipped.count == length {
                        onComplete()
                    }
                }

            // Visible dots — tappable to focus
            PINDotsView(length: length, filled: min(pin.count, length))
                .contentShape(Rectangle())
                .onTapGesture { focused = true }
        }
        .onAppear { focused = true }
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

// MARK: - Dark Form Style

/// Apply to a `Form` (or `List`) to match the Horcrux dark theme.
/// Removes the default system-grouped background and paints the gradient.
extension View {
    func darkFormStyle() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(HorcruxTheme.backgroundGradient.ignoresSafeArea())
    }
}

/// Standard dark row background for `Form`/`List` sections.
struct DarkListRow: ViewModifier {
    func body(content: Content) -> some View {
        content.listRowBackground(HorcruxTheme.cardSurface.opacity(0.5))
    }
}

extension View {
    func darkListRow() -> some View {
        modifier(DarkListRow())
    }
}

// MARK: - Step Progress Bar

/// Compact 1…N step indicator used during multi-step ceremonies (DKG, cold signing).
struct StepProgressBar: View {
    let steps: [String]
    let currentIndex: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(steps.indices, id: \.self) { i in
                let state = stepState(i)
                HStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(state == .done
                                  ? HorcruxTheme.accentPurple
                                  : (state == .current ? HorcruxTheme.accentPurple.opacity(0.25) : Color.white.opacity(0.08)))
                            .frame(width: 22, height: 22)
                            .overlay(
                                Circle().stroke(
                                    state == .current ? HorcruxTheme.accentPurple : Color.white.opacity(0.15),
                                    lineWidth: 1
                                )
                            )
                        if state == .done {
                            Image(systemName: "checkmark")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                        } else {
                            Text("\(i + 1)")
                                .font(.caption2.monospacedDigit().weight(.semibold))
                                .foregroundStyle(state == .current ? .white : HorcruxTheme.subtleText)
                        }
                    }
                    if i == currentIndex {
                        Text(steps[i])
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                }
                if i < steps.count - 1 {
                    Rectangle()
                        .fill(state == .done ? HorcruxTheme.accentPurple : Color.white.opacity(0.1))
                        .frame(height: 1)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(HorcruxTheme.cardSurface.opacity(0.4))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(currentIndex + 1) of \(steps.count): \(steps[currentIndex])")
    }

    private enum StepState { case done, current, pending }

    private func stepState(_ i: Int) -> StepState {
        if i < currentIndex { return .done }
        if i == currentIndex { return .current }
        return .pending
    }
}

// MARK: - PIN Unlock Sheet

/// Themed PIN entry sheet used before signing/decryption. Replaces the
/// system `.alert { SecureField }` variant so the keypad and error UI
/// match `LockScreenView`.
struct PinUnlockSheet: View {
    let title: String
    let subtitle: String
    /// Called with the entered PIN. Return `nil` on success (sheet dismisses),
    /// or a localized error string to display + reset the field.
    let onSubmit: (String) -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var pin: String = ""
    @State private var errorMessage: String?
    @State private var shakeOffset: CGFloat = 0

    var body: some View {
        ZStack {
            HorcruxTheme.backgroundGradient.ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                AnimatedShieldLogo(size: 48)

                VStack(spacing: 6) {
                    Text(title)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)

                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(HorcruxTheme.subtleText)
                        .multilineTextAlignment(.center)
                }

                PinDotsField(pin: $pin, length: 6, autoSubmit: true, onComplete: submit)
                    .offset(x: shakeOffset)
                    .accessibilityLabel(L10n.Common.pin)
                    .accessibilityIdentifier("pinUnlockSheet_pinField")

                if let errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                        Text(errorMessage)
                            .font(.caption)
                    }
                    .foregroundStyle(HorcruxTheme.dangerRed)
                    .transition(.opacity)
                }

                Button(L10n.LockScreen.unlock) { submit() }
                    .buttonStyle(GradientButtonStyle(isEnabled: pin.count >= 6))
                    .disabled(pin.count < 6)
                    .padding(.horizontal, 32)
                    .accessibilityIdentifier("pinUnlockSheet_unlockButton")

                Button(L10n.Common.cancel) { dismiss() }
                    .foregroundStyle(HorcruxTheme.subtleText)
                    .accessibilityIdentifier("pinUnlockSheet_cancelButton")

                Spacer()
            }
            .padding(.horizontal, 32)
        }
        .preferredColorScheme(.dark)
    }

    private func submit() {
        if let err = onSubmit(pin) {
            errorMessage = err
            pin = ""
            Haptics.error()
            triggerShake()
        } else {
            Haptics.success()
            dismiss()
        }
    }

    private func triggerShake() {
        withAnimation(.default) { shakeOffset = -12 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.default) { shakeOffset = 12 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(.spring(response: 0.2)) { shakeOffset = 0 }
        }
    }
}

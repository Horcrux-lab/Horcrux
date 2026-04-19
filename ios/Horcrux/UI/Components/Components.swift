import SwiftUI

/// Circular progress ring used during DKG and signing ceremonies.
struct ProgressRing: View {
    let progress: Double
    var lineWidth: CGFloat = 8
    var color: Color = HorcruxTheme.accentPurple
    /// Optional solid tint for the ring stroke. When non-nil, replaces the
    /// default purple/blue/cyan angular gradient with a solid-color stroke
    /// — used to tie signing/DKG ceremonies to the chain's brand color.
    var tint: Color? = nil
    /// Whether to render the "NN%" label in the centre. Callers that
    /// overlay their own glyph (e.g. chain logo, key) should pass false
    /// so the label doesn't collide with the overlay.
    var showPercentage: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke((tint ?? color).opacity(0.15), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    ringStrokeStyle,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: progress)

            if showPercentage {
                Text("\(Int(progress * 100))%")
                    .font(.title2.bold().monospacedDigit())
                    .foregroundStyle(.white)
            }
        }
    }

    private var ringStrokeStyle: AnyShapeStyle {
        if let tint {
            return AnyShapeStyle(
                AngularGradient(
                    colors: [tint.opacity(0.55), tint, tint.opacity(0.85)],
                    center: .center
                )
            )
        }
        return AnyShapeStyle(
            AngularGradient(
                colors: [HorcruxTheme.accentPurple, HorcruxTheme.accentBlue, HorcruxTheme.accentCyan],
                center: .center
            )
        )
    }
}

/// Ritual visualization: N shard dots orbiting the progress ring, one per
/// MPC signer. Dots rotate slowly while the ceremony is active; each
/// completes (green) or fails (red) as the peer reports its state.
/// Gives the otherwise opaque MPC round-trip visible rhythm and ties the
/// abstract "t-of-n" badge to a physical metaphor.
struct ShardOrbit: View {
    enum DotState { case waiting, active, done, failed }
    let total: Int
    /// One entry per shard; positional index maps to clock-angle starting
    /// at 12 o'clock and going clockwise.
    let states: [DotState]
    var radius: CGFloat
    var tint: Color = HorcruxTheme.accentPurple
    var dotSize: CGFloat = 14

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: Double = 0

    var body: some View {
        ZStack {
            ForEach(0..<total, id: \.self) { i in
                let baseAngle = Double(i) / Double(max(total, 1)) * 360.0
                let angle = baseAngle + phase
                let rad = angle * .pi / 180
                Circle()
                    .fill(color(for: i))
                    .frame(width: dotSize, height: dotSize)
                    .overlay(
                        Circle()
                            .stroke(color(for: i).opacity(0.5), lineWidth: 1)
                    )
                    .shadow(color: color(for: i).opacity(0.6), radius: 4)
                    .offset(x: CGFloat(cos(rad)) * radius,
                            y: CGFloat(sin(rad)) * radius)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 18).repeatForever(autoreverses: false)) {
                phase = 360
            }
        }
        .accessibilityHidden(true)
    }

    private func color(for index: Int) -> Color {
        guard index < states.count else { return tint.opacity(0.3) }
        switch states[index] {
        case .waiting: return tint.opacity(0.35)
        case .active:  return tint
        case .done:    return HorcruxTheme.successGreen
        case .failed:  return HorcruxTheme.dangerRed
        }
    }
}

/// Compact 24h percent-change pill. Green for gains, red for losses,
/// neutral gray when change is within ±0.05% (effectively flat).
/// Uses monospaced digits so columns don't jitter between refreshes.
struct PriceChangeBadge: View {
    let percent: Double

    private var color: Color {
        if percent > 0.05 { return HorcruxTheme.successGreen }
        if percent < -0.05 { return .red }
        return HorcruxTheme.subtleText
    }

    private var arrow: String {
        if percent > 0.05 { return "arrow.up" }
        if percent < -0.05 { return "arrow.down" }
        return "minus"
    }

    private var text: String {
        let abs = Swift.abs(percent)
        let formatted = String(format: "%.2f%%", abs)
        return formatted
    }

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: arrow)
                .font(.system(size: 8, weight: .bold))
            Text(text)
                .font(.caption2.bold().monospacedDigit())
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(color.opacity(0.15))
        )
        .accessibilityLabel("24 hour change \(percent >= 0 ? "up" : "down") \(text)")
    }
}

/// Minimal 24h portfolio sparkline. Draws a smooth polyline over the
/// normalized values, plus a soft gradient fill under the line tinted
/// with the trend direction (green if rising, red if falling).
struct Sparkline: View {
    let values: [Double]
    var height: CGFloat = 32

    private var isUp: Bool {
        guard let first = values.first, let last = values.last else { return true }
        return last >= first
    }
    private var color: Color {
        isUp ? HorcruxTheme.successGreen : .red
    }

    var body: some View {
        GeometryReader { geo in
            if values.count >= 2,
               let minV = values.min(), let maxV = values.max(), maxV > minV {
                let w = geo.size.width
                let h = geo.size.height
                let step = w / CGFloat(values.count - 1)
                let range = maxV - minV
                let points: [CGPoint] = values.enumerated().map { i, v in
                    CGPoint(x: CGFloat(i) * step,
                            y: h - CGFloat((v - minV) / range) * h)
                }
                ZStack {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: h))
                        for pt in points { p.addLine(to: pt) }
                        p.addLine(to: CGPoint(x: w, y: h))
                        p.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.35), color.opacity(0.0)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    Path { p in
                        p.move(to: points[0])
                        for pt in points.dropFirst() { p.addLine(to: pt) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                }
            } else {
                // Flat placeholder line
                Path { p in
                    p.move(to: CGPoint(x: 0, y: geo.size.height / 2))
                    p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height / 2))
                }
                .stroke(HorcruxTheme.subtleText.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
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

/// Unified PIN dots + numeric keypad. 6 dots fill as the user taps digits,
/// delete shrinks, auto-submits when full length reached. No system keyboard —
/// 100% visible and discoverable.
struct PinDotsField: View {
    @Binding var pin: String
    var length: Int = 6
    var autoSubmit: Bool = true
    var onComplete: () -> Void = {}
    var biometricIcon: String? = nil
    var onBiometric: (() -> Void)? = nil
    var dotsShakeOffset: CGFloat = 0

    var body: some View {
        VStack(spacing: 28) {
            PINDotsView(length: length, filled: min(pin.count, length))
                .offset(x: dotsShakeOffset)

            PinKeypad(
                pin: $pin,
                length: length,
                onComplete: { if autoSubmit { onComplete() } },
                biometricIcon: biometricIcon,
                onBiometric: onBiometric
            )
        }
    }
}

/// Self-contained numeric keypad for PIN entry. Rows 1-3, then 4-6, 7-9,
/// `bio?` · 0 · ⌫. Tapping a digit appends (up to `length`), `⌫` deletes
/// one char. Auto-submits via `onComplete` when `length` reached.
///
/// Using this avoids the iOS system keyboard (which covers half the screen
/// and ships its own number row layout) and keeps PIN entry fully visible
/// and discoverable on the locked screen.
struct PinKeypad: View {
    @Binding var pin: String
    var length: Int = 6
    var onComplete: () -> Void = {}
    var biometricIcon: String? = nil
    var onBiometric: (() -> Void)? = nil

    private let digitRows: [[String]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"]
    ]

    var body: some View {
        VStack(spacing: 16) {
            ForEach(digitRows, id: \.self) { row in
                HStack(spacing: 24) {
                    ForEach(row, id: \.self) { digit in
                        keyButton(label: digit) { append(digit) }
                    }
                }
            }
            HStack(spacing: 24) {
                if let icon = biometricIcon, let action = onBiometric {
                    keyButton(icon: icon, accessibility: L10n.LockScreen.useFaceID, action: action)
                } else {
                    Color.clear.frame(width: 72, height: 72)
                }
                keyButton(label: "0") { append("0") }
                keyButton(icon: "delete.left", accessibility: "Delete", disabled: pin.isEmpty) {
                    if !pin.isEmpty {
                        pin.removeLast()
                        Haptics.selection()
                    }
                }
            }
        }
    }

    private func append(_ digit: String) {
        guard pin.count < length else { return }
        pin.append(digit)
        Haptics.selection()
        if pin.count == length {
            onComplete()
        }
    }

    @ViewBuilder
    private func keyButton(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 30, weight: .regular, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private func keyButton(icon: String, accessibility: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(disabled ? Color.white.opacity(0.2) : .white)
                .frame(width: 72, height: 72)
                .contentShape(Circle())
        }
        .disabled(disabled)
        .accessibilityLabel(accessibility)
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

// MARK: - Disclosure Indicator

/// Chevron used as the trailing affordance on VaultSettingsRow-style
/// navigation links. Centralised so nine copies of
/// `Image("chevron.right").font(.caption).foregroundStyle(subtleText)`
/// don't drift apart over time.
struct VaultDisclosureIndicator: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption)
            .foregroundStyle(HorcruxTheme.subtleText)
            .accessibilityHidden(true)
    }
}

// MARK: - Vault Text Field

/// Text-field presentation used across Settings: hairline fill, white
/// stroke, monospaced caption, purple tint. Replaces the two hand-rolled
/// copies in SettingsView (relay URL + device nickname).
struct VaultTextField: View {
    @Binding var text: String
    var placeholder: String = ""
    var monospaced: Bool = true
    var isSecure: Bool = false
    var keyboardType: UIKeyboardType = .default
    var autocapitalization: TextInputAutocapitalization = .never

    var body: some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .font(monospaced ? .system(.caption, design: .monospaced) : .system(.caption))
        .autocorrectionDisabled()
        .textInputAutocapitalization(autocapitalization)
        .keyboardType(keyboardType)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(HorcruxTheme.hairline)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1), lineWidth: 1))
        )
        .foregroundStyle(.white)
        .tint(HorcruxTheme.accentPurple)
    }
}

// MARK: - Empty State View

struct VaultEmptyState: View {
    let icon: String
    let title: String
    let subtitle: String
    var iconSize: CGFloat = 96

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [HorcruxTheme.accentPurple.opacity(0.35), .clear],
                            center: .center,
                            startRadius: iconSize * 0.3,
                            endRadius: iconSize * 1.3
                        )
                    )
                    .frame(width: iconSize * 2.2, height: iconSize * 2.2)

                Image(systemName: icon)
                    .font(.system(size: iconSize, weight: .regular))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [HorcruxTheme.accentPurple, HorcruxTheme.accentCyan],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: HorcruxTheme.accentPurple.opacity(0.4), radius: 18, y: 6)
            }

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

                PinDotsField(
                    pin: $pin,
                    length: 6,
                    autoSubmit: true,
                    onComplete: submit,
                    dotsShakeOffset: shakeOffset
                )
                .accessibilityLabel(L10n.Common.pin)
                .accessibilityIdentifier("pinUnlockSheet_pinField")

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

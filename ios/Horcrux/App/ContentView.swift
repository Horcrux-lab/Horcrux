import SwiftUI

/// Root navigation — tab bar with wallet, shards, and settings.
struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showJailbreakWarning = false
    @State private var jailbreakReasons: [String] = []

    var body: some View {
        Group {
            if appState.isFirstLaunch {
                OnboardingView()
            } else if appState.isUnlocked {
                MainTabView()
            } else {
                LockScreenView()
            }
        }
        .alert(L10n.App.securityWarning, isPresented: $showJailbreakWarning) {
            Button(L10n.App.understandRisk, role: .destructive) {}
        } message: {
            Text("This device may be compromised:\n\n• \(jailbreakReasons.joined(separator: "\n• "))\n\n\(L10n.App.deviceCompromised)")
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .task {
            #if targetEnvironment(simulator)
            // Simulator always triggers jailbreak detection — skip
            #else
            guard !ProcessInfo.processInfo.arguments.contains("-UITesting") else { return }
            let result = SecurityEnvironment.check()
            if result.isCompromised {
                jailbreakReasons = result.reasons
                showJailbreakWarning = true
            }
            #endif
        }
    }
}

struct MainTabView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            WalletHomeView()
                .tabItem {
                    Image(systemName: selectedTab == 0 ? "creditcard.fill" : "creditcard")
                    Text(L10n.Tab.wallet)
                }
                .tag(0)

            ShardsListView()
                .tabItem {
                    Image(systemName: selectedTab == 1 ? "shield.lefthalf.filled" : "shield")
                    Text(L10n.Tab.shards)
                }
                .tag(1)

            SettingsView()
                .tabItem {
                    Image(systemName: selectedTab == 2 ? "gearshape.fill" : "gearshape")
                    Text(L10n.Tab.settings)
                }
                .tag(2)
        }
        .tint(HorcruxTheme.accentPurple)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Onboarding (first-run PIN setup)

struct OnboardingView: View {
    @EnvironmentObject private var appState: AppState
    @State private var pin: String = ""
    @State private var confirmPin: String = ""
    @State private var step: OnboardingStep = .welcome
    @State private var animateIn = false

    enum OnboardingStep {
        case welcome, createPin, confirmPin
    }

    var body: some View {
        ZStack {
            HorcruxTheme.backgroundGradient.ignoresSafeArea()

            // Subtle radial glow at top
            VStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [HorcruxTheme.accentPurple.opacity(0.15), .clear],
                            center: .center,
                            startRadius: 20,
                            endRadius: 250
                        )
                    )
                    .frame(width: 500, height: 500)
                    .offset(y: -150)
                Spacer()
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                switch step {
                case .welcome:
                    welcomeContent
                case .createPin:
                    createPinContent
                case .confirmPin:
                    confirmPinContent
                }

                Spacer()

                // Step indicator
                HStack(spacing: 8) {
                    ForEach(0..<3) { i in
                        Capsule()
                            .fill(stepIndex >= i ? HorcruxTheme.accentPurple : Color.white.opacity(0.15))
                            .frame(width: stepIndex == i ? 24 : 8, height: 8)
                            .animation(.spring(response: 0.4), value: step)
                    }
                }
                .padding(.bottom, 32)
            }
            .padding(.horizontal, 32)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.8)) { animateIn = true }
        }
    }

    private var stepIndex: Int {
        switch step {
        case .welcome: return 0
        case .createPin: return 1
        case .confirmPin: return 2
        }
    }

    // MARK: - Welcome

    private var welcomeContent: some View {
        VStack(spacing: 32) {
            AnimatedShieldLogo(size: 72)
                .opacity(animateIn ? 1 : 0)
                .offset(y: animateIn ? 0 : 20)

            VStack(spacing: 12) {
                Text(L10n.Onboarding.welcomeTitle)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text(L10n.Onboarding.welcomeSubtitle)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(HorcruxTheme.subtleText)
                    .lineSpacing(4)
            }
            .opacity(animateIn ? 1 : 0)
            .offset(y: animateIn ? 0 : 10)

            Button(L10n.Onboarding.getStarted) {
                withAnimation(.spring(response: 0.5)) { step = .createPin }
            }
            .buttonStyle(GradientButtonStyle())
            .accessibilityHint(L10n.Onboarding.getStartedHint)
            .accessibilityIdentifier("onboarding_getStartedButton")
            .opacity(animateIn ? 1 : 0)
        }
    }

    // MARK: - Create PIN

    private var createPinContent: some View {
        VStack(spacing: 32) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(HorcruxTheme.shieldGradient)
                .shadow(color: HorcruxTheme.accentPurple.opacity(0.4), radius: 8)

            VStack(spacing: 8) {
                Text(L10n.Onboarding.createPin)
                    .font(.title2.bold())
                    .foregroundStyle(.white)

                Text(L10n.Onboarding.pinProtects)
                    .font(.subheadline)
                    .foregroundStyle(HorcruxTheme.subtleText)
                    .multilineTextAlignment(.center)
            }

            PINDotsView(length: 6, filled: min(pin.count, 6))
                .padding(.vertical, 8)

            SecureField(L10n.Onboarding.enterPinPlaceholder, text: $pin)
                .keyboardType(.numberPad)
                .font(.title3.monospacedDigit())
                .multilineTextAlignment(.center)
                .padding(.vertical, 14)
                .padding(.horizontal, 20)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 1))
                )
                .frame(maxWidth: 200)
                .foregroundStyle(.white)
                .tint(HorcruxTheme.accentPurple)
                .accessibilityLabel(L10n.Onboarding.createPin)
                .accessibilityHint(L10n.Onboarding.createPinHint)
                .accessibilityIdentifier("onboarding_createPinField")

            Button(L10n.Common.next) {
                withAnimation(.spring(response: 0.5)) { step = .confirmPin }
            }
            .buttonStyle(GradientButtonStyle(isEnabled: pin.count >= 4))
            .disabled(pin.count < 4)
            .accessibilityHint(L10n.Onboarding.nextHint)
            .accessibilityIdentifier("onboarding_nextButton")
        }
        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
    }

    // MARK: - Confirm PIN

    private var confirmPinContent: some View {
        VStack(spacing: 32) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(HorcruxTheme.shieldGradient)
                .shadow(color: HorcruxTheme.accentPurple.opacity(0.4), radius: 8)

            VStack(spacing: 8) {
                Text(L10n.Onboarding.confirmPin)
                    .font(.title2.bold())
                    .foregroundStyle(.white)

                Text(L10n.Onboarding.enterSamePin)
                    .font(.subheadline)
                    .foregroundStyle(HorcruxTheme.subtleText)
                    .multilineTextAlignment(.center)
            }

            PINDotsView(length: 6, filled: min(confirmPin.count, 6))
                .padding(.vertical, 8)

            SecureField(L10n.Onboarding.confirmPin, text: $confirmPin)
                .keyboardType(.numberPad)
                .font(.title3.monospacedDigit())
                .multilineTextAlignment(.center)
                .padding(.vertical, 14)
                .padding(.horizontal, 20)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(!confirmPin.isEmpty && confirmPin != pin ? HorcruxTheme.dangerRed.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1)
                        )
                )
                .frame(maxWidth: 200)
                .foregroundStyle(.white)
                .tint(HorcruxTheme.accentPurple)
                .accessibilityLabel(L10n.Onboarding.confirmPin)
                .accessibilityHint(L10n.Onboarding.confirmPinHint)
                .accessibilityIdentifier("onboarding_confirmPinField")

            if !confirmPin.isEmpty && confirmPin != pin {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                    Text(L10n.Onboarding.pinsDontMatch)
                        .font(.caption)
                }
                .foregroundStyle(HorcruxTheme.dangerRed)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            Button(L10n.Onboarding.createWallet) {
                guard pin == confirmPin else { return }
                try? appState.setPin(pin)
                appState.isUnlocked = true
                #if !targetEnvironment(simulator)
                Task { await NotificationManager.shared.requestAuthorization() }
                #endif
            }
            .buttonStyle(GradientButtonStyle(isEnabled: confirmPin.count >= 4 && pin == confirmPin))
            .disabled(confirmPin.count < 4 || pin != confirmPin)
            .accessibilityHint(L10n.Onboarding.createWalletHint)
            .accessibilityIdentifier("onboarding_createWalletButton")
        }
        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
    }
}

// MARK: - Lock Screen

struct LockScreenView: View {
    @EnvironmentObject private var appState: AppState
    @State private var pin: String = ""
    @State private var errorMessage: String?
    @State private var attemptedBiometric = false
    @State private var shakeOffset: CGFloat = 0

    var body: some View {
        ZStack {
            HorcruxTheme.backgroundGradient.ignoresSafeArea()

            // Top glow
            VStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [HorcruxTheme.accentPurple.opacity(0.12), .clear],
                            center: .center,
                            startRadius: 20,
                            endRadius: 200
                        )
                    )
                    .frame(width: 400, height: 400)
                    .offset(y: -120)
                Spacer()
            }
            .ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                AnimatedShieldLogo(size: 56)

                Text(L10n.LockScreen.title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text(L10n.LockScreen.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(HorcruxTheme.subtleText)

                PINDotsView(length: 6, filled: min(pin.count, 6))
                    .offset(x: shakeOffset)
                    .padding(.vertical, 4)

                SecureField(L10n.Common.pin, text: $pin)
                    .keyboardType(.numberPad)
                    .font(.title3.monospacedDigit())
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 20)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.white.opacity(0.06))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 1))
                    )
                    .frame(maxWidth: 200)
                    .foregroundStyle(.white)
                    .tint(HorcruxTheme.accentPurple)
                    .onSubmit { unlock() }
                    .accessibilityLabel(L10n.Common.pin)
                    .accessibilityHint(L10n.LockScreen.pinHint)
                    .accessibilityIdentifier("lockScreen_pinField")

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

                Button(L10n.LockScreen.unlock) { unlock() }
                    .buttonStyle(GradientButtonStyle(isEnabled: pin.count >= 4))
                    .disabled(pin.count < 4)
                    .padding(.horizontal, 32)
                    .accessibilityLabel(L10n.LockScreen.unlock)
                    .accessibilityHint(L10n.LockScreen.unlockHint)
                    .accessibilityIdentifier("lockScreen_unlockButton")

                if UserDefaults.standard.bool(forKey: "biometricEnabled"),
                   BiometricAuth.shared.availableType != .none {
                    Button {
                        unlockBiometric()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "faceid")
                                .font(.title3)
                            Text(L10n.LockScreen.useFaceID)
                                .font(.subheadline.weight(.medium))
                        }
                        .foregroundStyle(HorcruxTheme.accentPurple)
                    }
                    .accessibilityLabel(L10n.LockScreen.useFaceID)
                    .accessibilityHint(L10n.LockScreen.unlockBiometricHint)
                    .accessibilityIdentifier("lockScreen_biometricButton")
                }

                Spacer()
            }
            .padding(.horizontal, 32)
        }
    }

    private func unlock() {
        if appState.isLockedOut {
            let secs = Int(appState.lockoutRemaining)
            errorMessage = L10n.LockScreen.tooManyAttempts(secs)
            pin = ""
            triggerShake()
            return
        }
        if appState.verifyPin(pin) {
            errorMessage = nil
            appState.isUnlocked = true
        } else {
            let remaining = AppState.maxFailedAttempts - appState.failedAttempts
            if remaining > 0 {
                errorMessage = L10n.LockScreen.incorrectPin(remaining)
            } else {
                errorMessage = L10n.LockScreen.dataWiped
            }
            pin = ""
            triggerShake()
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

    private func unlockBiometric() {
        Task { await tryBiometricUnlock() }
    }

    private func tryBiometricUnlock() async {
        guard UserDefaults.standard.bool(forKey: "biometricEnabled") else { return }
        guard BiometricAuth.shared.availableType != .none else { return }
        let success = await BiometricAuth.shared.authenticate()
        if success {
            appState.isUnlocked = true
        }
    }
}

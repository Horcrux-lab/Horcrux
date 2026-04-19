import SwiftUI

/// Root navigation — tab bar with wallet, shards, and settings.
struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showJailbreakWarning = false
    @State private var jailbreakReasons: [String] = []

    private var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("-UITesting")
    }

    private var isDKGTest: Bool {
        ProcessInfo.processInfo.arguments.contains("-DKGTest")
    }

    var body: some View {
        Group {
            if isDKGTest {
                // Auto-run DKG ceremony for testing
                DKGTestView()
                    .environmentObject(appState)
            } else if isUITesting {
                // Skip onboarding and lock screen for UI testing
                MainTabView()
                    .task { appState.isUnlocked = true }
            } else if appState.isFirstLaunch {
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
        .copyToastOverlay()
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
        case welcome, valueProp1, valueProp2, valueProp3, createPin, confirmPin
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            switch step {
            case .welcome:
                welcomeContent
            case .valueProp1:
                valuePropPage(
                    icon: "shield.lefthalf.filled",
                    title: L10n.OnboardingCards.card1Title,
                    subtitle: L10n.OnboardingCards.card1Subtitle
                )
            case .valueProp2:
                valuePropPage(
                    icon: "iphone.and.arrow.forward",
                    title: L10n.OnboardingCards.card2Title,
                    subtitle: L10n.OnboardingCards.card2Subtitle
                )
            case .valueProp3:
                valuePropPage(
                    icon: "arrow.triangle.2.circlepath.circle.fill",
                    title: L10n.OnboardingCards.card3Title,
                    subtitle: L10n.OnboardingCards.card3Subtitle
                )
            case .createPin:
                createPinContent
            case .confirmPin:
                confirmPinContent
            }

            Spacer()

            // Step indicator
            HStack(spacing: 8) {
                ForEach(0..<6) { i in
                    Capsule()
                        .fill(stepIndex >= i ? HorcruxTheme.accentPurple : Color.white.opacity(0.15))
                        .frame(width: stepIndex == i ? 24 : 8, height: 8)
                        .animation(.spring(response: 0.4), value: step)
                }
            }
            .padding(.bottom, 32)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HorcruxTheme.backgroundGradient.ignoresSafeArea())
        .background(alignment: .top) {
            // Subtle radial glow at top. Placed in `.background` so its
            // intrinsic 500pt width does not widen the layout and push
            // siblings (button bars, body text) past the screen edges.
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
                .allowsHitTesting(false)
        }
        .clipped()
        .ignoresSafeArea(edges: .top)
        .onAppear {
            withAnimation(.easeOut(duration: 0.8)) { animateIn = true }
        }
    }

    private var stepIndex: Int {
        switch step {
        case .welcome: return 0
        case .valueProp1: return 1
        case .valueProp2: return 2
        case .valueProp3: return 3
        case .createPin: return 4
        case .confirmPin: return 5
        }
    }

    @ViewBuilder
    private func valuePropPage(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 32) {
            Image(systemName: icon)
                .font(.system(size: 64, weight: .thin))
                .foregroundStyle(HorcruxTheme.shieldGradient)
                .shadow(color: HorcruxTheme.accentPurple.opacity(0.4), radius: 10)

            VStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text(subtitle)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(HorcruxTheme.subtleText)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)

            Button(L10n.OnboardingCards.continueBtn) {
                withAnimation(.spring(response: 0.5)) {
                    switch step {
                    case .valueProp1: step = .valueProp2
                    case .valueProp2: step = .valueProp3
                    case .valueProp3: step = .createPin
                    default: break
                    }
                }
            }
            .buttonStyle(GradientButtonStyle())
        }
        .frame(maxWidth: .infinity)
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
                withAnimation(.spring(response: 0.5)) { step = .valueProp1 }
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

            PinDotsField(
                pin: $pin,
                length: 6,
                autoSubmit: true,
                onComplete: { withAnimation(.spring(response: 0.5)) { step = .confirmPin } }
            )
            .padding(.vertical, 8)
            .accessibilityLabel(L10n.Onboarding.createPin)
            .accessibilityHint(L10n.Onboarding.createPinHint)
            .accessibilityIdentifier("onboarding_createPinField")
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

            PinDotsField(
                pin: $confirmPin,
                length: 6,
                autoSubmit: true,
                onComplete: finishOnboarding
            )
            .padding(.vertical, 8)
            .accessibilityLabel(L10n.Onboarding.confirmPin)
            .accessibilityHint(L10n.Onboarding.confirmPinHint)
            .accessibilityIdentifier("onboarding_confirmPinField")

            if !confirmPin.isEmpty && confirmPin.count == 6 && confirmPin != pin {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                    Text(L10n.Onboarding.pinsDontMatch)
                        .font(.caption)
                }
                .foregroundStyle(HorcruxTheme.dangerRed)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
    }

    private func finishOnboarding() {
        guard pin == confirmPin else {
            Haptics.error()
            confirmPin = ""
            return
        }
        try? appState.setPin(pin)
        appState.isUnlocked = true
        #if !targetEnvironment(simulator)
        Task { await NotificationManager.shared.requestAuthorization() }
        #endif
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
                    onComplete: unlock,
                    biometricIcon: bioIconName,
                    onBiometric: bioIconName == nil ? nil : unlockBiometric,
                    dotsShakeOffset: shakeOffset
                )
                .padding(.vertical, 4)
                .accessibilityLabel(L10n.Common.pin)
                .accessibilityHint(L10n.LockScreen.pinHint)
                .accessibilityIdentifier("lockScreen_pinField")

                Spacer()
            }
            .padding(.horizontal, 32)
        }
    }

    /// Face ID / Touch ID icon for the keypad, if enabled and available.
    private var bioIconName: String? {
        guard UserDefaults.standard.bool(forKey: "biometricEnabled") else { return nil }
        switch BiometricAuth.shared.availableType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .none: return nil
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
            Haptics.success()
            appState.isUnlocked = true
        } else {
            let remaining = AppState.maxFailedAttempts - appState.failedAttempts
            if remaining > 0 {
                errorMessage = L10n.LockScreen.incorrectPin(remaining)
            } else {
                errorMessage = L10n.LockScreen.dataWiped
            }
            pin = ""
            Haptics.error()
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
            // Unwrap the Shard Wrap Key via the SE-sealed copy so the user
            // won't be asked for the PIN again when signing. If no sealed
            // copy exists yet (older install), the SWK cache stays nil and
            // the signing flow falls back to the PIN prompt.
            _ = await appState.unlockShardKeyWithBiometric()
            appState.isUnlocked = true
            Haptics.success()
        }
    }
}

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
            guard !ProcessInfo.processInfo.arguments.contains("-UITesting") else { return }
            let result = SecurityEnvironment.check()
            if result.isCompromised {
                jailbreakReasons = result.reasons
                showJailbreakWarning = true
            }
        }
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            WalletHomeView()
                .tabItem {
                    Label(L10n.Tab.wallet, systemImage: "creditcard.fill")
                }

            ShardsListView()
                .tabItem {
                    Label(L10n.Tab.shards, systemImage: "shield.lefthalf.filled")
                }

            SettingsView()
                .tabItem {
                    Label(L10n.Tab.settings, systemImage: "gear")
                }
        }
        .tint(HorcruxTheme.accentColor)
    }
}

// MARK: - Onboarding (first-run PIN setup)

struct OnboardingView: View {
    @EnvironmentObject private var appState: AppState
    @State private var pin: String = ""
    @State private var confirmPin: String = ""
    @State private var step: OnboardingStep = .welcome
    @ScaledMetric(relativeTo: .largeTitle) private var logoSize: CGFloat = 72

    enum OnboardingStep {
        case welcome, createPin, confirmPin
    }

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: logoSize))
                .foregroundStyle(HorcruxTheme.accentColor)
                .accessibilityHidden(true)

            switch step {
            case .welcome:
                VStack(spacing: 12) {
                    Text(L10n.Onboarding.welcomeTitle)
                        .font(.largeTitle.bold())
                    Text(L10n.Onboarding.welcomeSubtitle)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }

                Button(L10n.Onboarding.getStarted) { step = .createPin }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint(L10n.Onboarding.getStartedHint)
                    .accessibilityIdentifier("onboarding_getStartedButton")

            case .createPin:
                VStack(spacing: 12) {
                    Text(L10n.Onboarding.createPin)
                        .font(.title2.bold())
                    Text(L10n.Onboarding.pinProtects)
                        .foregroundStyle(.secondary)
                }

                SecureField(L10n.Onboarding.enterPinPlaceholder, text: $pin)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                    .multilineTextAlignment(.center)
                    .accessibilityLabel(L10n.Onboarding.createPin)
                    .accessibilityHint(L10n.Onboarding.createPinHint)
                    .accessibilityIdentifier("onboarding_createPinField")

                Button(L10n.Common.next) {
                    step = .confirmPin
                }
                .buttonStyle(.borderedProminent)
                .disabled(pin.count < 4)
                .accessibilityHint(L10n.Onboarding.nextHint)
                .accessibilityIdentifier("onboarding_nextButton")

            case .confirmPin:
                VStack(spacing: 12) {
                    Text(L10n.Onboarding.confirmPin)
                        .font(.title2.bold())
                    Text(L10n.Onboarding.enterSamePin)
                        .foregroundStyle(.secondary)
                }

                SecureField(L10n.Onboarding.confirmPin, text: $confirmPin)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                    .multilineTextAlignment(.center)
                    .accessibilityLabel(L10n.Onboarding.confirmPin)
                    .accessibilityHint(L10n.Onboarding.confirmPinHint)
                    .accessibilityIdentifier("onboarding_confirmPinField")

                if !confirmPin.isEmpty && confirmPin != pin {
                    Text(L10n.Onboarding.pinsDontMatch)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button(L10n.Onboarding.createWallet) {
                    guard pin == confirmPin else { return }
                    try? appState.setPin(pin)
                    appState.isUnlocked = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(confirmPin.count < 4 || pin != confirmPin)
                .accessibilityHint(L10n.Onboarding.createWalletHint)
                .accessibilityIdentifier("onboarding_createWalletButton")
            }

            Spacer()
        }
        .padding()
    }
}

// MARK: - Lock Screen

struct LockScreenView: View {
    @EnvironmentObject private var appState: AppState
    @State private var pin: String = ""
    @State private var errorMessage: String?
    @State private var attemptedBiometric = false
    @ScaledMetric(relativeTo: .largeTitle) private var logoSize: CGFloat = 72

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: logoSize))
                .foregroundStyle(HorcruxTheme.accentColor)
                .accessibilityHidden(true)

            Text(L10n.LockScreen.title)
                .font(.largeTitle.bold())

            Text(L10n.LockScreen.subtitle)
                .foregroundStyle(.secondary)

            SecureField(L10n.Common.pin, text: $pin)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
                .multilineTextAlignment(.center)
                .onSubmit { unlock() }
                .accessibilityLabel(L10n.Common.pin)
                .accessibilityHint(L10n.LockScreen.pinHint)
                .accessibilityIdentifier("lockScreen_pinField")

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel(errorMessage)
            }

            Button(L10n.LockScreen.unlock) { unlock() }
                .buttonStyle(.borderedProminent)
                .disabled(pin.count < 4)
                .accessibilityLabel(L10n.LockScreen.unlock)
                .accessibilityHint(L10n.LockScreen.unlockHint)
                .accessibilityIdentifier("lockScreen_unlockButton")

            if UserDefaults.standard.bool(forKey: "biometricEnabled"),
               BiometricAuth.shared.availableType != .none {
                Button(L10n.LockScreen.useFaceID) { unlockBiometric() }
                    .foregroundStyle(HorcruxTheme.accentColor)
                    .accessibilityLabel(L10n.LockScreen.useFaceID)
                    .accessibilityHint(L10n.LockScreen.unlockBiometricHint)
                    .accessibilityIdentifier("lockScreen_biometricButton")
            }

            Spacer()
        }
        .padding()
        .task {
            if !attemptedBiometric {
                attemptedBiometric = true
                await tryBiometricUnlock()
            }
        }
    }

    private func unlock() {
        if appState.isLockedOut {
            let secs = Int(appState.lockoutRemaining)
            errorMessage = L10n.LockScreen.tooManyAttempts(secs)
            pin = ""
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
        }
    }

    private func unlockBiometric() {
        Task { await tryBiometricUnlock() }
    }

    private func tryBiometricUnlock() async {
        // Respect user's biometric toggle in Settings
        guard UserDefaults.standard.bool(forKey: "biometricEnabled") else { return }
        guard BiometricAuth.shared.availableType != .none else { return }
        let success = await BiometricAuth.shared.authenticate()
        if success {
            appState.isUnlocked = true
        }
    }
}

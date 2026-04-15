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
        .alert("Security Warning", isPresented: $showJailbreakWarning) {
            Button("I Understand the Risk", role: .destructive) {}
        } message: {
            Text("This device may be compromised:\n\n• \(jailbreakReasons.joined(separator: "\n• "))\n\nYour key shards may be at risk. Use a secure device for production wallets.")
        }
        .task {
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
                    Label("Wallet", systemImage: "creditcard.fill")
                }

            ShardsListView()
                .tabItem {
                    Label("Shards", systemImage: "shield.lefthalf.filled")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
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

    enum OnboardingStep {
        case welcome, createPin, confirmPin
    }

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 72))
                .foregroundStyle(HorcruxTheme.accentColor)
                .accessibilityHidden(true)

            switch step {
            case .welcome:
                VStack(spacing: 12) {
                    Text("Welcome to Horcrux")
                        .font(.largeTitle.bold())
                    Text("Your keys are your horcruxes.\nSplit them. Guard them.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }

                Button("Get Started") { step = .createPin }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Begin setting up your wallet PIN")
                    .accessibilityIdentifier("onboarding_getStartedButton")

            case .createPin:
                VStack(spacing: 12) {
                    Text("Create a PIN")
                        .font(.title2.bold())
                    Text("This PIN protects your key shards")
                        .foregroundStyle(.secondary)
                }

                SecureField("Enter PIN (min 4 digits)", text: $pin)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                    .multilineTextAlignment(.center)
                    .accessibilityLabel("Create PIN")
                    .accessibilityHint("Enter at least 4 digits for your new PIN")
                    .accessibilityIdentifier("onboarding_createPinField")

                Button("Next") {
                    step = .confirmPin
                }
                .buttonStyle(.borderedProminent)
                .disabled(pin.count < 4)
                .accessibilityHint("Proceed to confirm your PIN")
                .accessibilityIdentifier("onboarding_nextButton")

            case .confirmPin:
                VStack(spacing: 12) {
                    Text("Confirm PIN")
                        .font(.title2.bold())
                    Text("Enter the same PIN again")
                        .foregroundStyle(.secondary)
                }

                SecureField("Confirm PIN", text: $confirmPin)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                    .multilineTextAlignment(.center)
                    .accessibilityLabel("Confirm PIN")
                    .accessibilityHint("Re-enter your PIN to confirm")
                    .accessibilityIdentifier("onboarding_confirmPinField")

                if !confirmPin.isEmpty && confirmPin != pin {
                    Text("PINs don't match")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button("Create Wallet") {
                    guard pin == confirmPin else { return }
                    try? appState.setPin(pin)
                    appState.isUnlocked = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(confirmPin.count < 4 || pin != confirmPin)
                .accessibilityHint("Save your PIN and create your wallet")
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

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 72))
                .foregroundStyle(HorcruxTheme.accentColor)
                .accessibilityHidden(true)

            Text("Horcrux")
                .font(.largeTitle.bold())

            Text("Enter PIN to unlock your shards")
                .foregroundStyle(.secondary)

            SecureField("PIN", text: $pin)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
                .multilineTextAlignment(.center)
                .onSubmit { unlock() }
                .accessibilityLabel("PIN")
                .accessibilityHint("Enter your numeric PIN to unlock the app")
                .accessibilityIdentifier("lockScreen_pinField")

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel(errorMessage)
            }

            Button("Unlock") { unlock() }
                .buttonStyle(.borderedProminent)
                .disabled(pin.count < 4)
                .accessibilityLabel("Unlock")
                .accessibilityHint("Unlock the app with the entered PIN")
                .accessibilityIdentifier("lockScreen_unlockButton")

            if UserDefaults.standard.bool(forKey: "biometricEnabled"),
               BiometricAuth.shared.availableType != .none {
                Button("Use Face ID") { unlockBiometric() }
                    .foregroundStyle(HorcruxTheme.accentColor)
                    .accessibilityLabel("Unlock with Face ID")
                    .accessibilityHint("Use biometric authentication to unlock the app")
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
            errorMessage = "Too many attempts. Try again in \(secs)s"
            pin = ""
            return
        }
        if appState.verifyPin(pin) {
            errorMessage = nil
            appState.isUnlocked = true
        } else {
            let remaining = AppState.maxFailedAttempts - appState.failedAttempts
            if remaining > 0 {
                errorMessage = "Incorrect PIN (\(remaining) attempts left)"
            } else {
                errorMessage = "All data wiped due to too many failed attempts"
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

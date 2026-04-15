import SwiftUI

/// Root navigation — tab bar with wallet, shards, and settings.
struct ContentView: View {
    @EnvironmentObject private var appState: AppState

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

                Button("Next") {
                    step = .confirmPin
                }
                .buttonStyle(.borderedProminent)
                .disabled(pin.count < 4)

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

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button("Unlock") { unlock() }
                .buttonStyle(.borderedProminent)
                .disabled(pin.count < 4)

            Button("Use Face ID") { unlockBiometric() }
                .foregroundStyle(HorcruxTheme.accentColor)

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
        if appState.verifyPin(pin) {
            errorMessage = nil
            appState.isUnlocked = true
        } else {
            errorMessage = "Incorrect PIN"
            pin = ""
        }
    }

    private func unlockBiometric() {
        Task { await tryBiometricUnlock() }
    }

    private func tryBiometricUnlock() async {
        guard BiometricAuth.shared.availableType != .none else { return }
        let success = await BiometricAuth.shared.authenticate()
        if success {
            appState.isUnlocked = true
        }
    }
}

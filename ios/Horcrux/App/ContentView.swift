import SwiftUI

/// Root navigation — tab bar with wallet, shards, and settings.
struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if appState.isUnlocked {
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

/// Simple lock screen — PIN or biometric.
struct LockScreenView: View {
    @EnvironmentObject private var appState: AppState
    @State private var pin: String = ""

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

            Button("Unlock") { unlock() }
                .buttonStyle(.borderedProminent)
                .disabled(pin.count < 4)

            Button("Use Face ID") { unlockBiometric() }
                .foregroundStyle(HorcruxTheme.accentColor)

            Spacer()
        }
        .padding()
    }

    private func unlock() {
        // TODO: verify PIN against keychain
        appState.isUnlocked = true
    }

    private func unlockBiometric() {
        // TODO: LAContext biometric auth
        appState.isUnlocked = true
    }
}

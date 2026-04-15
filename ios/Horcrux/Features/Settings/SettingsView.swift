import SwiftUI

/// App settings — security, relay server, and about.
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("relayURL") private var relayURL = "ws://localhost:3000/ws"
    @AppStorage("biometricEnabled") private var biometricEnabled = true
    @State private var showChangePin = false
    @State private var showWipeConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Security") {
                    Toggle("Face ID / Touch ID", isOn: $biometricEnabled)

                    Button("Change PIN") {
                        showChangePin = true
                    }
                }

                Section("Relay Server") {
                    TextField("WebSocket URL", text: $relayURL)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: relayURL) { _, newValue in
                            appState.peerManager.relay.relayURL = newValue
                        }

                    RelayStatusRow(relay: appState.peerManager.relay)
                }

                Section("Communication") {
                    NavigationLink {
                        TransportSettingsView()
                    } label: {
                        Label("Transport Preferences", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: "0.1.0")
                    LabeledContent("Core Library", value: "horcrux-core (Rust)")
                    LabeledContent("MPC Protocols", value: "CGGMP21 + FROST")
                    LabeledContent("E2E Encryption", value: "Noise Protocol")

                    NavigationLink {
                        LicensesView()
                    } label: {
                        Text("Open Source Licenses")
                    }
                }

                Section("Danger Zone") {
                    Button(role: .destructive) {
                        showWipeConfirmation = true
                    } label: {
                        Label("Wipe All Data", systemImage: "trash.fill")
                    }
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showChangePin) {
                ChangePinView()
            }
            .alert("Wipe All Data?", isPresented: $showWipeConfirmation) {
                Button("Wipe Everything", role: .destructive) {
                    appState.wipeAllData()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete all wallets, key shards, and settings from this device. This cannot be undone.")
            }
        }
    }
}

/// Shows live relay connection status.
struct RelayStatusRow: View {
    @ObservedObject var relay: RelayTransport

    var body: some View {
        HStack {
            Circle()
                .fill(relay.isConnected ? .green : .red)
                .frame(width: 8, height: 8)
            Text(relay.isConnected ? "Connected" : "Disconnected")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct TransportSettingsView: View {
    @AppStorage("ble_enabled") private var bleEnabled = true
    @AppStorage("wifi_direct_enabled") private var wifiDirectEnabled = true
    @AppStorage("wifi_lan_enabled") private var wifiLANEnabled = true

    var body: some View {
        Form {
            Section("Face-to-Face Channels") {
                Toggle(isOn: $bleEnabled) {
                    Label("Bluetooth (BLE)", systemImage: "wave.3.right")
                }

                Toggle(isOn: $wifiDirectEnabled) {
                    Label("Wi-Fi Direct", systemImage: "wifi")
                }

                Toggle(isOn: $wifiLANEnabled) {
                    Label("Wi-Fi LAN (Bonjour)", systemImage: "network")
                }
            }

            Section {
                Text("BLE works without Wi-Fi. Wi-Fi LAN offers higher throughput for large transactions. Wi-Fi Direct creates a peer-to-peer connection without a router.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Transport")
    }
}

struct ChangePinView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var currentPin = ""
    @State private var newPin = ""
    @State private var confirmPin = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                SecureField("Current PIN", text: $currentPin)
                    .keyboardType(.numberPad)
                SecureField("New PIN", text: $newPin)
                    .keyboardType(.numberPad)
                SecureField("Confirm New PIN", text: $confirmPin)
                    .keyboardType(.numberPad)

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                Button("Change PIN") {
                    changePin()
                }
                .disabled(newPin.count < 4 || newPin != confirmPin || currentPin.isEmpty)
            }
            .navigationTitle("Change PIN")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func changePin() {
        guard appState.verifyPin(currentPin) else {
            errorMessage = "Current PIN is incorrect"
            return
        }
        guard newPin == confirmPin else {
            errorMessage = "New PINs don't match"
            return
        }
        do {
            try appState.setPin(newPin)
            dismiss()
        } catch {
            errorMessage = "Failed to save new PIN"
        }
    }
}

struct LicensesView: View {
    var body: some View {
        List {
            Section("Core Dependencies") {
                LicenseRow(name: "cggmp21", license: "MIT", description: "CGGMP21 threshold ECDSA (Kudelski-audited)")
                LicenseRow(name: "frost-ed25519", license: "MIT/Apache-2.0", description: "IETF FROST RFC 9591")
                LicenseRow(name: "snow", license: "Apache-2.0", description: "Noise Protocol Framework")
                LicenseRow(name: "k256", license: "MIT/Apache-2.0", description: "secp256k1 elliptic curve")
                LicenseRow(name: "uniffi", license: "MPL-2.0", description: "Mozilla UniFFI bindings")
            }
        }
        .navigationTitle("Licenses")
    }
}

struct LicenseRow: View {
    let name: String
    let license: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name).font(.headline)
                Spacer()
                Text(license).font(.caption).foregroundStyle(.secondary)
            }
            Text(description).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

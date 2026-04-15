import SwiftUI

/// App settings — security, relay server, and about.
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("relayURL") private var relayURL = "wss://localhost:3000/ws"
    @AppStorage("biometricEnabled") private var biometricEnabled = true
    @State private var showChangePin = false
    @State private var showWipeConfirmation = false
    @State private var relayWarning: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Security") {
                    Toggle("Face ID / Touch ID", isOn: $biometricEnabled)
                        .accessibilityHint("Enable or disable biometric authentication for unlocking")
                        .accessibilityIdentifier("settings_biometricToggle")

                    Button("Change PIN") {
                        showChangePin = true
                    }
                    .accessibilityHint("Open the PIN change screen")
                    .accessibilityIdentifier("settings_changePinButton")

                    Picker("Auto-Lock", selection: $appState.autoLockTimeout) {
                        Text("Immediately").tag(TimeInterval(0))
                        Text("1 minute").tag(TimeInterval(60))
                        Text("5 minutes").tag(TimeInterval(300))
                        Text("15 minutes").tag(TimeInterval(900))
                        Text("1 hour").tag(TimeInterval(3600))
                        Text("Never").tag(TimeInterval(-1))
                    }
                    .accessibilityIdentifier("settings_autoLockPicker")
                }

                Section("Blockchain Nodes") {
                    NavigationLink {
                        BlockchainNodeSettingsView()
                    } label: {
                        Label("RPC Endpoints", systemImage: "server.rack")
                    }
                    .accessibilityHint("Configure blockchain RPC node endpoints")
                    .accessibilityIdentifier("settings_rpcEndpointsLink")

                    HStack {
                        Text("Network")
                        Spacer()
                        Text(networkSummary)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Relay Server") {
                    TextField("WebSocket URL", text: $relayURL)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: relayURL) { _, newValue in
                            relayWarning = Self.validateRelayURL(newValue)
                            appState.peerManager.relay.relayURL = newValue
                        }
                        .accessibilityLabel("Relay server URL")
                        .accessibilityHint("Enter the WebSocket URL for the relay server")
                        .accessibilityIdentifier("settings_relayURLField")

                    if let relayWarning {
                        Label(relayWarning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    RelayStatusRow(relay: appState.peerManager.relay)
                }

                Section("Communication") {
                    NavigationLink {
                        TransportSettingsView()
                    } label: {
                        Label("Transport Preferences", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .accessibilityHint("Configure Bluetooth, Wi-Fi Direct, and LAN transport options")
                    .accessibilityIdentifier("settings_transportLink")
                }

                Section("About") {
                    LabeledContent("Version", value: "0.1.0")
                    LabeledContent("Core Library", value: "horcrux-core (Rust)")
                    LabeledContent("MPC Protocols", value: "CGGMP21 + FROST")
                    LabeledContent("E2E Encryption", value: "Noise Protocol")

                    HStack {
                        Text("Secure Enclave")
                        Spacer()
                        if SecureEnclaveManager.shared.isAvailable {
                            Label("Hardware Protected", systemImage: "checkmark.shield.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Label("Software Only", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    NavigationLink {
                        LicensesView()
                    } label: {
                        Text("Open Source Licenses")
                    }
                    .accessibilityHint("View open source library licenses")
                    .accessibilityIdentifier("settings_licensesLink")
                }

                Section("Danger Zone") {
                    Button(role: .destructive) {
                        showWipeConfirmation = true
                    } label: {
                        Label("Wipe All Data", systemImage: "trash.fill")
                    }
                    .accessibilityHint("Permanently delete all wallets, key shards, and settings")
                    .accessibilityIdentifier("settings_wipeButton")
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
            .onAppear {
                relayWarning = Self.validateRelayURL(relayURL)
            }
        }
    }

    private var networkSummary: String {
        let config = appState.networkConfig
        var parts: [String] = []
        parts.append(config.evmChainId == 1 ? "ETH Mainnet" : "ETH Chain \(config.evmChainId)")
        parts.append(config.btcTestnet ? "BTC Testnet" : "BTC Mainnet")
        parts.append(config.solDevnet ? "SOL Devnet" : "SOL Mainnet")
        return parts.joined(separator: " · ")
    }

    /// Validate relay URL — must be wss:// for production use.
    static func validateRelayURL(_ urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased() else {
            return "Invalid URL format"
        }
        if scheme == "ws" {
            let host = url.host ?? ""
            if host != "localhost" && host != "127.0.0.1" && host != "::1" {
                return "⚠️ Unencrypted ws:// — use wss:// for production"
            }
        } else if scheme != "wss" {
            return "URL must use wss:// (or ws:// for local dev)"
        }
        return nil
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
                .accessibilityHidden(true)
            Text(relay.isConnected ? "Connected" : "Disconnected")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Relay status: \(relay.isConnected ? "Connected" : "Disconnected")")
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
                .accessibilityHint("Enable or disable Bluetooth for peer-to-peer communication")

                Toggle(isOn: $wifiDirectEnabled) {
                    Label("Wi-Fi Direct", systemImage: "wifi")
                }
                .accessibilityHint("Enable or disable Wi-Fi Direct for peer-to-peer communication")

                Toggle(isOn: $wifiLANEnabled) {
                    Label("Wi-Fi LAN (Bonjour)", systemImage: "network")
                }
                .accessibilityHint("Enable or disable local Wi-Fi network discovery")
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
                    .accessibilityLabel("Current PIN")
                    .accessibilityIdentifier("changePin_currentField")
                SecureField("New PIN", text: $newPin)
                    .keyboardType(.numberPad)
                    .accessibilityLabel("New PIN")
                    .accessibilityIdentifier("changePin_newField")
                SecureField("Confirm New PIN", text: $confirmPin)
                    .keyboardType(.numberPad)
                    .accessibilityLabel("Confirm new PIN")
                    .accessibilityIdentifier("changePin_confirmField")

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                Button("Change PIN") {
                    changePin()
                }
                .disabled(newPin.count < 4 || newPin != confirmPin || currentPin.isEmpty)
                .accessibilityHint("Save your new PIN")
                .accessibilityIdentifier("changePin_submitButton")
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

struct BlockchainNodeSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var config = NetworkConfig.shared
    @State private var showResetConfirm = false

    var body: some View {
        Form {
            Section {
                Text("Configure RPC endpoints for each blockchain. These are used to query balances, estimate fees, and broadcast signed transactions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Ethereum / EVM") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("RPC URL")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("https://eth.llamarpc.com", text: $config.ethereumRPC)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Picker("Network", selection: $config.evmChainId) {
                    Text("Mainnet (Chain ID 1)").tag(UInt64(1))
                    Text("Sepolia Testnet (11155111)").tag(UInt64(11155111))
                    Text("Polygon (137)").tag(UInt64(137))
                    Text("Arbitrum One (42161)").tag(UInt64(42161))
                    Text("Base (8453)").tag(UInt64(8453))
                }

                NodeStatusRow(chain: .ethereum)
            }

            Section("Bitcoin") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("REST API URL")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("https://blockstream.info/api", text: $config.bitcoinAPI)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Toggle("Testnet", isOn: $config.btcTestnet)
                    .accessibilityHint("Switch between Bitcoin mainnet and testnet")

                NodeStatusRow(chain: .bitcoin)
            }

            Section("Solana") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("RPC URL")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("https://api.mainnet-beta.solana.com", text: $config.solanaRPC)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Toggle("Devnet", isOn: $config.solDevnet)
                    .accessibilityHint("Switch between Solana mainnet and devnet")

                NodeStatusRow(chain: .solana)
            }

            Section {
                Button("Reset to Defaults") {
                    showResetConfirm = true
                }
                .foregroundStyle(.red)
                .accessibilityHint("Reset all RPC endpoints to default public nodes")
                .accessibilityIdentifier("nodeSettings_resetButton")
            }
        }
        .navigationTitle("Blockchain Nodes")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Reset to Defaults?", isPresented: $showResetConfirm) {
            Button("Reset", role: .destructive) { config.resetToDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will reset all RPC endpoints to the default public nodes.")
        }
    }
}

/// Shows a connectivity indicator for a blockchain node.
struct NodeStatusRow: View {
    let chain: Chain
    @State private var status: NodeStatus = .unknown
    @State private var checking = false

    enum NodeStatus {
        case unknown, connected, error(String)

        var color: Color {
            switch self {
            case .unknown: return .gray
            case .connected: return .green
            case .error: return .red
            }
        }

        var label: String {
            switch self {
            case .unknown: return "Not checked"
            case .connected: return "Connected"
            case .error(let msg): return msg
            }
        }
    }

    var body: some View {
        HStack {
            Button {
                checkConnection()
            } label: {
                HStack(spacing: 6) {
                    if checking {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Circle()
                            .fill(status.color)
                            .frame(width: 8, height: 8)
                    }
                    Text(checking ? "Checking…" : status.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Test")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func checkConnection() {
        guard !checking else { return }
        checking = true
        let config = NetworkConfig.shared
        let service = BlockchainService()

        Task {
            do {
                switch chain {
                case .ethereum:
                    // Simple eth_blockNumber call
                    _ = try await service.ethBalance(address: "0x0000000000000000000000000000000000000000", rpcURL: config.ethereumRPC)
                case .bitcoin:
                    let urlString = "\(config.bitcoinAPI)/blocks/tip/hash"
                    guard let url = URL(string: urlString) else { throw BlockchainError.invalidURL(urlString) }
                    let (_, response) = try await PinnedURLSession.shared.session.data(from: url)
                    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                        throw BlockchainError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
                    }
                case .solana:
                    _ = try await service.solBalance(address: "11111111111111111111111111111111", rpcURL: config.solanaRPC)
                }
                await MainActor.run {
                    status = .connected
                    checking = false
                }
            } catch {
                await MainActor.run {
                    status = .error(error.localizedDescription.prefix(40) + "…")
                    checking = false
                }
            }
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

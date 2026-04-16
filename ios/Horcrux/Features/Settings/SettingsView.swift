import SwiftUI

/// App settings — security, relay server, and about.
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("biometricEnabled") private var biometricEnabled = true
    @State private var relayURL = "wss://localhost:3000/ws"
    @State private var showChangePin = false
    @State private var showWipeConfirmation = false
    @State private var relayWarning: String?

    private static let relayURLKey = "horcrux_relay_url"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Security
                    VStack(alignment: .leading, spacing: 10) {
                        VaultSectionHeader(L10n.Settings.security, icon: "lock.shield")
                            .padding(.horizontal, 4)

                        VStack(spacing: 1) {
                            HStack {
                                VaultSettingsRow(icon: "faceid", iconColor: HorcruxTheme.accentPurple, title: L10n.Settings.faceIDTouchID)
                                Spacer()
                                Toggle("", isOn: $biometricEnabled)
                                    .labelsHidden()
                                    .tint(HorcruxTheme.accentPurple)
                            }
                            .glassCard()
                            .accessibilityHint(L10n.Settings.biometricHint)
                            .accessibilityIdentifier("settings_biometricToggle")

                            Button { showChangePin = true } label: {
                                HStack {
                                    VaultSettingsRow(icon: "key.fill", iconColor: HorcruxTheme.accentBlue, title: L10n.Settings.changePin)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(HorcruxTheme.subtleText)
                                }
                            }
                            .glassCard()
                            .accessibilityHint(L10n.Settings.changePinHint)
                            .accessibilityIdentifier("settings_changePinButton")

                            HStack {
                                VaultSettingsRow(icon: "timer", iconColor: HorcruxTheme.warningAmber, title: L10n.Settings.autoLock)
                                Spacer()
                                Picker("", selection: $appState.autoLockTimeout) {
                                    Text(L10n.Settings.immediately).tag(TimeInterval(0))
                                    Text(L10n.Settings.oneMinute).tag(TimeInterval(60))
                                    Text(L10n.Settings.fiveMinutes).tag(TimeInterval(300))
                                    Text(L10n.Settings.fifteenMinutes).tag(TimeInterval(900))
                                    Text(L10n.Settings.oneHour).tag(TimeInterval(3600))
                                    Text(L10n.Settings.never).tag(TimeInterval(-1))
                                }
                                .labelsHidden()
                                .tint(HorcruxTheme.accentPurple)
                            }
                            .glassCard()
                            .accessibilityIdentifier("settings_autoLockPicker")
                        }
                    }

                    // Blockchain Nodes
                    VStack(alignment: .leading, spacing: 10) {
                        VaultSectionHeader(L10n.Settings.blockchainNodes, icon: "server.rack")
                            .padding(.horizontal, 4)

                        VStack(spacing: 1) {
                            NavigationLink {
                                BlockchainNodeSettingsView()
                            } label: {
                                HStack {
                                    VaultSettingsRow(icon: "server.rack", iconColor: HorcruxTheme.accentCyan, title: L10n.Settings.rpcEndpoints, subtitle: networkSummary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(HorcruxTheme.subtleText)
                                }
                            }
                            .glassCard()
                            .accessibilityHint(L10n.Settings.rpcEndpointsHint)
                            .accessibilityIdentifier("settings_rpcEndpointsLink")
                        }
                    }

                    // Relay
                    VStack(alignment: .leading, spacing: 10) {
                        VaultSectionHeader(L10n.Settings.relayServer, icon: "antenna.radiowaves.left.and.right")
                            .padding(.horizontal, 4)

                        VStack(spacing: 8) {
                            TextField(L10n.Settings.webSocketURL, text: $relayURL)
                                .font(.system(.caption, design: .monospaced))
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.white.opacity(0.06))
                                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1), lineWidth: 1))
                                )
                                .foregroundStyle(.white)
                                .tint(HorcruxTheme.accentPurple)
                                .onChange(of: relayURL) { _, newValue in
                                    relayWarning = Self.validateRelayURL(newValue)
                                    appState.peerManager.relay.relayURL = newValue
                                    try? KeychainManager.shared.store(key: Self.relayURLKey, data: Data(newValue.utf8))
                                }
                                .accessibilityLabel(L10n.Settings.relayServerURL)
                                .accessibilityHint(L10n.Settings.relayURLHint)
                                .accessibilityIdentifier("settings_relayURLField")

                            if let relayWarning {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.caption2)
                                    Text(relayWarning)
                                        .font(.caption)
                                }
                                .foregroundStyle(HorcruxTheme.warningAmber)
                            }

                            RelayStatusRow(relay: appState.peerManager.relay)
                        }
                        .glassCard()
                    }

                    // Communication
                    VStack(alignment: .leading, spacing: 10) {
                        VaultSectionHeader(L10n.Settings.communication, icon: "wave.3.right")
                            .padding(.horizontal, 4)

                        NavigationLink {
                            TransportSettingsView()
                        } label: {
                            HStack {
                                VaultSettingsRow(icon: "antenna.radiowaves.left.and.right", iconColor: HorcruxTheme.successGreen, title: L10n.Settings.transportPreferences)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(HorcruxTheme.subtleText)
                            }
                        }
                        .glassCard()
                        .accessibilityHint(L10n.Settings.transportHint)
                        .accessibilityIdentifier("settings_transportLink")
                    }

                    // About
                    VStack(alignment: .leading, spacing: 10) {
                        VaultSectionHeader(L10n.Settings.about, icon: "info.circle")
                            .padding(.horizontal, 4)

                        VStack(spacing: 0) {
                            aboutRow(L10n.Settings.version, value: "0.2.0")
                            Divider().background(Color.white.opacity(0.06))
                            aboutRow(L10n.Settings.coreLibrary, value: "horcrux-core (Rust)")
                            Divider().background(Color.white.opacity(0.06))
                            aboutRow(L10n.Settings.mpcProtocols, value: "CGGMP21 + FROST")
                            Divider().background(Color.white.opacity(0.06))
                            aboutRow(L10n.Settings.e2eEncryption, value: "Noise Protocol")
                            Divider().background(Color.white.opacity(0.06))
                            HStack {
                                Text(L10n.Settings.secureEnclave)
                                    .font(.subheadline)
                                    .foregroundStyle(HorcruxTheme.subtleText)
                                Spacer()
                                if SecureEnclaveManager.shared.isAvailable {
                                    HStack(spacing: 4) {
                                        Image(systemName: "checkmark.shield.fill")
                                            .font(.caption2)
                                        Text(L10n.Settings.hardwareProtected)
                                            .font(.caption)
                                    }
                                    .foregroundStyle(HorcruxTheme.successGreen)
                                } else {
                                    HStack(spacing: 4) {
                                        Image(systemName: "exclamationmark.triangle")
                                            .font(.caption2)
                                        Text(L10n.Settings.softwareOnly)
                                            .font(.caption)
                                    }
                                    .foregroundStyle(HorcruxTheme.warningAmber)
                                }
                            }
                            .padding(.vertical, 10)
                            Divider().background(Color.white.opacity(0.06))
                            NavigationLink {
                                LicensesView()
                            } label: {
                                HStack {
                                    Text(L10n.Settings.openSourceLicenses)
                                        .font(.subheadline)
                                        .foregroundStyle(.white)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(HorcruxTheme.subtleText)
                                }
                                .padding(.vertical, 10)
                            }
                            .accessibilityHint(L10n.Settings.licensesHint)
                            .accessibilityIdentifier("settings_licensesLink")
                        }
                        .glassCard()
                    }

                    // Danger Zone
                    VStack(alignment: .leading, spacing: 10) {
                        VaultSectionHeader(L10n.Settings.dangerZone, icon: "exclamationmark.triangle")
                            .padding(.horizontal, 4)

                        Button(role: .destructive) {
                            showWipeConfirmation = true
                        } label: {
                            HStack {
                                VaultSettingsRow(icon: "trash.fill", iconColor: HorcruxTheme.dangerRed, title: L10n.Settings.wipeAllData, subtitle: "Permanently delete all keys and data")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(HorcruxTheme.subtleText)
                            }
                        }
                        .glassCard()
                        .accessibilityHint(L10n.Settings.wipeHint)
                        .accessibilityIdentifier("settings_wipeButton")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .darkBackground()
            .navigationTitle(L10n.Settings.title)
            .navigationBarTitleDisplayMode(.large)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .sheet(isPresented: $showChangePin) {
                ChangePinView()
            }
            .alert(L10n.Settings.wipeConfirmTitle, isPresented: $showWipeConfirmation) {
                Button(L10n.Settings.wipeEverything, role: .destructive) {
                    appState.wipeAllData()
                }
                Button(L10n.Common.cancel, role: .cancel) {}
            } message: {
                Text(L10n.Settings.wipeMessage)
            }
            .onAppear {
                if let data = try? KeychainManager.shared.retrieve(key: Self.relayURLKey),
                   let url = String(data: data, encoding: .utf8), !url.isEmpty {
                    relayURL = url
                }
                relayWarning = Self.validateRelayURL(relayURL)
            }
            .preferredColorScheme(.dark)
        }
    }

    private func aboutRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(HorcruxTheme.subtleText)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
        }
        .padding(.vertical, 10)
    }

    private var networkSummary: String {
        let config = appState.networkConfig
        var parts: [String] = []
        parts.append(config.evmChainId == 1 ? "ETH Mainnet" : "ETH Chain \(config.evmChainId)")
        parts.append(config.btcTestnet ? "BTC Testnet" : "BTC Mainnet")
        parts.append(config.solDevnet ? "SOL Devnet" : "SOL Mainnet")
        return parts.joined(separator: " · ")
    }

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
        HStack(spacing: 8) {
            Circle()
                .fill(relay.isConnected ? HorcruxTheme.successGreen : HorcruxTheme.dangerRed)
                .frame(width: 8, height: 8)
                .shadow(color: relay.isConnected ? HorcruxTheme.successGreen.opacity(0.5) : HorcruxTheme.dangerRed.opacity(0.5), radius: 4)
                .accessibilityHidden(true)
            Text(relay.isConnected ? L10n.Settings.connected : L10n.Settings.disconnected)
                .font(.caption)
                .foregroundStyle(HorcruxTheme.subtleText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(relay.isConnected ? L10n.Settings.relayStatusConnected : L10n.Settings.relayStatusDisconnected)
    }
}

struct TransportSettingsView: View {
    @AppStorage("ble_enabled") private var bleEnabled = true
    @AppStorage("wifi_direct_enabled") private var wifiDirectEnabled = true
    @AppStorage("wifi_lan_enabled") private var wifiLANEnabled = true

    var body: some View {
        Form {
            Section(L10n.Transport.faceToFaceChannels) {
                Toggle(isOn: $bleEnabled) {
                    Label(L10n.Transport.ble, systemImage: "wave.3.right")
                }
                .accessibilityHint(L10n.Transport.bleHint)

                Toggle(isOn: $wifiDirectEnabled) {
                    Label(L10n.Transport.wifiDirect, systemImage: "wifi")
                }
                .accessibilityHint(L10n.Transport.wifiDirectHint)

                Toggle(isOn: $wifiLANEnabled) {
                    Label(L10n.Transport.wifiLAN, systemImage: "network")
                }
                .accessibilityHint(L10n.Transport.wifiLANHint)
            }

            Section {
                Text(L10n.Transport.info)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L10n.Transport.title)
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
                SecureField(L10n.ChangePin.currentPin, text: $currentPin)
                    .keyboardType(.numberPad)
                    .accessibilityLabel(L10n.ChangePin.currentPin)
                    .accessibilityIdentifier("changePin_currentField")
                SecureField(L10n.ChangePin.newPin, text: $newPin)
                    .keyboardType(.numberPad)
                    .accessibilityLabel(L10n.ChangePin.newPin)
                    .accessibilityIdentifier("changePin_newField")
                SecureField(L10n.ChangePin.confirmNewPin, text: $confirmPin)
                    .keyboardType(.numberPad)
                    .accessibilityLabel(L10n.ChangePin.confirmNewPin)
                    .accessibilityIdentifier("changePin_confirmField")

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                Button(L10n.ChangePin.submit) {
                    changePin()
                }
                .disabled(newPin.count < 4 || newPin != confirmPin || currentPin.isEmpty)
                .accessibilityHint(L10n.ChangePin.submitHint)
                .accessibilityIdentifier("changePin_submitButton")
            }
            .navigationTitle(L10n.ChangePin.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.cancel) { dismiss() }
                }
            }
        }
    }

    private func changePin() {
        guard appState.verifyPin(currentPin) else {
            errorMessage = L10n.ChangePin.incorrectCurrent
            return
        }
        guard newPin == confirmPin else {
            errorMessage = L10n.ChangePin.dontMatch
            return
        }
        do {
            try appState.setPin(newPin)
            dismiss()
        } catch {
            errorMessage = L10n.ChangePin.saveFailed
        }
    }
}

struct BlockchainNodeSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var config = NetworkConfig.shared
    @State private var showResetConfirm = false

    var body: some View {
        Form {
            Section(L10n.NodeSettings.quickPresets) {
                HStack(spacing: 12) {
                    ForEach(NetworkPreset.all) { preset in
                        Button {
                            config.applyPreset(preset)
                        } label: {
                            Text(preset.name)
                                .font(.subheadline.bold())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.bordered)
                        .tint(isCurrentPreset(preset) ? .green : .accentColor)
                        .accessibilityLabel(L10n.NodeSettings.switchTo(preset.name))
                    }
                }
            }

            Section {
                Text(L10n.NodeSettings.configureInfo)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.NodeSettings.ethereumEVM) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.NodeSettings.rpcURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("https://eth.llamarpc.com", text: $config.ethereumRPC)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Picker(L10n.NodeSettings.networkPicker, selection: $config.evmChainId) {
                    Text(L10n.NodeSettings.mainnet).tag(UInt64(1))
                    Text(L10n.NodeSettings.sepoliaTestnet).tag(UInt64(11155111))
                    Text(L10n.NodeSettings.polygon).tag(UInt64(137))
                    Text(L10n.NodeSettings.arbitrumOne).tag(UInt64(42161))
                    Text(L10n.NodeSettings.base).tag(UInt64(8453))
                }

                NodeStatusRow(chain: .ethereum)
            }

            Section(L10n.NodeSettings.bitcoin) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.NodeSettings.restAPIURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("https://blockstream.info/api", text: $config.bitcoinAPI)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Toggle(L10n.NodeSettings.testnet, isOn: $config.btcTestnet)
                    .accessibilityHint(L10n.NodeSettings.testnetHint)

                NodeStatusRow(chain: .bitcoin)
            }

            Section(L10n.NodeSettings.solana) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.NodeSettings.rpcURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("https://api.mainnet-beta.solana.com", text: $config.solanaRPC)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Toggle(L10n.NodeSettings.devnet, isOn: $config.solDevnet)
                    .accessibilityHint(L10n.NodeSettings.devnetHint)

                NodeStatusRow(chain: .solana)
            }

            Section {
                Button(L10n.NodeSettings.resetToDefaults) {
                    showResetConfirm = true
                }
                .foregroundStyle(.red)
                .accessibilityHint(L10n.NodeSettings.resetHint)
                .accessibilityIdentifier("nodeSettings_resetButton")
            }
        }
        .navigationTitle(L10n.NodeSettings.title)
        .navigationBarTitleDisplayMode(.inline)
        .alert(L10n.NodeSettings.resetConfirmTitle, isPresented: $showResetConfirm) {
            Button(L10n.NodeSettings.reset, role: .destructive) { config.resetToDefaults() }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.NodeSettings.resetMessage)
        }
    }

    private func isCurrentPreset(_ preset: NetworkPreset) -> Bool {
        config.ethereumRPC == preset.ethereumRPC &&
        config.bitcoinAPI == preset.bitcoinAPI &&
        config.solanaRPC == preset.solanaRPC
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
            case .unknown: return L10n.NodeStatus.notChecked
            case .connected: return L10n.NodeStatus.connected
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
                    Text(checking ? L10n.NodeStatus.checking : status.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(L10n.Common.test)
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
            Section(L10n.Licenses.coreDependencies) {
                LicenseRow(name: "cggmp21", license: "MIT", description: "CGGMP21 threshold ECDSA (Kudelski-audited)")
                LicenseRow(name: "frost-ed25519", license: "MIT/Apache-2.0", description: "IETF FROST RFC 9591")
                LicenseRow(name: "snow", license: "Apache-2.0", description: "Noise Protocol Framework")
                LicenseRow(name: "k256", license: "MIT/Apache-2.0", description: "secp256k1 elliptic curve")
                LicenseRow(name: "uniffi", license: "MPL-2.0", description: "Mozilla UniFFI bindings")
            }
        }
        .navigationTitle(L10n.Licenses.title)
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

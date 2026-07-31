import SwiftUI

/// App settings — security, relay server, and about.
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("biometricEnabled") private var biometricEnabled = true
    @AppStorage("biometricSigningGate") private var biometricSigningGate = false
    @AppStorage(RelayConfig.useCustomKey) private var useCustomRelay = false
    @AppStorage("deviceNickname") private var deviceNickname = ""
    @State private var relayURL = RelayConfig.effectiveURL
    @State private var showChangePin = false
    @State private var showWipeConfirmation = false
    @State private var showWipePinSheet = false
    @State private var showBiometricDisablePinSheet = false
    @State private var biometricDisableVerified = false
    @State private var relayWarning: String?
    @ObservedObject private var health = NodeHealthStore.shared


    private static let relayURLKey = RelayConfig.customURLKey

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
                                Toggle("", isOn: Binding(
                                    get: { biometricEnabled },
                                    set: { newValue in
                                        if newValue {
                                            // Enabling biometric is harmless:
                                            // the SE-sealed key (if any) is
                                            // already there; this is purely a
                                            // UI preference for showing the
                                            // biometric button on the lock
                                            // screen.
                                            biometricEnabled = true
                                        } else {
                                            // Disabling is more sensitive: an
                                            // attacker with a briefly-unlocked
                                            // phone could hide the biometric
                                            // button to force a PIN entry
                                            // that they can shoulder-surf.
                                            // Gate it behind PIN verification.
                                            biometricEnabled = false
                                            showBiometricDisablePinSheet = true
                                        }
                                    }
                                ))
                                    .labelsHidden()
                                    .tint(HorcruxTheme.accentPurple)
                            }
                            .glassCard()
                            .accessibilityHint(L10n.Settings.biometricHint)
                            .accessibilityIdentifier("settings_biometricToggle")

                            HStack {
                                VaultSettingsRow(icon: "hand.raised.fingers.spread", iconColor: HorcruxTheme.accentBlue, title: L10n.Settings.biometricSign)
                                Spacer()
                                Toggle("", isOn: $biometricSigningGate)
                                    .labelsHidden()
                                    .tint(HorcruxTheme.accentBlue)
                            }
                            .glassCard()
                            .accessibilityHint(L10n.Settings.biometricSignHint)
                            .accessibilityIdentifier("settings_biometricSigningGateToggle")

                            Button { showChangePin = true } label: {
                                HStack {
                                    VaultSettingsRow(icon: "key.fill", iconColor: HorcruxTheme.accentBlue, title: L10n.Settings.changePin)
                                    Spacer()
                                    VaultDisclosureIndicator()
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
                                    if let dot = nodeHealthDotColor {
                                        Circle()
                                            .fill(dot)
                                            .frame(width: 8, height: 8)
                                    }
                                    Spacer()
                                    VaultDisclosureIndicator()
                                }
                            }
                            .glassCard()
                            .accessibilityHint(L10n.Settings.rpcEndpointsHint)
                            .accessibilityIdentifier("settings_rpcEndpointsLink")
                        }
                    }

                    // Appearance (Standard vs Vault display mode)
                    appearanceSection

                    // Relay
                    VStack(alignment: .leading, spacing: 10) {
                        VaultSectionHeader(L10n.Settings.relayServer, icon: "antenna.radiowaves.left.and.right")
                            .padding(.horizontal, 4)

                        VStack(spacing: 8) {
                            // Official / Custom picker
                            Picker("", selection: $useCustomRelay) {
                                Text(L10n.Settings.officialRelay).tag(false)
                                Text(L10n.Settings.customRelay).tag(true)
                            }
                            .pickerStyle(.segmented)
                            .tint(HorcruxTheme.accentPurple)
                            .onChange(of: useCustomRelay) { _, isCustom in
                                if !isCustom {
                                    RelayConfig.resetToDefault()
                                    relayURL = RelayConfig.effectiveURL
                                    appState.peerManager.relay.relayURL = relayURL
                                    relayWarning = nil
                                }
                            }

                            if useCustomRelay {
                                VaultTextField(text: $relayURL, placeholder: L10n.Settings.webSocketURL)
                                    .onChange(of: relayURL) { _, newValue in
                                        relayWarning = Self.validateRelayURL(newValue)
                                        appState.peerManager.relay.relayURL = newValue
                                        try? RelayConfig.setCustom(newValue)
                                    }
                                    .accessibilityLabel(L10n.Settings.relayServerURL)
                                    .accessibilityHint(L10n.Settings.relayURLHint)
                                    .accessibilityIdentifier("settings_relayURLField")
                            } else {
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark.seal.fill")
                                        .foregroundStyle(HorcruxTheme.accentCyan)
                                    Text(relayURL)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(HorcruxTheme.subtleText)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(HorcruxTheme.accentCyan.opacity(0.08))
                                )
                            }

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

                    // Address Book
                    VStack(alignment: .leading, spacing: 10) {
                        VaultSectionHeader(L10n.Settings.sectionContacts, icon: "person.2")
                            .padding(.horizontal, 4)

                        NavigationLink {
                            AddressBookView()
                        } label: {
                            HStack {
                                VaultSettingsRow(icon: "person.2.circle", iconColor: HorcruxTheme.accentBlue, title: L10n.Settings.addressBook)
                                Spacer()
                                VaultDisclosureIndicator()
                            }
                        }
                        .glassCard()
                        .accessibilityIdentifier("settings_addressBookLink")
                    }

                    // Custom tokens
                    VStack(alignment: .leading, spacing: 10) {
                        VaultSectionHeader(L10n.Settings.sectionTokens, icon: "circle.grid.2x2")
                            .padding(.horizontal, 4)

                        NavigationLink {
                            CustomTokensView()
                        } label: {
                            HStack {
                                VaultSettingsRow(icon: "plus.circle", iconColor: HorcruxTheme.accentPurple, title: L10n.Settings.customTokens)
                                Spacer()
                                VaultDisclosureIndicator()
                            }
                        }
                        .glassCard()
                        .accessibilityIdentifier("settings_customTokensLink")
                    }

                    // Shard health self-check
                    VStack(alignment: .leading, spacing: 10) {
                        VaultSectionHeader(L10n.Settings.sectionDiagnostics, icon: "stethoscope")
                            .padding(.horizontal, 4)

                        NavigationLink {
                            ShardHealthView()
                        } label: {
                            HStack {
                                VaultSettingsRow(icon: "checkmark.shield", iconColor: HorcruxTheme.successGreen, title: L10n.Settings.shardHealth)
                                Spacer()
                                VaultDisclosureIndicator()
                            }
                        }
                        .glassCard()
                        .accessibilityIdentifier("settings_shardHealthLink")

                        NavigationLink {
                            AuditExportView()
                        } label: {
                            HStack {
                                VaultSettingsRow(
                                    icon: "square.and.arrow.up.on.square",
                                    iconColor: HorcruxTheme.accentBlue,
                                    title: NSLocalizedString("settings.auditExport",
                                                              value: "Export Audit Log",
                                                              comment: ""),
                                    subtitle: NSLocalizedString("settings.auditExport.subtitle",
                                                                 value: "Transactions + approvals as CSV / JSON",
                                                                 comment: "")
                                )
                                Spacer()
                                VaultDisclosureIndicator()
                            }
                        }
                        .glassCard()
                        .accessibilityIdentifier("settings_auditExportLink")
                    }

                    // Language
                    VStack(alignment: .leading, spacing: 10) {
                        VaultSectionHeader(L10n.SettingsResidual.languageSection, icon: "globe")
                            .padding(.horizontal, 4)

                        NavigationLink {
                            LanguageSettingsView()
                        } label: {
                            HStack {
                                VaultSettingsRow(
                                    icon: "character.bubble",
                                    iconColor: HorcruxTheme.accentPurple,
                                    title: L10n.SettingsResidual.languageRowTitle,
                                    subtitle: languageSummary
                                )
                                Spacer()
                                VaultDisclosureIndicator()
                            }
                        }
                        .glassCard()
                        .accessibilityIdentifier("settings_languageLink")
                    }

                    // Replace device / Share refresh
                    VStack(alignment: .leading, spacing: 10) {
                        VaultSectionHeader(L10n.Settings.sectionDeviceMgmt, icon: "iphone.gen3")
                            .padding(.horizontal, 4)

                        NavigationLink {
                            ReplaceDeviceInfoView()
                        } label: {
                            HStack {
                                VaultSettingsRow(
                                    icon: "arrow.triangle.2.circlepath.circle",
                                    iconColor: HorcruxTheme.accentCyan,
                                    title: L10n.Settings.replaceDevice,
                                    subtitle: L10n.Settings.replaceDeviceSubtitle
                                )
                                Spacer()
                                VaultDisclosureIndicator()
                            }
                        }
                        .glassCard()
                        .accessibilityIdentifier("settings_replaceDeviceLink")
                    }

                    // Communication
                    VStack(alignment: .leading, spacing: 10) {
                        VaultSectionHeader(L10n.Settings.communication, icon: "wave.3.right")
                            .padding(.horizontal, 4)

                        VStack(spacing: 8) {
                            // Device nickname — shown to peers during DKG / signing
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Image(systemName: "iphone")
                                        .foregroundStyle(HorcruxTheme.accentPurple)
                                    Text(L10n.SettingsResidual.deviceNickname)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.white)
                                    Spacer()
                                }
                                VaultTextField(text: $deviceNickname, placeholder: DeviceIdentity.displayName, monospaced: false)
                                    .accessibilityIdentifier("settings_deviceNicknameField")
                                Text(L10n.SettingsResidual.deviceNicknameHint)
                                    .font(.caption2)
                                    .foregroundStyle(HorcruxTheme.subtleText)
                            }
                        }
                        .glassCard()

                        NavigationLink {
                            TransportSettingsView()
                        } label: {
                            HStack {
                                VaultSettingsRow(icon: "antenna.radiowaves.left.and.right", iconColor: HorcruxTheme.successGreen, title: L10n.Settings.transportPreferences)
                                Spacer()
                                VaultDisclosureIndicator()
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
                            aboutRow(L10n.Settings.version, value: Self.appVersion)
                            Rectangle().fill(HorcruxTheme.hairline).frame(height: 1)
                            aboutRow(L10n.Settings.coreLibrary, value: "horcrux-core (Rust)")
                            Rectangle().fill(HorcruxTheme.hairline).frame(height: 1)
                            aboutRow(L10n.Settings.mpcProtocols, value: "CGGMP21 + FROST")
                            Rectangle().fill(HorcruxTheme.hairline).frame(height: 1)
                            aboutRow(L10n.Settings.e2eEncryption, value: "Noise Protocol")
                            Rectangle().fill(HorcruxTheme.hairline).frame(height: 1)
                            aboutRow(L10n.Settings.priceDataSources, value: "CoinGecko · Coincap")
                            Rectangle().fill(HorcruxTheme.hairline).frame(height: 1)
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
                            Rectangle().fill(HorcruxTheme.hairline).frame(height: 1)
                            NavigationLink {
                                LicensesView()
                            } label: {
                                HStack {
                                    Text(L10n.Settings.openSourceLicenses)
                                        .font(.subheadline)
                                        .foregroundStyle(.white)
                                    Spacer()
                                    VaultDisclosureIndicator()
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
                                VaultSettingsRow(icon: "trash.fill", iconColor: HorcruxTheme.dangerRed, title: L10n.Settings.wipeAllData, subtitle: L10n.Settings.wipeAllDataSubtitle)
                                Spacer()
                                VaultDisclosureIndicator()
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .sheet(isPresented: $showChangePin) {
                ChangePinView()
            }
            .alert(L10n.Settings.wipeConfirmTitle, isPresented: $showWipeConfirmation) {
                Button(L10n.Settings.wipeEverything, role: .destructive) {
                    // Gate the actual wipe behind a PIN sheet. A destructive
                    // alert alone is too weak for the most destructive action
                    // in the app — a single shard delete already requires PIN,
                    // so wiping everything should too.
                    showWipePinSheet = true
                }
                Button(L10n.Common.cancel, role: .cancel) {}
            } message: {
                Text(L10n.Settings.wipeMessage)
            }
            .sheet(isPresented: $showWipePinSheet) {
                PinUnlockSheet(
                    title: L10n.Settings.wipePinTitle,
                    subtitle: L10n.Settings.wipePinSubtitle
                ) { entered in
                    guard appState.verifyPin(entered) else {
                        return L10n.Settings.wipePinWrong
                    }
                    DispatchQueue.main.async { appState.wipeAllData() }
                    return nil
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showBiometricDisablePinSheet) {
                PinUnlockSheet(
                    title: L10n.Settings.biometricDisableTitle,
                    subtitle: L10n.Settings.biometricDisableSubtitle
                ) { entered in
                    guard appState.verifyPin(entered) else {
                        return L10n.Settings.biometricDisablePinWrong
                    }
                    biometricDisableVerified = true
                    return nil
                }
                .presentationDetents([.medium, .large])
                .onDisappear {
                    // If the sheet closed without a successful PIN
                    // verification, revert the toggle so an attacker with
                    // a briefly-unlocked phone can't silently hide the
                    // biometric prompt.
                    if !biometricDisableVerified {
                        biometricEnabled = true
                    }
                    biometricDisableVerified = false
                }
            }
            .onAppear {
                relayURL = RelayConfig.effectiveURL
                relayWarning = useCustomRelay ? Self.validateRelayURL(relayURL) : nil
            }
            .preferredColorScheme(.dark)
        }
    }

    // MARK: - Appearance section

    /// Wallet display mode and its two Vault-Mode-specific sub-toggles.
    /// Rendered inline in the main settings scroll so users don't need
    /// to drill into a sub-screen to flip between Standard and Vault
    /// styling — that's a quick demo gesture for buyers.
    @ViewBuilder
    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VaultSectionHeader(L10n.SettingsAppearance.section, icon: "square.grid.2x2.fill")
                .padding(.horizontal, 4)

            VStack(spacing: 10) {
                // Segmented mode picker
                HStack {
                    VaultSettingsRow(
                        icon: "square.grid.2x2.fill",
                        iconColor: HorcruxTheme.accentPurple,
                        title: L10n.SettingsAppearance.displayMode
                    )
                    Spacer()
                    Picker("", selection: $appState.walletDisplayMode) {
                        Text(L10n.SettingsAppearance.modeStandard)
                            .tag(AppState.WalletDisplayMode.standard)
                        Text(L10n.SettingsAppearance.modeVault)
                            .tag(AppState.WalletDisplayMode.vault)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 200)
                    .accessibilityIdentifier("settings_walletDisplayModePicker")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassCard()

                if appState.walletDisplayMode == .vault {
                    HStack {
                        VaultSettingsRow(
                            icon: "eye.slash",
                            iconColor: HorcruxTheme.accentCyan,
                            title: L10n.SettingsAppearance.hideBalances,
                            subtitle: L10n.SettingsAppearance.hideBalancesHint
                        )
                        Spacer()
                        Toggle("", isOn: $appState.hideBalancesByDefault)
                            .labelsHidden()
                            .accessibilityIdentifier("settings_hideBalancesToggle")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .glassCard()

                    HStack {
                        VaultSettingsRow(
                            icon: "tag.fill",
                            iconColor: HorcruxTheme.warningAmber,
                            title: L10n.SettingsAppearance.envTag,
                            subtitle: L10n.SettingsAppearance.envTagHint
                        )
                        Spacer()
                        Toggle("", isOn: $appState.showEnvironmentTag)
                            .labelsHidden()
                            .accessibilityIdentifier("settings_envTagToggle")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .glassCard()
                }
            }
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
        if let net = EVMNetwork(rawValue: config.evmChainId) {
            parts.append("EVM: \(net.displayName)")
        } else {
            parts.append("EVM Chain \(config.evmChainId)")
        }
        parts.append(config.btcTestnet ? "BTC Testnet" : "BTC Mainnet")
        parts.append(config.solDevnet ? "SOL Devnet" : "SOL Mainnet")
        if health.probedCount > 0 {
            parts.append(health.summaryText)
        }
        return parts.joined(separator: " · ")
    }

    /// Color dot rendered on the RPC entry row to surface failing nodes without
    /// requiring the user to drill in. Gray = not yet probed this session,
    /// green = all probed chains OK, red = any failure.
    private var nodeHealthDotColor: Color? {
        guard health.probedCount > 0 else { return nil }
        return health.anyFailed ? HorcruxTheme.dangerRed : HorcruxTheme.successGreen
    }

    private var languageSummary: String {
        guard let arr = UserDefaults.standard.array(forKey: "AppleLanguages") as? [String],
              let first = arr.first else {
            return L10n.Settings.languageFollowSystem
        }
        if first.hasPrefix("zh") { return L10n.SettingsResidual.langZh }
        if first.hasPrefix("en") { return "English" }
        return first
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

    /// Marketing version from Info.plist, with the build number appended when
    /// present. Renders as either "0.3.0" or "0.3.0 (42)" so About always
    /// reflects what's actually installed instead of a stale hard-coded literal.
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        if let build = info?["CFBundleVersion"] as? String, !build.isEmpty, build != short {
            return "\(short) (\(build))"
        }
        return short
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
        .vaultForm()
    }
}

struct ChangePinView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private enum Step { case current, new, confirm }

    @State private var step: Step = .current
    @State private var currentPin = ""
    @State private var newPin = ""
    @State private var confirmPin = ""
    @State private var errorMessage: String?
    @State private var shakeOffset: CGFloat = 0

    private var stepTitle: String {
        switch step {
        case .current: return L10n.ChangePin.currentPin
        case .new: return L10n.ChangePin.newPin
        case .confirm: return L10n.ChangePin.confirmNewPin
        }
    }

    private var stepSubtitle: String {
        switch step {
        case .current: return L10n.ChangePin.submitHint
        case .new: return L10n.ChangePin.title
        case .confirm: return L10n.ChangePin.confirmNewPin
        }
    }

    private var activePin: Binding<String> {
        switch step {
        case .current: return $currentPin
        case .new: return $newPin
        case .confirm: return $confirmPin
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                HorcruxTheme.backgroundGradient.ignoresSafeArea()

                VStack(spacing: 24) {
                    Spacer()

                    AnimatedShieldLogo(size: 48)

                    VStack(spacing: 6) {
                        Text(stepTitle)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                        Text(L10n.ChangePin.title)
                            .font(.subheadline)
                            .foregroundStyle(HorcruxTheme.subtleText)
                    }

                    // Step indicator: three dots so users know where they
                    // are in the current → new → confirm wizard.
                    HStack(spacing: 8) {
                        ForEach(0..<3) { idx in
                            Circle()
                                .fill(stepIndex >= idx ? HorcruxTheme.accentPurple : Color.white.opacity(0.15))
                                .frame(width: 6, height: 6)
                        }
                    }

                    if let errorMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                            Text(errorMessage).font(.caption)
                        }
                        .foregroundStyle(HorcruxTheme.dangerRed)
                        .transition(.opacity)
                    }

                    if step == .new && !newPin.isEmpty {
                        PinStrengthIndicator(pin: newPin)
                            .padding(.horizontal, 32)
                    }

                    PinDotsField(
                        pin: activePin,
                        length: 6,
                        autoSubmit: true,
                        onComplete: advance,
                        dotsShakeOffset: shakeOffset
                    )
                    .accessibilityIdentifier("changePin_pinField_\(step)")

                    Spacer()
                }
                .padding(.horizontal, 32)
            }
            .preferredColorScheme(.dark)
            .navigationTitle(L10n.ChangePin.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.cancel) { dismiss() }
                }
            }
        }
    }

    private var stepIndex: Int {
        switch step {
        case .current: return 0
        case .new: return 1
        case .confirm: return 2
        }
    }

    private func advance() {
        switch step {
        case .current:
            // Pre-verify current PIN before letting user pick a new one,
            // so we fail fast instead of at the final submit.
            guard appState.verifyPin(currentPin) else {
                errorMessage = L10n.ChangePin.incorrectCurrent
                currentPin = ""
                Haptics.error()
                triggerShake()
                return
            }
            errorMessage = nil
            step = .new
        case .new:
            guard newPin.count >= 4 else {
                errorMessage = L10n.ChangePin.dontMatch
                newPin = ""
                Haptics.error()
                triggerShake()
                return
            }
            errorMessage = nil
            step = .confirm
        case .confirm:
            submit()
        }
    }

    private func submit() {
        guard newPin == confirmPin else {
            errorMessage = L10n.ChangePin.dontMatch
            confirmPin = ""
            Haptics.error()
            triggerShake()
            return
        }
        do {
            try appState.changePin(
                current: currentPin,
                new: newPin,
                walletStore: appState.walletStore
            )
            Haptics.success()
            dismiss()
        } catch AppError.invalidPin {
            errorMessage = L10n.ChangePin.incorrectCurrent
            Haptics.error()
            currentPin = ""
            newPin = ""
            confirmPin = ""
            step = .current
            triggerShake()
        } catch {
            errorMessage = L10n.ChangePin.saveFailed
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
}

/// Visual strength meter for numeric PINs.
private struct PinStrengthIndicator: View {
    let pin: String

    private var score: Int {
        var s = 0
        if pin.count >= 4 { s += 1 }
        if pin.count >= 6 { s += 1 }
        if pin.count >= 8 { s += 1 }
        // Penalise all-same or sequential digits
        let chars = Array(pin)
        if chars.count >= 2 {
            let allSame = chars.allSatisfy { $0 == chars.first }
            var isSequential = true
            for i in 1..<chars.count {
                if let a = chars[i-1].wholeNumberValue,
                   let b = chars[i].wholeNumberValue,
                   b - a == 1 { continue }
                isSequential = false
                break
            }
            if allSame || isSequential { s = max(s - 1, 0) }
        }
        // Bonus for mixed digits
        if Set(chars).count >= 4 { s += 1 }
        return min(s, 4)
    }

    private var label: String {
        switch score {
        case 0...1: return L10n.SettingsResidual.pinWeak
        case 2: return L10n.SettingsResidual.pinMedium
        case 3: return L10n.SettingsResidual.pinStrong
        default: return L10n.SettingsResidual.pinVeryStrong
        }
    }

    private var color: Color {
        switch score {
        case 0...1: return HorcruxTheme.dangerRed
        case 2: return HorcruxTheme.warningAmber
        case 3: return HorcruxTheme.warningAmber.opacity(0.85)
        default: return HorcruxTheme.successGreen
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<4) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(i < score ? color : Color.secondary.opacity(0.2))
                    .frame(height: 4)
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(color)
                .frame(width: 40, alignment: .trailing)
        }
    }
}

struct BlockchainNodeSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var config = NetworkConfig.shared
    @ObservedObject private var health = NodeHealthStore.shared
    @ObservedObject private var overrides = ChainEndpointOverrides.shared
    @State private var showResetConfirm = false
    @State private var showImportSheet = false
    @State private var showExportSheet = false
    @State private var importPasteText: String = ""
    @State private var importPreview: RPCConfigSnapshot? = nil
    @State private var importError: String? = nil
    @State private var exportJSON: String = ""
    @State private var pendingPreset: NetworkPreset?

    var body: some View {
        Form {
            Section(L10n.NodeSettings.quickPresets) {
                HStack(spacing: 12) {
                    ForEach(NetworkPreset.all) { preset in
                        Button {
                            if isCurrentPreset(preset) { return }
                            pendingPreset = preset
                        } label: {
                            Text(preset.name)
                                .font(.subheadline.bold())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.bordered)
                        .tint(isCurrentPreset(preset) ? HorcruxTheme.successGreen : HorcruxTheme.accentPurple)
                        .accessibilityLabel(L10n.NodeSettings.switchTo(preset.name))
                    }
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.NodeSettings.etherscanKeyLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SecureField(L10n.NodeSettings.pasteKeyPlaceholder, text: $config.etherscanAPIKey)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("nodeSettings_etherscanKey")
                    Text(L10n.NodeSettings.etherscanKeyHelp)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.NodeSettings.heliusKeyLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SecureField(L10n.NodeSettings.pasteKeyPlaceholder, text: $config.heliusAPIKey)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if !config.heliusAPIKey.isEmpty {
                        Button(L10n.NodeSettings.useHelius) {
                            ChainEndpointOverrides.shared.set(
                                RPCProviderTemplate.helius(mainnet: !config.solDevnet),
                                for: .solana)
                        }
                        .font(.caption)
                    }
                }
            } header: {
                Text(L10n.NodeSettings.apiKeysSection)
            } footer: {
                Text(L10n.NodeSettings.apiKeysHint)
            }

            NodeProviderSection()
            ChainEndpointList()

            EndpointCooldownSection()

            Section {
                NavigationLink {
                    ImportExportSubView(
                        config: config,
                        showExportSheet: $showExportSheet,
                        showImportSheet: $showImportSheet,
                        exportJSON: $exportJSON,
                        importPasteText: $importPasteText,
                        importPreview: $importPreview,
                        importError: $importError
                    )
                } label: {
                    Label(L10n.NodeSettings.importExportSection, systemImage: "square.and.arrow.up.on.square")
                }
            }

            Section {
                Button(L10n.NodeSettings.resetToDefaults) {
                    showResetConfirm = true
                }
                .foregroundStyle(HorcruxTheme.dangerRed)
                .accessibilityHint(L10n.NodeSettings.resetHint)
                .accessibilityIdentifier("nodeSettings_resetButton")
            }
        }
        .navigationTitle(L10n.NodeSettings.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await health.refreshAll(config: config, force: true) }
                } label: {
                    if health.refreshingAll {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.body.weight(.semibold))
                    }
                }
                .tint(HorcruxTheme.accentCyan)
                .disabled(health.refreshingAll)
                .accessibilityLabel(L10n.NodeStatus.testAll)
                .accessibilityIdentifier("nodeSettings_testAllButton")
            }
        }
        .vaultForm()
        .task {
            // Auto-probe all endpoints when the page opens so the user sees
            // current status without needing to tap anything. `refreshAll` is
            // a no-op when another refresh is already in flight.
            await health.refreshAll(config: config)
        }
        .alert(L10n.NodeSettings.presetConfirmTitle, isPresented: Binding(
            get: { pendingPreset != nil },
            set: { if !$0 { pendingPreset = nil } }
        )) {
            Button(L10n.NodeSettings.presetApply) {
                if let p = pendingPreset { config.applyPreset(p) }
                pendingPreset = nil
            }
            if !presetGoverningOverrides.isEmpty {
                Button(L10n.NodeSettings.presetApplyAndClear) {
                    let affected = presetGoverningOverrides
                    affected.forEach { overrides.clear($0) }
                    if let p = pendingPreset { config.applyPreset(p) }
                    pendingPreset = nil
                }
            }
            Button(L10n.Common.cancel, role: .cancel) { pendingPreset = nil }
        } message: {
            if let p = pendingPreset {
                Text(presetPreviewMessage(p))
            }
        }
        .alert(L10n.NodeSettings.resetConfirmTitle, isPresented: $showResetConfirm) {
            Button(L10n.NodeSettings.reset, role: .destructive) { config.resetToDefaults() }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.NodeSettings.resetMessage)
        }
        .sheet(isPresented: $showExportSheet) {
            RPCConfigExportSheet(json: exportJSON)
        }
        .sheet(isPresented: $showImportSheet) {
            RPCConfigImportSheet(
                pasteText: $importPasteText,
                preview: $importPreview,
                error: $importError,
                onApply: { snapshot in
                    snapshot.apply(to: config)
                    showImportSheet = false
                }
            )
        }
    }

    private func isCurrentPreset(_ preset: NetworkPreset) -> Bool {
        // Compare only the logical network identity (chainId + flags), not URLs.
        // Only ethereum, bitcoin and solana are governed by presets — applyPreset
        // does not touch litecoin, tron, polygon, etc. An override on one of the
        // preset-governed chains means the preset's network claim isn't fully in
        // effect; an override on an unrelated chain (e.g. Litecoin) does not
        // invalidate the preset's domain.
        guard presetGoverningOverrides.isEmpty else { return false }
        return config.evmChainId == preset.evmChainId &&
               config.btcTestnet == preset.btcTestnet &&
               config.solDevnet == preset.solDevnet
    }

    /// Chains that are governed by presets AND currently have a custom override.
    /// Used consistently for badge, warning message, and the "Apply and clear" button
    /// so all three reflect the same scope.
    private var presetGoverningOverrides: [Chain] {
        return overrides.allChains().filter { NetworkPreset.governedChains.contains($0) }
    }

    private func presetPreviewMessage(_ p: NetworkPreset) -> String {
        let ethNet = (EVMNetwork(rawValue: p.evmChainId) ?? .mainnet).displayName
        let btcNet = p.btcTestnet ? L10n.NodeSettings.testnet : L10n.NodeSettings.mainnet
        let solNet = p.solDevnet ? L10n.NodeSettings.devnet  : L10n.NodeSettings.mainnet
        var msg = "ETH · \(ethNet)\nBTC · \(btcNet)\nSOL · \(solNet)"
        let affected = presetGoverningOverrides
        if !affected.isEmpty {
            let names = affected.map(\.displayName).joined(separator: ", ")
            msg += "\n\n" + L10n.NodeSettings.presetOverrideWarning(count: affected.count, names: names)
        }
        return msg
    }
}

/// Inline warning chip for a user-entered RPC URL. Hidden when the URL is
/// valid HTTPS. Shown in amber for insecure http:// and in red for malformed.
/// Compact single-line status strip for an RPC/REST URL field: combines
/// provider identification, key-security hint, and URL validation into one
/// horizontal row so the Settings page doesn't stack 3 separate caption
/// lines under every URL input. Each sub-badge still self-hides when it has
/// nothing to say, so URLs with no provider match / no `{KEY}` / no warning
/// collapse down to zero height.
struct RPCStatusStrip: View {
    let urlString: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ProviderBadge(urlString: urlString)
            KeySecurityHint(urlString: urlString)
            URLValidationHint(urlString: urlString)
            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }
}

/// Inline chip row for one-tap switching between known-good REST/RPC
/// endpoints. Each chip writes `binding` to its URL. The currently
/// active preset renders filled green; the others render outlined so
/// the user sees at a glance which one is in use.
///
/// Used for zero-code-change providers (Esplora for BTC/LTC, Tron
/// Full-HTTP mirrors for TRX, etc.) — if a mirror speaks the same
/// protocol as the default, it's just a one-line tuple addition.
struct RPCPresetChips: View {
    let presets: [(label: String, url: String)]
    @Binding var binding: String

    var body: some View {
        HStack(spacing: 8) {
            ForEach(presets, id: \.url) { p in
                let active = binding == p.url
                Button {
                    if !active { binding = p.url }
                } label: {
                    Text(p.label)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .tint(active ? HorcruxTheme.successGreen : HorcruxTheme.accentPurple)
                .controlSize(.mini)
                .accessibilityLabel("\(p.label)\(active ? " (active)" : "")")
            }
            Spacer(minLength: 0)
        }
    }
}

/// Back-compat alias for the earlier, BTC/LTC-specific name.
typealias EsploraPresetChips = RPCPresetChips

struct URLValidationHint: View {
    let urlString: String

    var body: some View {
        let v = NetworkConfig.validate(url: urlString)
        if let warning = v.warning {
            HStack(spacing: 6) {
                Image(systemName: v.ok ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                    .font(.caption2)
                Text(warning)
                    .font(.caption2)
            }
            .foregroundStyle(v.ok ? HorcruxTheme.warningAmber : HorcruxTheme.dangerRed)
            .accessibilityLabel(warning)
        }
    }
}

/// Shows a connectivity indicator for a blockchain node, backed by the shared
/// `NodeHealthStore` so results survive across re-renders and match the rollup
/// on the Settings entry row. Tapping the row re-probes *this* chain only.
struct NodeStatusRow: View {
    let chain: Chain
    @ObservedObject private var health = NodeHealthStore.shared

    var body: some View {
        let snap = health.snapshot(for: chain)
        return Button {
            Task { await health.refresh(chain: chain) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if case .checking = snap.status {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Circle().fill(color(for: snap.status))
                            .frame(width: 8, height: 8)
                    }
                    Text(label(for: snap.status))
                        .font(.caption)
                        .foregroundStyle(HorcruxTheme.subtleText)
                    Spacer()
                    Text(L10n.Common.test)
                        .font(.caption)
                        .foregroundStyle(HorcruxTheme.accentCyan)
                }
                if snap.isOk {
                    HStack(spacing: 8) {
                        if let ms = snap.latencyMs {
                            Label(L10n.NodeStatus.latencyMs(ms), systemImage: "bolt.fill")
                                .labelStyle(.titleOnly)
                                .font(.caption2)
                                .foregroundStyle(latencyColor(ms))
                        }
                        if snap.latencyHistory.count >= 2 {
                            LatencySparkline(samples: snap.latencyHistory)
                                .frame(width: 56, height: 14)
                                .accessibilityLabel(L10n.NodeStatus.latencyTrend)
                        }
                        if let h = snap.blockHeight {
                            Text(L10n.NodeStatus.blockHeight(h))
                                .font(.caption2)
                                .foregroundStyle(HorcruxTheme.subtleText)
                        }
                    }
                }
                if let rel = snap.lastOkRelative(), !snap.isOk {
                    Text(L10n.NodeStatus.lastOkPrefix(rel))
                        .font(.caption2)
                        .foregroundStyle(HorcruxTheme.subtleText)
                }
                if let warning = snap.mismatchWarning {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                        Text(warning).font(.caption2)
                    }
                    .foregroundStyle(HorcruxTheme.dangerRed)
                    .accessibilityLabel(warning)
                }
                if let lag = snap.lagWarning {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.badge.exclamationmark")
                            .font(.caption2)
                        Text(lag).font(.caption2)
                    }
                    .foregroundStyle(HorcruxTheme.warningAmber)
                    .accessibilityLabel(lag)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("nodeStatus_\(chain.rawValue)")
    }

    private func color(for status: NodeHealthSnapshot.Status) -> Color {
        switch status {
        case .unknown, .checking: return HorcruxTheme.subtleText
        case .ok: return HorcruxTheme.successGreen
        case .failed: return HorcruxTheme.dangerRed
        }
    }

    private func label(for status: NodeHealthSnapshot.Status) -> String {
        switch status {
        case .unknown: return L10n.NodeStatus.notChecked
        case .checking: return L10n.NodeStatus.checking
        case .ok: return L10n.NodeStatus.connected
        case .failed(let msg): return msg
        }
    }

    private func latencyColor(_ ms: Int) -> Color {
        switch ms {
        case ..<300: return HorcruxTheme.successGreen
        case ..<1000: return HorcruxTheme.warningAmber
        default: return HorcruxTheme.dangerRed
        }
    }
}

/// Drop-down list of built-in fallback endpoints for a chain. Lets users swap
/// RPC providers without typing a URL. Pulls candidates from
/// `RPCFallbacks.endpoints(for:config:)` and filters out the currently active
/// URL so the menu shows only *alternatives*.
struct EndpointSwitcher: View {
    @ObservedObject var editor: ChainEndpointEditor
    @ObservedObject private var config = NetworkConfig.shared
    @ObservedObject private var overrides = ChainEndpointOverrides.shared

    var body: some View {
        let chain = editor.chain
        let current = config.rpcURL(for: chain)
        let candidates = RPCFallbacks.endpoints(for: chain, config: config)
            .filter { $0 != current && $0 != overrides.url(for: chain) }
        if !candidates.isEmpty {
            Menu {
                ForEach(candidates, id: \.self) { url in
                    Button {
                        // editor.select atomically updates both draft and storage,
                        // so commit() on .onDisappear finds no diff to write.
                        editor.select(url: url)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(URL(string: url)?.host ?? url)
                            Text(url).font(.caption2)
                        }
                    }
                }
            } label: {
                Label(L10n.NodeStatus.switchEndpoint, systemImage: "arrow.left.arrow.right")
                    .font(.caption)
            }
            .accessibilityIdentifier("nodeStatus_switchEndpoint_\(chain.rawValue)")
        }
    }
}

/// Key-security chip for an RPC URL field.
///
/// * Blue "密钥已加密存储" when the URL uses the `{KEY}` placeholder, i.e. the
///   API key lives in Keychain and is substituted at request time.
/// * Amber "URL 内嵌密钥" when the URL looks like it contains a raw 20+
///   character key (common Alchemy/Infura/Helius pattern), nudging the user
///   to split it out.
struct KeySecurityHint: View {
    let urlString: String

    var body: some View {
        if urlString.contains("{KEY}") {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .font(.caption2)
                Text(L10n.NodeStatus.keyStoredSecurely)
                    .font(.caption2)
            }
            .foregroundStyle(HorcruxTheme.accentCyan)
        } else if Self.looksLikeBakedKey(urlString) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                Text(L10n.NodeStatus.bakedKeyWarning)
                    .font(.caption2)
            }
            .foregroundStyle(HorcruxTheme.warningAmber)
        }
    }

    /// Heuristic: last path segment (or query value) looks like a hex/base64
    /// secret — length ≥ 20, no slashes, not a known hostname fragment.
    static func looksLikeBakedKey(_ s: String) -> Bool {
        guard let url = URL(string: s) else { return false }
        // Check query first: `?api-key=…`
        if let q = url.query, let eq = q.range(of: "=") {
            let val = String(q[eq.upperBound...])
            if val.count >= 20, val.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil {
                return true
            }
        }
        // Then trailing path segment
        let comps = url.pathComponents.filter { $0 != "/" }
        if let last = comps.last, last.count >= 20,
           last.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil,
           !["rpc", "api", "mainnet", "testnet", "devnet"].contains(last.lowercased()) {
            return true
        }
        return false
    }
}

/// Small pill that names the recognised provider behind a URL (e.g. "Alchemy",
/// "PublicNode · 公共"). Public providers also get a ⓘ tooltip warning about
/// IP / address correlation. When the URL is currently in the RPC fallback
/// router's cooldown window (auth-failed / transiently down), a small red
/// dot is prefixed so the user sees at a glance that routing is degraded.
struct ProviderBadge: View {
    let urlString: String
    @State private var showPrivacyTip = false
    @State private var showCooldownTip = false
    @State private var cooldownTick = 0 // drives re-render while sheet cycles

    var body: some View {
        let provider = RPCProvider.identify(urlString)
        let isCoolingDown = RPCEndpointHealth.isCoolingDown(urlString)
        let _ = cooldownTick // keep dependency for refresh
        if provider != .unknown {
            HStack(spacing: 6) {
                if isCoolingDown {
                    Button {
                        showCooldownTip = true
                    } label: {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                            .accessibilityLabel(Text(L10n.NodeStatus.cooldownBadge))
                    }
                    .buttonStyle(.plain)
                }
                Image(systemName: provider.isPublic ? "globe" : "key.fill")
                    .font(.caption2)
                Text(provider.label)
                    .font(.caption2.weight(.semibold))
                if !provider.tag.isEmpty {
                    Text("· \(provider.tag)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if provider.isPublic {
                    Button {
                        showPrivacyTip = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                }
            }
            .foregroundStyle(provider.isPublic ? HorcruxTheme.subtleText : HorcruxTheme.accentCyan)
            .alert(L10n.NodeStatus.publicPrivacyNote, isPresented: $showPrivacyTip) {
                Button(L10n.Common.ok, role: .cancel) {}
            }
            .alert(L10n.NodeStatus.cooldownBadge, isPresented: $showCooldownTip) {
                Button(L10n.Common.ok, role: .cancel) {}
            } message: {
                Text(L10n.NodeStatus.cooldownExplain)
            }
            .onAppear { cooldownTick &+= 1 }
        }
    }
}

/// Per-chain footer with "Copy URL" and "Reset this chain" actions. Placed
/// below the RPC URL field so users can quickly fall back to defaults for a
/// single chain without running the page-level "reset to defaults".
///
/// "Copy URL" copies the raw override URL (un-substituted, may contain
/// {KEY}). Copying rpcURL(for:) would put a substituted API key on the
/// clipboard — even through SecureClipboard, a resolved key is a secret
/// leaving the app. The override is exactly what the user typed, which is
/// safe to copy and paste elsewhere.
struct ChainFieldActions: View {
    @ObservedObject var editor: ChainEndpointEditor
    @ObservedObject private var overrides = ChainEndpointOverrides.shared

    var body: some View {
        let chain = editor.chain
        HStack(spacing: 12) {
            if let url = overrides.url(for: chain), !url.isEmpty {
                Button {
                    // Intentionally copies the raw override template, not
                    // rpcURL(for:). rpcURL substitutes the real API key into
                    // the URL; copying it would send a resolved secret to the
                    // clipboard. The raw template is exactly what the user
                    // typed and is safe to copy for backup or re-entry.
                    SecureClipboard.copy(url)
                } label: {
                    Label(L10n.NodeStatus.copyURL, systemImage: "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(HorcruxTheme.accentCyan)
            }
            Spacer()
            Button {
                // editor.reset atomically clears both draft and storage,
                // so commit() on .onDisappear finds draft == "" == stored and
                // does nothing. Without this atomicity the cleared override
                // would be resurrected on navigate-back.
                editor.reset()
            } label: {
                Label(L10n.NodeStatus.resetThisChain, systemImage: "arrow.uturn.backward")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(HorcruxTheme.subtleText)
            .accessibilityIdentifier("nodeStatus_resetChain_\(chain.rawValue)")
        }
    }
}

/// Diagnostic panel on the node-settings page listing RPC URLs that the
/// fallback router is currently avoiding (auth-failed or transiently
/// down). Each row shows remaining cool-down and offers a "试试看"
/// button that clears the entry so the user can confirm a fix took
/// effect without waiting 30 minutes.
///
/// Hidden entirely when no URLs are cooling — the vast majority of the
/// time the router is fully green.
struct EndpointCooldownSection: View {
    @State private var entries: [(url: String, until: Date)] = []
    @State private var now: Date = Date()
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if !entries.isEmpty {
                Section {
                    ForEach(entries, id: \.url) { entry in
                        row(for: entry)
                    }
                } header: {
                    ReadOnlySectionHeader(title: L10n.NodeStatus.cooldownSectionTitle)
                } footer: {
                    Text(L10n.NodeStatus.cooldownSectionFooter)
                }
            }
        }
        .onAppear { refresh() }
        .onReceive(tick) { _ in refresh() }
    }

    private func row(for entry: (url: String, until: Date)) -> some View {
        let host = URL(string: entry.url)?.host ?? entry.url
        let provider = RPCProvider.identify(entry.url)
        let remaining = max(0, Int(entry.until.timeIntervalSince(now)))
        let mins = remaining / 60
        let secs = remaining % 60
        let rel = mins > 0 ? "\(mins)m\(secs)s" : "\(secs)s"
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    Text(provider == .unknown ? host : "\(provider.label) · \(host)")
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(L10n.NodeStatus.cooldownRemaining(rel))
                    .font(.caption2)
                    .foregroundStyle(HorcruxTheme.subtleText)
            }
            Spacer(minLength: 8)
            Button(L10n.NodeStatus.cooldownRetry) {
                RPCEndpointHealth.clear(entry.url)
                refresh()
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .tint(HorcruxTheme.accentCyan)
        }
    }

    private func refresh() {
        now = Date()
        entries = RPCEndpointHealth.activeSnapshot()
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

// MARK: - Replace Device / Share Refresh

/// Explains the replace-device migration path. True CGGMP21 share refresh (rotate
/// secret shares while keeping the same public key) requires dedicated Rust FFI
/// that is not yet exposed; until then, the recommended workflow is:
/// 1. Create a fresh wallet with a new device in place of the lost one
/// 2. Transfer funds from the old wallet to the new one
///
/// Surfaced here so users understand the recovery story before they need it.
struct ReplaceDeviceInfoView: View {
    @EnvironmentObject var appState: AppState
    @State private var refreshTarget: Wallet?

    /// All refreshable accounts (n-of-n CGGMP21 ECDSA), grouped so a single
    /// DKG/account shows once even when it spans multiple chains.
    private var refreshableAccounts: [ShardAccount] {
        let wallets = appState.walletStore.wallets.filter { w in
            w.threshold == w.totalParties &&
            w.chain.curveType == .secp256k1 &&
            !w.hidden
        }
        return ShardAccount.group(wallets)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label {
                    HStack(spacing: 6) {
                        Text(L10n.SettingsResidual.replaceTitle).font(.title2.bold())
                        InfoHint(title: L10n.SettingsResidual.replaceTitle,
                                 body: L10n.SettingsResidual.replaceIntro)
                    }
                } icon: {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .foregroundStyle(HorcruxTheme.accentCyan)
                }

                HStack(spacing: 6) {
                    Label {
                        Text(L10n.SettingsResidual.rotateExplanationTitle).font(.subheadline.weight(.semibold))
                    } icon: {
                        Image(systemName: "sparkle").foregroundStyle(HorcruxTheme.accentCyan)
                    }
                    InfoHint(title: L10n.SettingsResidual.rotateExplanationTitle,
                             body: L10n.SettingsResidual.rotateExplanationBody)
                    Spacer()
                }

                if !refreshableAccounts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label {
                            Text(L10n.Refresh.entryPoint).font(.subheadline.weight(.semibold))
                        } icon: {
                            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(HorcruxTheme.accentCyan)
                        }
                        Text(L10n.Refresh.entryPointSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        VStack(spacing: 8) {
                            ForEach(refreshableAccounts) { acct in
                                accountRow(for: acct)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(HorcruxTheme.accentCyan.opacity(0.08)))
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Label {
                            Text(L10n.SettingsResidual.comingSoon).font(.subheadline.weight(.semibold))
                        } icon: {
                            Image(systemName: "sparkles").foregroundStyle(HorcruxTheme.warningAmber)
                        }
                        Text(L10n.SettingsResidual.refreshShardsComingSoon)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(HorcruxTheme.warningAmber.opacity(0.1)))
                }

                VStack(alignment: .leading, spacing: 12) {
                    stepRow(index: 1, title: L10n.SettingsResidual.step1Title, body: L10n.SettingsResidual.step1Body)
                    stepRow(index: 2, title: L10n.SettingsResidual.step2Title, body: L10n.SettingsResidual.step2Body)
                    stepRow(index: 3, title: L10n.SettingsResidual.step3Title, body: L10n.SettingsResidual.step3Body)
                    stepRow(index: 4, title: L10n.SettingsResidual.step4Title, body: L10n.SettingsResidual.step4Body)
                }
            }
            .padding()
        }
        .navigationTitle(L10n.SettingsResidual.replaceNavTitle)
        .navigationBarTitleDisplayMode(.inline)
        .darkBackground()
        .toolbarColorScheme(.dark, for: .navigationBar)
        .sheet(item: $refreshTarget) { wallet in
            RefreshShardSheet(wallet: wallet, appState: appState)
                .environmentObject(appState)
        }
    }

    @ViewBuilder
    private func accountRow(for acct: ShardAccount) -> some View {
        let representative = acct.wallets.first!
        let last = RefreshTracker.lastRefresh(accountId: acct.id)
        let days = last.map { Calendar.current.dateComponents([.day], from: $0, to: Date()).day ?? 0 }
        let daysText = days.map { L10n.WalletHome.securityRotationAgo($0) } ?? L10n.WalletHome.securityRotationNever
        let chainsLabel = acct.wallets.map(\.chain.symbol).joined(separator: " · ")

        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(acct.name.isEmpty ? L10n.SecurityDetail.shardGenericName : acct.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                Text("\(chainsLabel) · \(daysText)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            Button {
                refreshTarget = representative
            } label: {
                Text(L10n.Refresh.startButton)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(HorcruxTheme.accentCyan))
                    .foregroundStyle(.black)
            }
            .accessibilityIdentifier("refresh_startButton_\(acct.id.prefix(8))")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
    }

    private func stepRow(index: Int, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(index)")
                .font(.headline.bold().monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(HorcruxTheme.accentCyan))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(body).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Read-only chain section header

private struct ReadOnlySectionHeader: View {
    let title: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(title)
            Text(L10n.NodeSettings.readOnlyTag)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(Color.secondary.opacity(0.18))
                )
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - RPC config import/export

/// One row in the import-preview diff table.
struct DiffRow {
    let label: String
    let before: String
    let after: String
}

/// A JSON-serializable snapshot of the user-editable RPC settings.
/// Intentionally omits API keys so exports are safe to share for debugging.
struct RPCConfigSnapshot: Codable, Equatable {
    var ethereumRPC: String
    var bitcoinAPI: String
    var litecoinAPI: String
    var solanaRPC: String
    var tronAPI: String
    var evmChainId: UInt64
    var btcTestnet: Bool
    var solDevnet: Bool
    var ethereumWSS: String?
    var solanaWSS: String?
    // Version 2 fields — all optional so pre-versioning exports still decode.
    var version: Int?
    var activeProvider: NodeProvider?
    // Raw URL strings; may contain {KEY} placeholders or literal API keys.
    // Do not strip them: stripping breaks round-tripping. Treat exports as
    // sensitive and advise users not to share them publicly.
    var chainOverrides: [String: String]?

    /// The wire-format version of the export schema. Increment whenever a
    /// field is added or removed that Codable would silently drop on an older
    /// build. This is NOT the migration version (NodeSettingsMigration).
    static let currentVersion = 2

    /// Hard ceiling on `chainOverrides` entries. A single socially-engineered
    /// paste could otherwise inflate UserDefaults and be silently re-loaded on
    /// every launch.
    static let maxChainOverrides = 256
    /// Per-key character limit for `chainOverrides`. Chain.rawValue strings are
    /// display names ≤ ~20 chars; this leaves ample room for future chains.
    static let maxOverrideKeyLength = 128
    /// Per-value character limit for `chainOverrides`. A bare HTTPS URL is well
    /// under 2 KB; this still permits lengthy query strings.
    static let maxOverrideValueLength = 2048

    enum ImportFailure: Error, Equatable {
        case malformed
        case versionTooNew
        /// The `chainOverrides` map exceeds the entry count, key-length, or
        /// value-length ceiling. Separate from `malformed` so the user gets
        /// "too many endpoint settings" rather than "check the format".
        case oversized
    }

    init(from config: NetworkConfig) {
        self.ethereumRPC = config.legacyEthereumRPC
        self.bitcoinAPI = config.legacyBitcoinAPI
        self.litecoinAPI = config.legacyLitecoinAPI
        self.solanaRPC = config.legacySolanaRPC
        self.tronAPI = config.legacyTronAPI
        self.evmChainId = config.evmChainId
        self.btcTestnet = config.btcTestnet
        self.solDevnet = config.solDevnet
        self.ethereumWSS = config.ethereumWSS
        self.solanaWSS = config.solanaWSS
        self.version = RPCConfigSnapshot.currentVersion
        self.activeProvider = config.activeProvider
        self.chainOverrides = ChainEndpointOverrides.shared.snapshot()
    }

    func jsonString() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decodes and validates the snapshot, distinguishing a well-formed but
    /// too-new format from malformed JSON so callers can show an honest error.
    static func decodeWithReason(_ text: String) -> Result<RPCConfigSnapshot, ImportFailure> {
        guard let data = text.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(RPCConfigSnapshot.self, from: data)
        else { return .failure(.malformed) }
        // A missing version is a pre-versioning export and is fine. A higher
        // one means fields this build cannot represent — Codable would drop
        // them without a word.
        if let v = snapshot.version, v > currentVersion { return .failure(.versionTooNew) }
        // Reject rather than truncate: silently dropping entries is the
        // failure mode this whole versioning scheme exists to prevent.
        if let overrides = snapshot.chainOverrides {
            guard overrides.count <= maxChainOverrides,
                  overrides.keys.allSatisfy({ $0.count <= maxOverrideKeyLength }),
                  overrides.values.allSatisfy({ $0.count <= maxOverrideValueLength })
            else { return .failure(.oversized) }
        }
        return .success(snapshot)
    }

    /// Convenience wrapper for tests and callers that only need success/failure.
    /// `decodeWithReason` is the production entry point: ImportSheet uses it to
    /// show distinct error messages for malformed JSON, oversized maps, and
    /// exports from a newer app version. Do not route ImportSheet back to this.
    static func decode(_ text: String) -> RPCConfigSnapshot? {
        if case .success(let snap) = decodeWithReason(text) { return snap }
        return nil
    }

    func apply(to config: NetworkConfig) {
        if config.legacyEthereumRPC != ethereumRPC { config.legacyEthereumRPC = ethereumRPC }
        if config.legacyBitcoinAPI != bitcoinAPI { config.legacyBitcoinAPI = bitcoinAPI }
        if config.legacyLitecoinAPI != litecoinAPI { config.legacyLitecoinAPI = litecoinAPI }
        if config.legacySolanaRPC != solanaRPC { config.legacySolanaRPC = solanaRPC }
        if config.legacyTronAPI != tronAPI { config.legacyTronAPI = tronAPI }
        if config.evmChainId != evmChainId { config.evmChainId = evmChainId }
        if config.btcTestnet != btcTestnet { config.btcTestnet = btcTestnet }
        if config.solDevnet != solDevnet { config.solDevnet = solDevnet }
        let incomingEthWSS = ethereumWSS ?? ""
        if config.ethereumWSS != incomingEthWSS { config.ethereumWSS = incomingEthWSS }
        let incomingSolWSS = solanaWSS ?? ""
        if config.solanaWSS != incomingSolWSS { config.solanaWSS = incomingSolWSS }
        // Only apply provider and overrides from versioned exports. A legacy
        // import (version == nil) cannot distinguish "activeProvider not set"
        // from "field not present in JSON", so we leave what the user has
        // configured rather than silently clearing it.
        if version != nil {
            config.activeProvider = activeProvider
            if let overrides = chainOverrides {
                // Atomic replacement: one lock, one UserDefaults write, one
                // publish. Unknown keys are passed through verbatim so a
                // newer build's overrides survive a downgrade and round-trip.
                ChainEndpointOverrides.shared.replaceAll(with: overrides)
            }
        }
    }

    /// Chain keys in `chainOverrides` that this build cannot show or use because
    /// it does not recognise them as `Chain` cases. They are preserved in storage
    /// by `replaceAll(with:)` and will work again after an app update.
    var unrecognisedChainKeys: [String] {
        guard let overrides = chainOverrides else { return [] }
        return overrides.keys.filter { Chain(rawValue: $0) == nil }.sorted()
    }

    /// Human-readable per-field diff against the live config. Empty = no changes.
    /// Rows are present only for fields that `apply(to:)` will actually write:
    /// provider and override rows are omitted for legacy imports (version == nil).
    func diffRows(against config: NetworkConfig) -> [DiffRow] {
        var rows: [DiffRow] = []
        func add(_ label: String, _ before: String, _ after: String) {
            if before != after { rows.append(DiffRow(label: label, before: before, after: after)) }
        }
        add("Ethereum RPC", config.legacyEthereumRPC, ethereumRPC)
        add("Bitcoin API", config.legacyBitcoinAPI, bitcoinAPI)
        add("Litecoin API", config.legacyLitecoinAPI, litecoinAPI)
        add("Solana RPC", config.legacySolanaRPC, solanaRPC)
        add("Tron API", config.legacyTronAPI, tronAPI)
        add("EVM Chain ID", String(config.evmChainId), String(evmChainId))
        add("BTC Testnet", config.btcTestnet ? "on" : "off", btcTestnet ? "on" : "off")
        add("SOL Devnet", config.solDevnet ? "on" : "off", solDevnet ? "on" : "off")
        add("Ethereum WSS", config.ethereumWSS, ethereumWSS ?? "")
        add("Solana WSS", config.solanaWSS, solanaWSS ?? "")
        // Version-2 fields: only emit when apply(to:) will actually write them.
        if version != nil {
            let noProvider = L10n.NodeSettings.providerPublicDefaults
            add(L10n.NodeSettings.providerPicker,
                config.activeProvider?.displayName ?? noProvider,
                activeProvider?.displayName ?? noProvider)
            if let incomingOverrides = chainOverrides {
                let liveOverrides = ChainEndpointOverrides.shared.snapshot()
                let noOverride = L10n.NodeSettings.useDefault
                // Union of both sides so removals appear too. All keys included —
                // unknown ones get a row so Apply is never greyed out for a real change.
                let allRawChains = Set(liveOverrides.keys).union(incomingOverrides.keys)
                for rawChain in allRawChains.sorted() {
                    // Normalise the incoming value the same way set(_:for:) does so
                    // a whitespace-only value does not produce a phantom diff row.
                    let incomingTrimmed = (incomingOverrides[rawChain] ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let after = incomingTrimmed.isEmpty ? noOverride : incomingTrimmed
                    let before = liveOverrides[rawChain] ?? noOverride
                    add(rawChain, before, after)
                }
            }
        }
        return rows
    }
}

private struct ImportExportSubView: View {
    @ObservedObject var config: NetworkConfig
    @Binding var showExportSheet: Bool
    @Binding var showImportSheet: Bool
    @Binding var exportJSON: String
    @Binding var importPasteText: String
    @Binding var importPreview: RPCConfigSnapshot?
    @Binding var importError: String?

    var body: some View {
        Form {
            Section {
                Button {
                    exportJSON = RPCConfigSnapshot(from: config).jsonString() ?? ""
                    showExportSheet = true
                } label: {
                    Label(L10n.NodeSettings.exportConfig, systemImage: "square.and.arrow.up")
                }
                Button {
                    importPasteText = ""
                    importPreview = nil
                    importError = nil
                    showImportSheet = true
                } label: {
                    Label(L10n.NodeSettings.importConfig, systemImage: "square.and.arrow.down")
                }
            } footer: {
                Text(L10n.NodeSettings.exportNote)
            }
        }
        .vaultForm()
        .navigationTitle(L10n.NodeSettings.importExportSection)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct RPCConfigExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let json: String
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.NodeSettings.exportNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(json)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                }
                .padding()
            }
            .navigationTitle(L10n.NodeSettings.exportConfig)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.Common.close) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        SecureClipboard.copy(json)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                    } label: {
                        Label(copied ? L10n.Common.copied : L10n.Common.copy,
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }
            }
        }
    }
}

private struct RPCConfigImportSheet: View {
    @ObservedObject private var config = NetworkConfig.shared
    @Environment(\.dismiss) private var dismiss
    @Binding var pasteText: String
    @Binding var preview: RPCConfigSnapshot?
    @Binding var error: String?
    var onApply: (RPCConfigSnapshot) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.NodeSettings.importPasteTitle) {
                    TextEditor(text: $pasteText)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 140)
                        .onChange(of: pasteText) { _, newValue in
                            parse(newValue)
                        }
                    if pasteText.isEmpty {
                        Text(L10n.NodeSettings.importPastePlaceholder)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        if let s = UIPasteboard.general.string { pasteText = s }
                    } label: {
                        Label(L10n.Common.copy + " ← " + "Clipboard",
                              systemImage: "doc.on.clipboard")
                    }
                }

                if let err = error {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(HorcruxTheme.dangerRed)
                            .font(.footnote)
                    }
                }

                if let snap = preview {
                    let rows = snap.diffRows(against: config)
                    let unrecognisedChains = snap.unrecognisedChainKeys
                    Section(L10n.NodeSettings.importPreviewTitle) {
                        if rows.isEmpty {
                            Text(L10n.NodeSettings.importNoChanges)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.label).font(.caption.weight(.semibold))
                                    HStack(alignment: .top, spacing: 6) {
                                        Text(row.before)
                                            .font(.system(.caption, design: .monospaced))
                                            .strikethrough()
                                            .foregroundStyle(.secondary)
                                        Image(systemName: "arrow.right")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        Text(row.after)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(HorcruxTheme.successGreen)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    if !unrecognisedChains.isEmpty {
                        Section {
                            Label(L10n.NodeSettings.importUnrecognisedChains(unrecognisedChains.joined(separator: ", ")),
                                  systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(HorcruxTheme.warningAmber)
                        }
                    }
                }
            }
            .navigationTitle(L10n.NodeSettings.importConfig)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.Common.cancel) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.NodeSettings.importApply) {
                        if let snap = preview { onApply(snap) }
                    }
                    .disabled(preview == nil || (preview?.diffRows(against: config).isEmpty ?? true))
                }
            }
        }
    }

    private func parse(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            preview = nil; error = nil; return
        }
        switch RPCConfigSnapshot.decodeWithReason(trimmed) {
        case .success(let snap):
            preview = snap
            error = nil
        case .failure(.versionTooNew):
            preview = nil
            error = L10n.NodeSettings.importVersionTooNew
        case .failure(.oversized):
            preview = nil
            error = L10n.NodeSettings.importOversized
        case .failure(.malformed):
            preview = nil
            error = L10n.NodeSettings.importParseFailed
        }
    }
}

// MARK: - Latency sparkline

/// Compact inline latency history chart rendered alongside the current
/// latency label in NodeStatusRow. Helps users spot whether a node is
/// stable ("flat line at 120ms") or jittery ("spikes to 800ms").
private struct LatencySparkline: View {
    let samples: [Int]

    var body: some View {
        GeometryReader { geo in
            let maxValue = max((samples.max() ?? 1), 1)
            let minValue = min((samples.min() ?? 0), maxValue)
            let range = max(maxValue - minValue, 1)
            let stepX = samples.count > 1 ? geo.size.width / CGFloat(samples.count - 1) : 0

            Path { path in
                for (i, v) in samples.enumerated() {
                    let x = CGFloat(i) * stepX
                    let normalized = CGFloat(v - minValue) / CGFloat(range)
                    let y = geo.size.height * (1 - normalized)
                    if i == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(color(for: samples.last ?? 0), lineWidth: 1.2)
        }
    }

    /// Colour tip per latest sample — same thresholds as the inline label.
    private func color(for ms: Int) -> Color {
        if ms < 300 { return HorcruxTheme.successGreen }
        if ms < 1000 { return HorcruxTheme.warningAmber }
        return HorcruxTheme.dangerRed
    }
}

// MARK: - Optional WebSocket field

/// Per-chain `wss://` input plus a manual "Test connection" button.
///
/// We deliberately don't auto-probe WebSockets because paid providers
/// bill subscriptions differently from HTTP reads — hammering `wss`
/// on every page open could eat a user's quota. The user explicitly
/// taps Test when they want verification.
struct WSSField: View {
    @Binding var url: String
    let kind: WebSocketProbe.Kind

    @State private var probing = false
    @State private var resultText: String?
    @State private var resultOK: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.NodeSettings.wssURLLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $url)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onChange(of: url) { _, _ in
                    // Any edit invalidates the last probe result.
                    resultText = nil
                }
            if url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(L10n.NodeSettings.wssHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Button {
                        Task { await runProbe() }
                    } label: {
                        if probing {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.mini)
                                Text(L10n.NodeSettings.wssTesting)
                            }
                        } else {
                            Label(L10n.NodeSettings.wssTest, systemImage: "bolt.horizontal.circle")
                        }
                    }
                    .disabled(probing)
                    .font(.caption)
                    .buttonStyle(.bordered)

                    if let text = resultText {
                        Text(text)
                            .font(.caption2)
                            .foregroundStyle(resultOK ? HorcruxTheme.successGreen : HorcruxTheme.dangerRed)
                    }
                }
            }
        }
    }

    private var placeholder: String {
        switch kind {
        case .evm:
            // Match whichever EVM provider the user already has a key for,
            // so the placeholder nudges them toward the template they can
            // actually authenticate against. Infura first because its WSS
            // path (`/ws/v3/{KEY}`) differs visibly from HTTP (`/v3/{KEY}`)
            // — that mismatch is the most common source of broken paste-ins.
            let cfg = NetworkConfig.shared
            let isSepolia = cfg.evmChainId == EVMNetwork.sepolia.rawValue
            if !cfg.infuraAPIKey.isEmpty {
                return isSepolia
                    ? "wss://sepolia.infura.io/ws/v3/{KEY}"
                    : "wss://mainnet.infura.io/ws/v3/{KEY}"
            }
            return isSepolia
                ? "wss://eth-sepolia.g.alchemy.com/v2/{KEY}"
                : "wss://eth-mainnet.g.alchemy.com/v2/{KEY}"
        case .solana:
            return "wss://mainnet.helius-rpc.com/?api-key={KEY}"
        }
    }

    private func runProbe() async {
        probing = true
        resultText = nil
        // Substitute `{KEY}` against the Keychain-stored API key for
        // whichever provider the user is targeting (Infura / Alchemy /
        // Helius / …). Without this, probing a stored template like
        // `wss://sepolia.infura.io/ws/v3/{KEY}` would hit the server with
        // the literal `{KEY}` in the path and always 401.
        let chain: Chain = (kind == .evm) ? .ethereum : .solana
        let resolved = NetworkConfig.shared.substituteAPIKey(in: url, chain: chain)
        let result = await WebSocketProbe.probe(urlString: resolved, kind: kind)
        probing = false
        switch result {
        case .success(let ms):
            resultOK = true
            resultText = L10n.NodeSettings.wssOK(ms)
        case .failure(let err):
            resultOK = false
            resultText = err.localizedDescription
        }
    }
}

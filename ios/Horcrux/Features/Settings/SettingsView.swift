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
                                VaultTextField(text: $deviceNickname, placeholder: UIDevice.current.name, monospaced: false)
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
            .navigationBarTitleDisplayMode(.large)
            .toolbarColorScheme(.dark, for: .navigationBar)
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
    @State private var showResetConfirm = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    Circle()
                        .fill(healthRollupColor)
                        .frame(width: 10, height: 10)
                    Text(health.summaryText)
                        .font(.subheadline)
                    Spacer()
                    Button {
                        Task { await health.refreshAll(config: config) }
                    } label: {
                        if health.refreshingAll {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Label(L10n.NodeStatus.testAll, systemImage: "arrow.clockwise")
                                .font(.caption.weight(.semibold))
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(HorcruxTheme.accentCyan)
                    .disabled(health.refreshingAll)
                    .accessibilityIdentifier("nodeSettings_testAllButton")
                }
            }

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
                        .tint(isCurrentPreset(preset) ? HorcruxTheme.successGreen : HorcruxTheme.accentPurple)
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
                    URLValidationHint(urlString: config.ethereumRPC)
                    KeySecurityHint(urlString: config.ethereumRPC)
                    ProviderBadge(urlString: config.ethereumRPC)
                    EndpointSwitcher(chain: .ethereum)
                    ChainFieldActions(chain: .ethereum)
                }

                Picker(L10n.NodeSettings.networkPicker, selection: $config.evmChainId) {
                    ForEach(EVMNetwork.allCases) { net in
                        Text(net.displayName).tag(net.rawValue)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.NodeSettings.alchemyKeyLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SecureField(L10n.NodeSettings.pasteKeyPlaceholder, text: $config.alchemyAPIKey)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if !config.alchemyAPIKey.isEmpty,
                       let net = EVMNetwork(rawValue: config.evmChainId),
                       let tmpl = RPCProviderTemplate.alchemy(evm: net) {
                        Button(L10n.NodeSettings.useAlchemyFor(net.displayName)) {
                            config.ethereumRPC = tmpl
                        }
                        .font(.caption)
                    }
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
                    URLValidationHint(urlString: config.bitcoinAPI)
                    ProviderBadge(urlString: config.bitcoinAPI)
                    EndpointSwitcher(chain: .bitcoin)
                    ChainFieldActions(chain: .bitcoin)
                }

                Toggle(L10n.NodeSettings.testnet, isOn: $config.btcTestnet)
                    .accessibilityHint(L10n.NodeSettings.testnetHint)

                NodeStatusRow(chain: .bitcoin)
            }

            Section(L10n.NodeSettings.litecoinSection) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.NodeSettings.restAPIURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("https://litecoinspace.org/api", text: $config.litecoinAPI)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    URLValidationHint(urlString: config.litecoinAPI)
                    ProviderBadge(urlString: config.litecoinAPI)
                    EndpointSwitcher(chain: .litecoin)
                    ChainFieldActions(chain: .litecoin)
                    Text(L10n.NodeSettings.signingUnsupportedNote)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                NodeStatusRow(chain: .litecoin)
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
                    URLValidationHint(urlString: config.solanaRPC)
                    KeySecurityHint(urlString: config.solanaRPC)
                    ProviderBadge(urlString: config.solanaRPC)
                    EndpointSwitcher(chain: .solana)
                    ChainFieldActions(chain: .solana)
                }

                Toggle(L10n.NodeSettings.devnet, isOn: $config.solDevnet)
                    .accessibilityHint(L10n.NodeSettings.devnetHint)

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
                            config.solanaRPC = RPCProviderTemplate.helius(mainnet: !config.solDevnet)
                        }
                        .font(.caption)
                    }
                }

                NodeStatusRow(chain: .solana)
            }

            Section(L10n.NodeSettings.tronSection) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.NodeSettings.restAPIURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("https://api.trongrid.io", text: $config.tronAPI)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    URLValidationHint(urlString: config.tronAPI)
                    ProviderBadge(urlString: config.tronAPI)
                    EndpointSwitcher(chain: .tron)
                    ChainFieldActions(chain: .tron)
                    Text(L10n.NodeSettings.signingUnsupportedNote)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                NodeStatusRow(chain: .tron)
            }

            Section(L10n.NodeSettings.etherscanKeySection) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.NodeSettings.etherscanKeyLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SecureField(L10n.NodeSettings.pasteKeyPlaceholder, text: $config.etherscanAPIKey)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("nodeSettings_etherscanKey")
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
        .vaultForm()
        .task {
            // Auto-probe all endpoints when the page opens so the user sees
            // current status without needing to tap anything. `refreshAll` is
            // a no-op when another refresh is already in flight.
            await health.refreshAll(config: config)
        }
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
        config.solanaRPC == preset.solanaRPC &&
        config.evmChainId == preset.evmChainId &&
        config.btcTestnet == preset.btcTestnet &&
        config.solDevnet == preset.solDevnet
    }

    private var healthRollupColor: Color {
        if health.refreshingAll { return HorcruxTheme.subtleText }
        if health.probedCount == 0 { return HorcruxTheme.subtleText }
        if health.anyFailed { return HorcruxTheme.dangerRed }
        return HorcruxTheme.successGreen
    }
}

/// Inline warning chip for a user-entered RPC URL. Hidden when the URL is
/// valid HTTPS. Shown in amber for insecure http:// and in red for malformed.
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
    let chain: Chain
    @ObservedObject private var config = NetworkConfig.shared

    var body: some View {
        let current = config.rpcURL(for: chain)
        let candidates = RPCFallbacks.endpoints(for: chain, config: config)
            .filter { $0 != current && $0 != config.fieldValue(for: chain) }
        if !candidates.isEmpty {
            Menu {
                ForEach(candidates, id: \.self) { url in
                    Button {
                        config.setFieldValue(url, for: chain)
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
/// IP / address correlation.
struct ProviderBadge: View {
    let urlString: String
    @State private var showPrivacyTip = false

    var body: some View {
        let provider = RPCProvider.identify(urlString)
        if provider != .unknown {
            HStack(spacing: 6) {
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
        }
    }
}

/// Per-chain footer with "Copy URL" and "Reset this chain" actions. Placed
/// below the RPC URL field so users can quickly fall back to defaults for a
/// single chain without running the page-level "reset to defaults".
struct ChainFieldActions: View {
    let chain: Chain
    @ObservedObject private var config = NetworkConfig.shared

    var body: some View {
        HStack(spacing: 12) {
            if let url = config.fieldValue(for: chain), !url.isEmpty {
                Button {
                    UIPasteboard.general.string = url
                } label: {
                    Label(L10n.NodeStatus.copyURL, systemImage: "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(HorcruxTheme.accentCyan)
            }
            Spacer()
            Button {
                config.resetField(for: chain)
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
                    Text(L10n.SettingsResidual.replaceTitle).font(.title2.bold())
                } icon: {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .foregroundStyle(HorcruxTheme.accentCyan)
                }

                Text(L10n.SettingsResidual.replaceIntro)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text(L10n.SettingsResidual.rotateExplanationTitle).font(.subheadline.weight(.semibold))
                    } icon: {
                        Image(systemName: "sparkle").foregroundStyle(HorcruxTheme.accentCyan)
                    }
                    Text(L10n.SettingsResidual.rotateExplanationBody)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(HorcruxTheme.accentCyan.opacity(0.06)))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(HorcruxTheme.accentCyan.opacity(0.25), lineWidth: 1)
                )

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

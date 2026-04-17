import SwiftUI

/// Multi-step flow for creating a new MPC wallet (DKG ceremony).
struct CreateShardFlow: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = CreateShardViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.step {
                case .configure:
                    ConfigureView(viewModel: viewModel)
                case .discover:
                    PeerDiscoveryView(viewModel: viewModel)
                case .dkg:
                    DKGProgressView(viewModel: viewModel)
                case .complete:
                    DKGCompleteView(viewModel: viewModel, dismiss: dismiss)
                case .error:
                    DKGErrorView(viewModel: viewModel)
                }
            }
            .navigationTitle(L10n.CreateShard.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.cancel) { dismiss() }
                        .accessibilityIdentifier("createShard_cancelButton")
                }
            }
            .environmentObject(appState)
            .onAppear {
                viewModel.bind(to: appState)
            }
        }
    }
}

// MARK: - Step 1: Configure

struct ConfigureView: View {
    @ObservedObject var viewModel: CreateShardViewModel

    var body: some View {
        Form {
            Section(L10n.CreateShard.walletName) {
                TextField(L10n.CreateShard.walletNamePlaceholder, text: $viewModel.walletName)
                    .accessibilityLabel(L10n.CreateShard.walletNameAccessibility)
                    .accessibilityHint(L10n.CreateShard.walletNameHint)
                    .accessibilityIdentifier("configure_walletNameField")
            }

            Section(L10n.CreateShard.blockchain) {
                Picker(L10n.CreateShard.chain, selection: $viewModel.selectedCurve) {
                    Text("Ethereum + Bitcoin (secp256k1)")
                        .tag(FfiCurveType.secp256k1)
                    Text("Solana (Ed25519)")
                        .tag(FfiCurveType.ed25519)
                }
                .pickerStyle(.inline)

                Text("同一曲线的链共享同一个密钥分片，自动派生所有地址")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.CreateShard.threshold) {
                Stepper(L10n.CreateShard.totalParties(viewModel.totalParties),
                        value: $viewModel.totalParties, in: 2...10)
                    .accessibilityLabel(L10n.CreateShard.totalParties(viewModel.totalParties))
                    .accessibilityHint(L10n.CreateShard.totalPartiesHint())
                Stepper(L10n.CreateShard.signingThreshold(viewModel.threshold),
                        value: $viewModel.threshold, in: 2...viewModel.totalParties)
                    .accessibilityLabel(L10n.CreateShard.signingThreshold(viewModel.threshold))
                    .accessibilityHint(L10n.CreateShard.signingThresholdHint())

                Text(L10n.CreateShard.requiresDevices(viewModel.threshold, viewModel.totalParties))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if viewModel.totalParties == 3 && viewModel.threshold == 2 {
                    Label {
                        Text("推荐配置：3 台设备生成分片，任意 2 台即可签名。第三台作为备份，设备丢失时仍可恢复钱包。")
                            .font(.caption)
                    } icon: {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                    }
                    .padding(.top, 4)
                } else if viewModel.totalParties == viewModel.threshold {
                    Label {
                        Text("警告：\(viewModel.threshold)-of-\(viewModel.totalParties) 配置没有冗余，任一设备丢失将永久无法动用钱包。建议至少多加一台备份设备。")
                            .font(.caption)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .padding(.top, 4)
                }
            }

            Section(L10n.CreateShard.communication) {
                ForEach(TransportType.allCases) { transport in
                    Toggle(isOn: Binding(
                        get: { viewModel.selectedTransports.contains(transport) },
                        set: { enabled in
                            if enabled {
                                viewModel.selectedTransports.insert(transport)
                            } else {
                                viewModel.selectedTransports.remove(transport)
                            }
                        }
                    )) {
                        Label(transport.rawValue, systemImage: transport.iconName)
                    }
                }

                if viewModel.selectedTransports.contains(.relay) {
                    TextField("Room Code (e.g. my-wallet-123)", text: $viewModel.roomCode)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("configure_roomCodeField")
                }
            }

            Section {
                Button {
                    viewModel.step = .discover
                    viewModel.startDiscovery()
                } label: {
                    Text(L10n.CreateShard.nextFindPeers)
                        .frame(maxWidth: .infinity)
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.walletName.isEmpty || (viewModel.selectedTransports.contains(.relay) && viewModel.roomCode.isEmpty))
                .accessibilityHint(L10n.CreateShard.findPeersHint)
                .accessibilityIdentifier("configure_nextButton")
            }
        }
    }
}

// MARK: - Step 2: Peer Discovery

struct PeerDiscoveryView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var viewModel: CreateShardViewModel
    @State private var timeRemaining = 90
    @State private var timerTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
                .padding()

            Text(L10n.Discovery.lookingForDevices)
                .foregroundStyle(.secondary)

            // Show local peer identity
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .foregroundStyle(HorcruxTheme.accentCyan)
                Text("My ID: \(viewModel.localPeerId)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(HorcruxTheme.accentCyan)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(HorcruxTheme.accentCyan.opacity(0.1), in: Capsule())

            Text(L10n.Discovery.peersFound(viewModel.foundPeers.count, viewModel.totalParties - 1))
                .font(.headline)
                .accessibilityLabel(L10n.Discovery.peersFoundAccessibility(viewModel.foundPeers.count, viewModel.totalParties - 1))

            Text(L10n.Discovery.timeoutIn(timeRemaining))
                .font(.caption)
                .foregroundStyle(timeRemaining < 15 ? Color.red : Color.gray)

            List(viewModel.foundPeers) { peer in
                HStack {
                    Image(systemName: "person.circle.fill")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading) {
                        Text(peer.name)
                            .font(.headline)
                        Text("\(peer.channel) · \(String(peer.id.prefix(8)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            if viewModel.foundPeers.count >= viewModel.totalParties - 1 {
                Button {
                    timerTask?.cancel()
                    viewModel.startDKG()
                } label: {
                    Text(L10n.Discovery.startKeyGeneration)
                        .frame(maxWidth: .infinity)
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
                .accessibilityHint(L10n.Discovery.startKeyGenHint)
                .accessibilityIdentifier("discover_startDKGButton")
            }

            Button(L10n.Common.cancel, role: .cancel) {
            }
            .foregroundStyle(.secondary)
        }
        .padding()
        .onAppear {
            timerTask = Task {
                while timeRemaining > 0 && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    timeRemaining -= 1
                }
                if timeRemaining <= 0 && !Task.isCancelled {
                    viewModel.errorMessage = L10n.DKG.peerTimeout
                    viewModel.step = .error
                }
            }
        }
        .onDisappear {
            timerTask?.cancel()
        }
    }
}

// MARK: - Step 3: DKG Progress

struct DKGProgressView: View {
    @ObservedObject var viewModel: CreateShardViewModel

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            ProgressRing(progress: viewModel.dkgProgress)
                .frame(width: 120, height: 120)
                .accessibilityLabel(L10n.DKG.keyGenProgress)
                .accessibilityValue("\(Int(viewModel.dkgProgress * 100)) percent")

            VStack(spacing: 8) {
                Text(L10n.DKG.generatingKeyShards)
                    .font(.title2.bold())

                Text(viewModel.dkgStatusMessage)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Text(L10n.DKG.roundOf(viewModel.currentRound, viewModel.totalRounds))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityLabel(L10n.DKG.keyGenRound(viewModel.currentRound, viewModel.totalRounds))

            Spacer()

            Text(L10n.DKG.keepDevicesNearby)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(L10n.DKG.cancelCeremony, role: .destructive) {
                viewModel.cancel()
            }
            .font(.caption)
            .padding(.bottom)
        }
        .padding()
    }
}

// MARK: - Step 4: Complete

struct DKGCompleteView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var viewModel: CreateShardViewModel
    let dismiss: DismissAction
    @State private var pin = ""
    @State private var showPinPrompt = false
    @State private var pinError: String?
    @ScaledMetric(relativeTo: .largeTitle) private var successIconSize: CGFloat = 72

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: successIconSize))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(L10n.DKG.walletCreated)
                    .font(.title.bold())

                ForEach(viewModel.generatedAddresses, id: \.chain) { entry in
                    HStack(spacing: 6) {
                        ChainIcon(chain: entry.chain, size: 20)
                        Text(entry.address)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .textSelection(.enabled)
                    .padding(.horizontal)
                }
            }

            VStack(spacing: 4) {
                Text(L10n.DKG.yourShardIs(viewModel.partyIndex))
                    .font(.headline)
                Text(L10n.DKG.thresholdOf(viewModel.threshold, viewModel.totalParties))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                showPinPrompt = true
            } label: {
                Text(L10n.DKG.saveEncryptShard)
                    .frame(maxWidth: .infinity)
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
            .accessibilityHint(L10n.DKG.saveEncryptHint)
            .accessibilityIdentifier("dkgComplete_saveButton")
        }
        .padding()
        .alert(L10n.DKG.enterPinEncrypt, isPresented: $showPinPrompt) {
            SecureField(L10n.Common.pin, text: $pin)
                .keyboardType(.numberPad)
            Button(L10n.DKG.encryptSave) {
                guard appState.verifyPin(pin) else {
                    pinError = L10n.DKG.incorrectPin
                    return
                }
                viewModel.saveWallet(to: appState, pin: pin)
                pin = ""
                dismiss()
            }
            Button(L10n.Common.cancel, role: .cancel) { pin = "" }
        } message: {
            if let pinError {
                Text(pinError)
            } else {
                Text(L10n.DKG.pinNeededEncrypt)
            }
        }
    }
}

// MARK: - Error

struct DKGErrorView: View {
    @ObservedObject var viewModel: CreateShardViewModel
    @ScaledMetric(relativeTo: .largeTitle) private var errorIconSize: CGFloat = 64

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: errorIconSize))
                .foregroundStyle(.red)
                .accessibilityHidden(true)

            Text(L10n.DKG.keyGenFailed)
                .font(.title2.bold())

            Text(viewModel.errorMessage)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(L10n.Common.retry) {
                viewModel.step = .discover
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint(L10n.DKG.retryHint)
            .accessibilityIdentifier("dkgError_retryButton")

            Spacer()
        }
        .padding()
    }
}

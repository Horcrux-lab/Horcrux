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
            .navigationTitle("Create Wallet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
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
            Section("Wallet Name") {
                TextField("My Wallet", text: $viewModel.walletName)
                    .accessibilityLabel("Wallet name")
                    .accessibilityHint("Enter a name for your new wallet")
                    .accessibilityIdentifier("configure_walletNameField")
            }

            Section("Blockchain") {
                Picker("Chain", selection: $viewModel.selectedChain) {
                    ForEach(Chain.allCases) { chain in
                        Label(chain.rawValue, systemImage: chain.iconName)
                            .tag(chain)
                    }
                }
                .pickerStyle(.inline)
            }

            Section("Threshold") {
                Stepper("Total Parties: \(viewModel.totalParties)",
                        value: $viewModel.totalParties, in: 2...10)
                    .accessibilityLabel("Total parties: \(viewModel.totalParties)")
                    .accessibilityHint("Adjust the total number of devices participating")
                Stepper("Signing Threshold: \(viewModel.threshold)",
                        value: $viewModel.threshold, in: 2...viewModel.totalParties)
                    .accessibilityLabel("Signing threshold: \(viewModel.threshold)")
                    .accessibilityHint("Adjust the minimum number of devices needed to sign")

                Text("Requires **\(viewModel.threshold)** of **\(viewModel.totalParties)** devices to sign")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Communication") {
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
            }

            Section {
                Button {
                    viewModel.step = .discover
                    viewModel.startDiscovery()
                } label: {
                    Text("Next: Find Peers")
                        .frame(maxWidth: .infinity)
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.walletName.isEmpty)
                .accessibilityHint("Proceed to discover nearby devices for key generation")
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

            Text("Looking for nearby devices…")
                .foregroundStyle(.secondary)

            Text("\(viewModel.foundPeers.count) / \(viewModel.totalParties - 1) peers found")
                .font(.headline)
                .accessibilityLabel("\(viewModel.foundPeers.count) of \(viewModel.totalParties - 1) peers found")

            Text("Timeout in \(timeRemaining)s")
                .font(.caption)
                .foregroundStyle(timeRemaining < 15 ? .red : .tertiary)

            List(viewModel.foundPeers) { peer in
                HStack {
                    Image(systemName: "person.circle.fill")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading) {
                        Text(peer.name)
                            .font(.headline)
                        Text(peer.channel)
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
                    Text("Start Key Generation")
                        .frame(maxWidth: .infinity)
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
                .accessibilityHint("Begin the distributed key generation ceremony with connected peers")
                .accessibilityIdentifier("discover_startDKGButton")
            }

            Button("Cancel", role: .cancel) {
                timerTask?.cancel()
                viewModel.cancel()
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
                    viewModel.errorMessage = "Peer discovery timed out. Please try again."
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
                .accessibilityLabel("Key generation progress")
                .accessibilityValue("\(Int(viewModel.dkgProgress * 100)) percent")

            VStack(spacing: 8) {
                Text("Generating Key Shards")
                    .font(.title2.bold())

                Text(viewModel.dkgStatusMessage)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Text("Round \(viewModel.currentRound) of \(viewModel.totalRounds)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Key generation round \(viewModel.currentRound) of \(viewModel.totalRounds)")

            Spacer()

            Text("Keep devices nearby until complete")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Cancel Ceremony", role: .destructive) {
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

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("Wallet Created!")
                    .font(.title.bold())

                if let address = viewModel.generatedAddress {
                    Text(address)
                        .font(.system(.caption, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .padding(.horizontal)
                }
            }

            VStack(spacing: 4) {
                Text("Your shard is #\(viewModel.partyIndex)")
                    .font(.headline)
                Text("\(viewModel.threshold) of \(viewModel.totalParties) threshold")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                showPinPrompt = true
            } label: {
                Text("Save & Encrypt Shard")
                    .frame(maxWidth: .infinity)
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
            .accessibilityHint("Enter your PIN to encrypt and save the key shard")
            .accessibilityIdentifier("dkgComplete_saveButton")
        }
        .padding()
        .alert("Enter PIN to encrypt shard", isPresented: $showPinPrompt) {
            SecureField("PIN", text: $pin)
                .keyboardType(.numberPad)
            Button("Encrypt & Save") {
                guard appState.verifyPin(pin) else {
                    pinError = "Incorrect PIN"
                    return
                }
                viewModel.saveWallet(to: appState, pin: pin)
                pin = ""
                dismiss()
            }
            Button("Cancel", role: .cancel) { pin = "" }
        } message: {
            if let pinError {
                Text(pinError)
            } else {
                Text("Your PIN is needed to encrypt the key shard.")
            }
        }
    }
}

// MARK: - Error

struct DKGErrorView: View {
    @ObservedObject var viewModel: CreateShardViewModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.red)
                .accessibilityHidden(true)

            Text("Key Generation Failed")
                .font(.title2.bold())

            Text(viewModel.errorMessage)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Retry") {
                viewModel.step = .discover
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Go back and try key generation again")
            .accessibilityIdentifier("dkgError_retryButton")

            Spacer()
        }
        .padding()
    }
}

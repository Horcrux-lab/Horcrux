import SwiftUI

/// Transaction signing flow — invites co-signers and tracks progress.
struct SigningView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel: SigningViewModel
    @Environment(\.dismiss) private var dismiss

    init(wallet: Wallet) {
        _viewModel = StateObject(wrappedValue: SigningViewModel(wallet: wallet))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.step {
                case .compose:
                    ComposeTransactionView(viewModel: viewModel)
                case .invite:
                    InviteSignersView(viewModel: viewModel)
                case .signing:
                    SigningProgressView(viewModel: viewModel)
                case .complete:
                    SigningCompleteView(viewModel: viewModel, dismiss: dismiss)
                case .error:
                    SigningErrorView(viewModel: viewModel)
                }
            }
            .navigationTitle("Send \(viewModel.wallet.chain.symbol)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                viewModel.bind(to: appState)
            }
        }
    }
}

// MARK: - Step 1: Compose Transaction

struct ComposeTransactionView: View {
    @ObservedObject var viewModel: SigningViewModel
    @State private var showQRScanner = false

    private var addressError: String? {
        guard !viewModel.recipientAddress.isEmpty else { return nil }
        return AddressValidator.errorMessage(for: viewModel.recipientAddress, chain: viewModel.wallet.chain)
    }

    var body: some View {
        Form {
            Section("Recipient") {
                HStack {
                    TextField("Address", text: $viewModel.recipientAddress)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Button {
                        showQRScanner = true
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.title2)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                }

                if let addressError {
                    Text(addressError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Amount") {
                HStack {
                    TextField("0.0", text: $viewModel.amount)
                        .keyboardType(.decimalPad)
                    Text(viewModel.wallet.chain.symbol)
                        .foregroundStyle(.secondary)
                }
            }

            if viewModel.wallet.chain == .ethereum {
                Section("Gas") {
                    if viewModel.isEstimatingGas {
                        HStack {
                            Text("Estimating…")
                            Spacer()
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                    } else {
                        LabeledContent("Gas Limit", value: viewModel.estimatedGas)
                        LabeledContent("Est. Fee", value: viewModel.estimatedFee)
                    }
                }
            } else if viewModel.wallet.chain == .bitcoin || viewModel.wallet.chain == .solana {
                Section("Fee") {
                    if viewModel.isEstimatingGas {
                        HStack {
                            Text("Estimating…")
                            Spacer()
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                    } else {
                        LabeledContent("Est. Fee", value: viewModel.estimatedFee)
                    }
                }
            }

            Section {
                Button {
                    viewModel.estimateGas()
                    viewModel.step = .invite
                } label: {
                    Text("Next: Invite Co-Signers")
                        .frame(maxWidth: .infinity)
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.recipientAddress.isEmpty || viewModel.amount.isEmpty || addressError != nil)
            }
        }
        .sheet(isPresented: $showQRScanner) {
            QRScannerSheet { scannedAddress in
                viewModel.recipientAddress = scannedAddress
            }
        }
    }
}

// MARK: - Step 2: Invite Co-Signers

struct InviteSignersView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var viewModel: SigningViewModel
    @State private var showPinPrompt = false
    @State private var pin = ""
    @State private var pinError: String?

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("Invite Co-Signers")
                    .font(.title2.bold())

                Text("Need \(viewModel.wallet.threshold - 1) more signer(s)")
                    .foregroundStyle(.secondary)
            }

            // Transaction summary
            VStack(spacing: 4) {
                Text("\(viewModel.amount) \(viewModel.wallet.chain.symbol)")
                    .font(.title.bold())
                Text("→ \(viewModel.shortRecipient)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospaced()
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

            ProgressView()
                .padding()

            Text("Waiting for co-signers to join…")
                .foregroundStyle(.secondary)

            List(viewModel.joinedSigners) { peer in
                HStack {
                    Image(systemName: "person.circle.fill")
                        .foregroundStyle(.green)
                    Text(peer.name)
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            if viewModel.joinedSigners.count >= viewModel.wallet.threshold - 1 {
                Button {
                    showPinPrompt = true
                } label: {
                    Text("Sign Transaction")
                        .frame(maxWidth: .infinity)
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
            }
        }
        .padding()
        .alert("Enter PIN to decrypt shard", isPresented: $showPinPrompt) {
            SecureField("PIN", text: $pin)
                .keyboardType(.numberPad)
            Button("Unlock & Sign") {
                guard appState.verifyPin(pin) else {
                    pinError = "Incorrect PIN"
                    pin = ""
                    showPinPrompt = true
                    return
                }
                viewModel.setPin(pin)
                pin = ""
                viewModel.startSigning()
            }
            Button("Cancel", role: .cancel) { pin = "" }
        } message: {
            if let pinError {
                Text(pinError)
            } else {
                Text("Your PIN is needed to decrypt the key shard for signing.")
            }
        }
    }
}

// MARK: - Step 3: Signing Progress

struct SigningProgressView: View {
    @ObservedObject var viewModel: SigningViewModel

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            ProgressRing(progress: viewModel.signingProgress)
                .frame(width: 120, height: 120)

            VStack(spacing: 8) {
                Text("Signing Transaction")
                    .font(.title2.bold())

                Text(viewModel.signingStatusMessage)
                    .foregroundStyle(.secondary)
            }

            Text("Round \(viewModel.currentRound) of \(viewModel.totalRounds)")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .padding()
    }
}

// MARK: - Step 4: Complete

struct SigningCompleteView: View {
    @ObservedObject var viewModel: SigningViewModel
    let dismiss: DismissAction

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)

            VStack(spacing: 8) {
                Text("Transaction Signed!")
                    .font(.title.bold())

                Text("\(viewModel.amount) \(viewModel.wallet.chain.symbol)")
                    .font(.title2)

                if let txHash = viewModel.txHash {
                    Text(txHash)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            // Broadcast section
            VStack(spacing: 12) {
                if viewModel.isBroadcasting {
                    ProgressView()
                    Text(viewModel.broadcastStatus ?? "Broadcasting…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let status = viewModel.broadcastStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(status.contains("OK") ? .green : .red)
                        .multilineTextAlignment(.center)
                } else {
                    Button {
                        viewModel.broadcastTransaction()
                    } label: {
                        Label("Broadcast to Network", systemImage: "antenna.radiowaves.left.and.right")
                            .frame(maxWidth: .infinity)
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .padding(.horizontal)
                }
            }

            Spacer()

            Button { dismiss() } label: {
                Text("Done")
                    .frame(maxWidth: .infinity)
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
        }
        .padding()
    }
}

// MARK: - Error

struct SigningErrorView: View {
    @ObservedObject var viewModel: SigningViewModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.red)
            Text("Signing Failed")
                .font(.title2.bold())
            Text(viewModel.errorMessage)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") { viewModel.step = .invite }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding()
    }
}

import SwiftUI

/// Transaction signing flow — invites co-signers and tracks progress.
struct SigningView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel: SigningViewModel
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .largeTitle) private var largeIconSize: CGFloat = 72
    @ScaledMetric(relativeTo: .largeTitle) private var mediumIconSize: CGFloat = 64

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
            .navigationTitle(L10n.Signing.sendSymbol(viewModel.wallet.chain.symbol))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.cancel) { dismiss() }
                        .accessibilityIdentifier("signing_cancelButton")
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
            Section(L10n.Signing.recipient) {
                HStack {
                    TextField(L10n.Signing.addressPlaceholder, text: $viewModel.recipientAddress)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityLabel(L10n.Signing.recipientAddress)
                        .accessibilityHint(L10n.Signing.recipientHint)
                        .accessibilityIdentifier("compose_recipientField")

                    Button {
                        showQRScanner = true
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.title2)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.Signing.scanQR)
                    .accessibilityHint(L10n.Signing.scanQRHint)
                    .accessibilityIdentifier("compose_scanQRButton")
                }

                if let addressError {
                    Text(addressError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section(L10n.Signing.amount) {
                HStack {
                    TextField("0.0", text: $viewModel.amount)
                        .keyboardType(.decimalPad)
                        .accessibilityLabel(L10n.Signing.amount)
                        .accessibilityHint(L10n.Signing.amountHint)
                        .accessibilityIdentifier("compose_amountField")
                    Text(viewModel.wallet.chain.symbol)
                        .foregroundStyle(.secondary)
                }
            }

            if viewModel.wallet.chain == .ethereum {
                Section(L10n.Signing.gas) {
                    if viewModel.isEstimatingGas {
                        HStack {
                            Text(L10n.Signing.estimating)
                            Spacer()
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                    } else {
                        LabeledContent(L10n.Signing.gasLimit, value: viewModel.estimatedGas)
                        LabeledContent(L10n.Signing.estFee, value: viewModel.estimatedFee)
                    }
                }
            } else if viewModel.wallet.chain == .bitcoin || viewModel.wallet.chain == .solana {
                Section(L10n.Signing.fee) {
                    if viewModel.isEstimatingGas {
                        HStack {
                            Text(L10n.Signing.estimating)
                            Spacer()
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                    } else {
                        LabeledContent(L10n.Signing.estFee, value: viewModel.estimatedFee)
                    }
                }
            }

            Section {
                Button {
                    viewModel.estimateGas()
                    viewModel.step = .invite
                } label: {
                    Text(L10n.Signing.nextInviteCoSigners)
                        .frame(maxWidth: .infinity)
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.recipientAddress.isEmpty || viewModel.amount.isEmpty || addressError != nil)
                .accessibilityHint(L10n.Signing.inviteHint)
                .accessibilityIdentifier("compose_nextButton")
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
                Text(L10n.Signing.inviteCoSigners)
                    .font(.title2.bold())

                Text(L10n.Signing.needMoreSigners(Int(viewModel.wallet.threshold) - 1))
                    .foregroundStyle(.secondary)
            }

            // Transaction summary
            VStack(spacing: 4) {
                Text(CurrencyFormatter.crypto(Double(viewModel.amount) ?? 0, symbol: viewModel.wallet.chain.symbol))
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

            Text(L10n.Signing.waitingForCoSigners)
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
                    Text(L10n.Signing.signTransaction)
                        .frame(maxWidth: .infinity)
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
                .accessibilityHint(L10n.Signing.signHint)
                .accessibilityIdentifier("invite_signButton")
            }
        }
        .padding()
        .alert(L10n.Signing.enterPinDecrypt, isPresented: $showPinPrompt) {
            SecureField(L10n.Common.pin, text: $pin)
                .keyboardType(.numberPad)
            Button(L10n.Signing.unlockSign) {
                guard appState.verifyPin(pin) else {
                    pinError = L10n.Signing.incorrectPin
                    pin = ""
                    showPinPrompt = true
                    return
                }
                viewModel.setPin(pin)
                pin = ""
                viewModel.startSigning()
            }
            Button(L10n.Common.cancel, role: .cancel) { pin = "" }
        } message: {
            if let pinError {
                Text(pinError)
            } else {
                Text(L10n.Signing.pinNeededDecrypt)
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
                .accessibilityLabel(L10n.Signing.signingProgress)
                .accessibilityValue("\(Int(viewModel.signingProgress * 100)) percent")

            VStack(spacing: 8) {
                Text(L10n.Signing.signingTransaction)
                    .font(.title2.bold())

                Text(viewModel.signingStatusMessage)
                    .foregroundStyle(.secondary)
            }

            Text(L10n.Signing.roundOf(viewModel.currentRound, viewModel.totalRounds))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityLabel(L10n.Signing.signingRound(viewModel.currentRound, viewModel.totalRounds))

            Spacer()

            Button(L10n.Signing.cancelSigning, role: .destructive) {
                viewModel.cancelSigning()
            }
            .font(.caption)
            .padding(.bottom)
        }
        .padding()
    }
}

// MARK: - Step 4: Complete

struct SigningCompleteView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var viewModel: SigningViewModel
    @ScaledMetric(relativeTo: .largeTitle) private var largeIconSize: CGFloat = 72
    let dismiss: DismissAction

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: largeIconSize))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(L10n.Signing.transactionSigned)
                    .font(.title.bold())

                Text(CurrencyFormatter.crypto(Double(viewModel.amount) ?? 0, symbol: viewModel.wallet.chain.symbol))
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
                    Text(viewModel.broadcastStatus ?? L10n.Signing.broadcasting)
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
                        Label(L10n.Signing.broadcastToNetwork, systemImage: "antenna.radiowaves.left.and.right")
                            .frame(maxWidth: .infinity)
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .padding(.horizontal)
                    .accessibilityHint(L10n.Signing.broadcastHint)
                    .accessibilityIdentifier("complete_broadcastButton")

                    Button {
                        viewModel.saveForLaterBroadcast(queue: appState.pendingBroadcastQueue)
                        dismiss()
                    } label: {
                        Label(L10n.Signing.saveForLater, systemImage: "clock.arrow.circlepath")
                            .frame(maxWidth: .infinity)
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    .padding(.horizontal)
                    .accessibilityHint(L10n.Signing.saveForLaterHint)
                    .accessibilityIdentifier("complete_saveForLaterButton")
                }
            }

            Spacer()

            Button { dismiss() } label: {
                Text(L10n.Common.done)
                    .frame(maxWidth: .infinity)
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
            .accessibilityIdentifier("complete_doneButton")
        }
        .padding()
    }
}

// MARK: - Error

struct SigningErrorView: View {
    @ObservedObject var viewModel: SigningViewModel
    @ScaledMetric(relativeTo: .largeTitle) private var errorIconSize: CGFloat = 64

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: errorIconSize))
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text(L10n.Signing.signingFailed)
                .font(.title2.bold())
            Text(viewModel.errorMessage)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(L10n.Common.retry) { viewModel.step = .invite }
                .buttonStyle(.borderedProminent)
                .accessibilityHint(L10n.Signing.retryHint)
                .accessibilityIdentifier("signingError_retryButton")
            Spacer()
        }
        .padding()
    }
}

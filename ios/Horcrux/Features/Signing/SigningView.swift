import SwiftUI
import CoreImage.CIFilterBuiltins

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

    /// RBF variant: pre-fills recipient + amount from a pending BTC/LTC tx and
    /// bumps the fee tier to fast. The wallet will naturally re-select the
    /// same still-unconfirmed UTXOs, producing a Bitcoin-policy-compliant
    /// RBF replacement.
    init(wallet: Wallet, rbfFrom record: TransactionRecord) {
        let vm = SigningViewModel(wallet: wallet)
        vm.recipientAddress = record.toAddress
        // `amount` on the record is display-formatted like "0.001 BTC".
        let numeric = record.amount.split(separator: " ").first.map(String.init) ?? record.amount
        vm.amount = numeric
        vm.feeTier = .fast
        vm.rbfReplacing = record.txHash
        _viewModel = StateObject(wrappedValue: vm)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                HorcruxTheme.backgroundGradient.ignoresSafeArea()

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
            }
            .navigationTitle(L10n.Signing.sendSymbol(viewModel.wallet.chain.symbol))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
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
        .preferredColorScheme(.dark)
    }
}

// MARK: - Step 1: Compose Transaction

struct ComposeTransactionView: View {
    @ObservedObject var viewModel: SigningViewModel
    @State private var showQRScanner = false
    @State private var showAddressBook = false
    @State private var ensStatus: String?
    @StateObject private var priceService = PriceService.shared

    /// A composite key of every field that should trigger a re-estimate.
    /// When any part changes, `.task(id:)` cancels the in-flight debounce
    /// and starts a fresh one — SwiftUI handles the cancellation and main
    /// actor scheduling for us.
    private var estimateKey: String {
        [
            viewModel.recipientAddress,
            viewModel.amount,
            viewModel.feeTier.rawValue,
            viewModel.selectedToken?.id ?? "__native__"
        ].joined(separator: "|")
    }

    private var addressError: String? {
        guard !viewModel.recipientAddress.isEmpty else { return nil }
        // Skip validation while ENS resolution is pending/used
        if viewModel.recipientAddress.hasSuffix(".eth") { return nil }
        return AddressValidator.errorMessage(for: viewModel.recipientAddress, chain: viewModel.wallet.chain)
    }

    /// Live USD equivalent of the currently-typed amount. Returns nil when the
    /// amount is empty/zero/invalid or when there is no cached quote for the
    /// transfer symbol (tokens without a CoinGecko listing fall through to nil).
    private var liveFiatString: String? {
        let trimmed = viewModel.amount.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let value = Double(trimmed),
              value > 0 else { return nil }
        return priceService.fiatString(amount: value, symbol: viewModel.transferSymbol)
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
                        .onChange(of: viewModel.recipientAddress) { _, newVal in
                            if newVal.hasSuffix(".eth"), viewModel.wallet.chain == .ethereum {
                                resolveENS(newVal)
                            } else {
                                ensStatus = nil
                            }
                        }

                    Button {
                        showAddressBook = true
                    } label: {
                        Image(systemName: "person.crop.circle")
                            .font(.title2)
                            .foregroundStyle(HorcruxTheme.accentBlue)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.Signing.pickFromAddressBook)
                    .accessibilityIdentifier(viewModel.wallet.chain != .bitcoin ? "compose_addressBookButton" : "")

                    Button {
                        showQRScanner = true
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.title2)
                            .foregroundStyle(HorcruxTheme.accentBlue)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.Signing.scanQR)
                    .accessibilityHint(L10n.Signing.scanQRHint)
                    .accessibilityIdentifier("compose_scanQRButton")
                }

                if let ensStatus {
                    HStack(spacing: 6) {
                        Image(systemName: "at.circle")
                            .foregroundStyle(HorcruxTheme.accentBlue)
                        Text(ensStatus)
                            .font(.caption)
                    }
                }

                if let primaryName = viewModel.resolvedRecipientENS {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(HorcruxTheme.successGreen)
                        Text("ENS: \(primaryName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("compose_resolvedENS")
                }

                if let addressError {
                    Text(addressError)
                        .font(.caption)
                        .foregroundStyle(HorcruxTheme.dangerRed)
                }
            }
            .darkListRow()

            Section(L10n.Signing.amount) {
                if !viewModel.availableTokens.isEmpty {
                    Picker(L10n.Signing.asset, selection: Binding(
                        get: { viewModel.selectedToken?.id ?? "__native__" },
                        set: { newId in
                            if newId == "__native__" {
                                viewModel.selectedToken = nil
                            } else {
                                viewModel.selectedToken = viewModel.availableTokens.first { $0.id == newId }
                            }
                        }
                    )) {
                        Text(viewModel.wallet.chain.symbol + L10n.SigningExtra.nativeTokenSuffix).tag("__native__")
                        ForEach(viewModel.availableTokens, id: \.id) { token in
                            Text("\(token.symbol) — \(token.name)").tag(token.id)
                        }
                    }
                    .pickerStyle(.menu)
                }

                HStack {
                    TextField("0.0", text: $viewModel.amount)
                        .keyboardType(.decimalPad)
                        .accessibilityLabel(L10n.Signing.amount)
                        .accessibilityHint(L10n.Signing.amountHint)
                        .accessibilityIdentifier("compose_amountField")
                    if viewModel.canFillMax {
                        Button(L10n.Common.max) {
                            viewModel.fillMax()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("compose_maxButton")
                    }
                    Text(viewModel.transferSymbol)
                        .foregroundStyle(.secondary)
                }

                if let fiat = liveFiatString {
                    Text("≈ \(fiat)")
                        .font(.caption)
                        .foregroundStyle(HorcruxTheme.subtleText)
                        .transition(.opacity)
                        .accessibilityIdentifier("compose_amountFiat")
                }
            }
            .darkListRow()

            if viewModel.wallet.chain.isEVM {
                Section(L10n.Signing.gas) {
                    Picker(L10n.Signing.feePriority, selection: $viewModel.feeTier) {
                        ForEach(SigningViewModel.FeeTier.allCases) { tier in
                            Text(tier.label).tag(tier)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("compose_feeTierPicker")

                    if viewModel.feeTier == .custom {
                        HStack {
                            Text(L10n.SigningExtra.gasPriceGwei)
                            Spacer()
                            TextField(L10n.Signing.customGasPlaceholder, text: $viewModel.customGasPriceGwei)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(minWidth: 80)
                                .accessibilityIdentifier("compose_customGasGwei")
                        }
                    }

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
                .darkListRow()
            } else if viewModel.wallet.chain == .bitcoin || viewModel.wallet.chain == .litecoin || viewModel.wallet.chain == .solana {
                Section(L10n.Signing.fee) {
                    if viewModel.wallet.chain != .solana {
                        // Solana has no user-tunable feerate for native transfers.
                        Picker(L10n.Signing.feePriority, selection: $viewModel.feeTier) {
                            ForEach(SigningViewModel.FeeTier.allCases) { tier in
                                Text(tier.label).tag(tier)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("compose_feeTierPicker")

                        if viewModel.feeTier == .custom {
                            HStack {
                                Text(L10n.Signing.customFeeRateLabel)
                                Spacer()
                                TextField(L10n.Signing.customFeeRatePlaceholder, text: $viewModel.customGasPriceGwei)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(minWidth: 80)
                                    .accessibilityIdentifier("compose_customSatVB")
                            }
                        }
                    }
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
                    if let blocker = viewModel.composeBlocker {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(HorcruxTheme.warningAmber)
                            Text(blocker)
                                .font(.caption)
                                .foregroundStyle(HorcruxTheme.warningAmber)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .darkListRow()
            }

            Section {
                Button {
                    viewModel.estimateGas()
                    viewModel.prepareInvite()
                } label: {
                    Text(L10n.Signing.nextInviteCoSigners)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GradientButtonStyle(
                    isEnabled: !(viewModel.recipientAddress.isEmpty || viewModel.amount.isEmpty || addressError != nil),
                    tint: viewModel.wallet.chain.color
                ))
                .disabled(viewModel.recipientAddress.isEmpty || viewModel.amount.isEmpty || addressError != nil)
                .accessibilityHint(L10n.Signing.inviteHint)
                .accessibilityIdentifier("compose_nextButton")
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
        .darkFormStyle()
        .sheet(isPresented: $showQRScanner) {
            QRScannerSheet { scannedAddress in
                viewModel.recipientAddress = scannedAddress
            }
        }
        .sheet(isPresented: $showAddressBook) {
            AddressBookPicker(chain: viewModel.wallet.chain) { entry in
                viewModel.recipientAddress = entry.address
            }
        }
        .onAppear {
            priceService.refreshIfNeeded()
        }
        // SwiftUI-managed debounced estimate: whenever any input changes,
        // the prior task is cancelled and a fresh one started after 500ms.
        // `estimateGas()` itself guards on empty recipient/amount, so it's
        // safe to fire even when fields aren't fully populated.
        .task(id: estimateKey) {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            viewModel.estimateGas()
        }
    }

    /// Minimal ENS resolution via public RPC. Queries the ENS registry
    /// resolver for the name and shows the result in an inline hint.
    private func resolveENS(_ name: String) {
        ensStatus = L10n.Signing.ensResolving(name)
        Task {
            let resolved = await ENSResolver.resolve(name)
            await MainActor.run {
                if let addr = resolved {
                    ensStatus = "→ \(addr.prefix(10))…\(addr.suffix(6))"
                    viewModel.recipientAddress = addr
                } else {
                    ensStatus = L10n.SigningExtra.ensResolveFailed
                }
            }
        }
    }
}

// MARK: - Step 2: Invite Co-Signers

struct InviteSignersView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var viewModel: SigningViewModel
    @State private var showPinSheet = false
    /// Seconds we've been sitting on the invite screen waiting for
    /// cosigners. Drives the "still waiting?" troubleshooting card
    /// that appears after `waitHintThreshold` seconds.
    @State private var waitElapsed: TimeInterval = 0
    private let waitHintThreshold: TimeInterval = 30
    /// Peer the user tapped the "x" button next to; bound to a confirm
    /// dialog so a mis-tap doesn't silently evict a legitimate cosigner.
    @State private var peerPendingKick: Peer?

    /// How many peers (excluding self) are needed to reach threshold.
    private var peersNeeded: Int { Int(viewModel.wallet.threshold) - 1 }
    private var peersJoined: Int { viewModel.joinedSigners.count }
    private var thresholdMet: Bool { peersJoined >= peersNeeded }
    private var showTroubleshoot: Bool {
        !thresholdMet && waitElapsed >= waitHintThreshold
    }

    /// Format a seconds-remaining integer as `M:SS` for the countdown.
    private func formatCountdown(_ secs: Int) -> String {
        let m = secs / 60
        let s = secs % 60
        return String(format: "%d:%02d", m, s)
    }

    var body: some View {
        let chainTint = viewModel.wallet.chain.color
        ZStack {
            HorcruxTheme.backgroundGradient.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    // Header + progress
                    VStack(spacing: 10) {
                        Text(L10n.Signing.inviteCoSigners)
                            .font(.title2.bold())
                            .foregroundStyle(.white)

                        // "N of M signers ready" — counts self as always ready.
                        Text(L10n.Signing.signersReady(peersJoined + 1, Int(viewModel.wallet.threshold)))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(HorcruxTheme.subtleText)

                        // Visual dot row: self + peer slots
                        HStack(spacing: 10) {
                            SignerSlot(filled: true, isSelf: true, tint: chainTint)
                            ForEach(0..<peersNeeded, id: \.self) { idx in
                                SignerSlot(filled: idx < peersJoined, isSelf: false, tint: chainTint)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .padding(.top, 16)

                    TransactionPreviewCard(viewModel: viewModel)

                    // Transport selector — lets the user choose how
                    // cosigners are allowed to attach. At least one
                    // channel must be selected; if the user deselects
                    // both we defensively snap relay back on.
                    if peersNeeded > 0 {
                        SigningTransportPicker(viewModel: viewModel)
                    }

                    // Invite card: shows the 3-word room code + QR + copy
                    // so co-signers can join the same relay room. Solo
                    // wallets (threshold == 1) skip this entirely.
                    if peersNeeded > 0
                        && !viewModel.roomCode.isEmpty
                        && viewModel.selectedTransports.contains(.relay) {
                        VStack(alignment: .leading, spacing: 10) {
                            VaultSectionHeader(L10n.Signing.inviteCoSigners, icon: "qrcode")
                            SigningRoomCodeCard(code: viewModel.roomCode)
                                .opacity(viewModel.roomCodeExpired ? 0.4 : 1)
                            if viewModel.roomCodeExpired {
                                HStack(spacing: 8) {
                                    Image(systemName: "clock.badge.exclamationmark")
                                        .foregroundStyle(HorcruxTheme.warningAmber)
                                    Text(L10n.Signing.roomCodeExpired)
                                        .font(.caption)
                                        .foregroundStyle(HorcruxTheme.warningAmber)
                                    Spacer()
                                    Button(L10n.Signing.roomCodeRegenerate) {
                                        viewModel.regenerateRoomCode()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                }
                            } else if let remaining = viewModel.roomCodeSecondsRemaining {
                                HStack(spacing: 6) {
                                    Image(systemName: "timer")
                                        .font(.caption2)
                                        .foregroundStyle(HorcruxTheme.subtleText)
                                    Text(L10n.Signing.roomCodeValidFor(
                                        formatCountdown(remaining)))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(HorcruxTheme.subtleText)
                                    Spacer()
                                    if remaining <= 60 {
                                        Button(L10n.Signing.roomCodeRegenerate) {
                                            viewModel.regenerateRoomCode()
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.mini)
                                    }
                                }
                            }
                            if let err = viewModel.roomJoinError {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(HorcruxTheme.warningAmber)
                                    Text(err)
                                        .font(.caption)
                                        .foregroundStyle(HorcruxTheme.subtleText)
                                    Spacer()
                                    Button(L10n.Common.retry) {
                                        viewModel.retryJoinRoom()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            } else if !viewModel.roomJoined {
                                HStack(spacing: 8) {
                                    ProgressView().scaleEffect(0.7)
                                    Text(L10n.Signing.joiningRoom)
                                        .font(.caption)
                                        .foregroundStyle(HorcruxTheme.subtleText)
                                }
                            } else {
                                Text(L10n.Signing.shareRoomCodeHint)
                                    .font(.caption)
                                    .foregroundStyle(HorcruxTheme.subtleText)
                            }
                        }
                    }

                    // "Last signed with" hint. Shows once no peers have
                    // joined yet so the initiator has a mental confirmation
                    // target ("yes, waiting for Alice's iPhone"). Disappears
                    // as soon as someone actually joins — at that point the
                    // cosigners list + fingerprint do the verification job.
                    if viewModel.joinedSigners.isEmpty,
                       let recent = RecentCoSignersStore.shared.mostRecent(for: viewModel.wallet.id) {
                        HStack(spacing: 8) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(HorcruxTheme.accentCyan)
                            Text(L10n.Signing.lastSignedWith(recent.name))
                                .font(.caption)
                                .foregroundStyle(HorcruxTheme.subtleText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.white.opacity(0.04))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(HorcruxTheme.hairline, lineWidth: 1))
                        )
                        // Long-press to forget — useful if the displayed
                        // "last peer" is stale (device lost, replaced) so
                        // the hint doesn't mislead the initiator into
                        // thinking that peer might still dial in.
                        .contextMenu {
                            Button(role: .destructive) {
                                RecentCoSignersStore.shared.forget(
                                    peerId: recent.id,
                                    walletId: viewModel.wallet.id
                                )
                            } label: {
                                Label(L10n.Signing.forgetPeer, systemImage: "trash")
                            }
                        }
                    }

                    // Joined peers list
                    if !viewModel.joinedSigners.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            VaultSectionHeader(L10n.Signing.coSigners, icon: "person.2.fill")
                            // Wallet-identity fingerprint. The cosigner's
                            // review screen shows the same 8-char hex;
                            // reading these two aloud to each other
                            // confirms they're signing against the
                            // *same* wallet and not an attacker-supplied
                            // lookalike. Only shown once at least one
                            // cosigner is connected — before then there
                            // is no one to verify with.
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.shield")
                                    .foregroundStyle(HorcruxTheme.successGreen)
                                Text(L10n.Signing.walletFingerprintLabel)
                                    .font(.caption)
                                    .foregroundStyle(HorcruxTheme.subtleText)
                                Text(viewModel.walletFingerprint)
                                    .font(.system(.caption, design: .monospaced).bold())
                                    .foregroundStyle(.white)
                                Spacer()
                            }
                            .padding(.horizontal, 4)
                            ForEach(viewModel.joinedSigners) { peer in
                                let parts = DeviceIdentity.split(peer.name)
                                HStack(spacing: 10) {
                                    Image(systemName: "person.circle.fill")
                                        .foregroundStyle(HorcruxTheme.successGreen)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(parts.label)
                                            .foregroundStyle(.white)
                                        if let sid = parts.shortId {
                                            Text("ID: \(sid)")
                                                .font(.caption2)
                                                .foregroundStyle(HorcruxTheme.subtleText)
                                                .monospaced()
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(HorcruxTheme.successGreen)
                                    Button {
                                        peerPendingKick = peer
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(HorcruxTheme.subtleText)
                                            .imageScale(.medium)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(L10n.Signing.removePeer)
                                }
                                .tintedGlassCard(color: chainTint)
                            }
                        }
                    }

                    // Waiting indicator until threshold met. After
                    // `waitHintThreshold` seconds we expand into a
                    // troubleshooting card so the user sees actionable
                    // next steps instead of an indefinite spinner.
                    if !thresholdMet {
                        if showTroubleshoot {
                            WaitingTroubleshootCard(
                                hasRelay: viewModel.selectedTransports.contains(.relay),
                                hasLAN: viewModel.selectedTransports.contains(.wifiLAN),
                                chainTint: chainTint
                            )
                        } else {
                            HStack(spacing: 10) {
                                ProgressView()
                                    .tint(chainTint)
                                Text(L10n.Signing.waitingForCoSigners)
                                    .font(.subheadline)
                                    .foregroundStyle(HorcruxTheme.subtleText)
                            }
                            .padding(.vertical, 8)
                        }
                    }

                    if thresholdMet {
                        Button {
                            // Fast path: SWK is cached from the unlock session.
                            if let swk = appState.cachedShardKey() {
                                viewModel.setShardKey(swk)
                                viewModel.startSigning()
                            } else {
                                showPinSheet = true
                            }
                        } label: {
                            Text(L10n.Signing.signTransaction)
                        }
                        .buttonStyle(GradientButtonStyle(tint: chainTint))
                        .accessibilityHint(L10n.Signing.signHint)
                        .accessibilityIdentifier("invite_signButton")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .sheet(isPresented: $showPinSheet) {
            PinUnlockSheet(
                title: L10n.Signing.unlockToSignTitle,
                subtitle: L10n.Signing.unlockToSignSubtitle
            ) { pin in
                guard appState.verifyPin(pin) else {
                    return L10n.Signing.incorrectPin
                }
                guard let swk = appState.cachedShardKey() else {
                    return L10n.Signing.incorrectPin
                }
                viewModel.setShardKey(swk)
                // Kick off signing after the sheet dismisses so the animation
                // doesn't fight the state transition.
                DispatchQueue.main.async { viewModel.startSigning() }
                return nil
            }
            .presentationDetents([.medium, .large])
        }
        // Drive the "still waiting?" timer + room-code expiry tick.
        // Resets as soon as anyone joins; only runs while in the invite
        // step and under threshold.
        .onReceive(
            Timer.publish(every: 1, on: .main, in: .common).autoconnect()
        ) { _ in
            viewModel.tickRoomCodeExpiry()
            if thresholdMet {
                waitElapsed = 0
            } else {
                waitElapsed += 1
            }
        }
        .onChange(of: viewModel.joinedSigners.count) { _, _ in
            waitElapsed = 0
        }
        .confirmationDialog(
            L10n.Signing.removePeerConfirmTitle,
            isPresented: Binding(
                get: { peerPendingKick != nil },
                set: { if !$0 { peerPendingKick = nil } }
            ),
            titleVisibility: .visible,
            presenting: peerPendingKick
        ) { peer in
            Button(L10n.Signing.removePeer, role: .destructive) {
                viewModel.kickPeer(peer)
                peerPendingKick = nil
            }
            Button(L10n.Common.cancel, role: .cancel) {
                peerPendingKick = nil
            }
        } message: { peer in
            Text(L10n.Signing.removePeerConfirmBody(peer.name))
        }
    }
}

/// Expanded guidance shown after ~30s of waiting so the user has a
/// concrete next step instead of an indefinite spinner. Covers the
/// three most common failure modes: typo in the room code, opposite
/// cosigner not on the same Wi-Fi (LAN-only mode), and relay-toggle
/// asymmetry between the two sides.
private struct WaitingTroubleshootCard: View {
    let hasRelay: Bool
    let hasLAN: Bool
    let chainTint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "clock.badge.questionmark")
                    .foregroundStyle(HorcruxTheme.warningAmber)
                Text(L10n.Signing.waitingTroubleshootTitle)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
            }
            TroubleshootRow(text: L10n.Signing.waitingCheckCode)
            if hasRelay {
                TroubleshootRow(text: L10n.Signing.waitingCheckRelay)
            }
            if hasLAN {
                TroubleshootRow(text: L10n.Signing.waitingCheckLAN)
            }
            if !hasRelay {
                TroubleshootRow(text: L10n.Signing.waitingEnableRelayHint)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(HorcruxTheme.warningAmber.opacity(0.35),
                                lineWidth: 1)
                )
        )
    }
}

private struct TroubleshootRow: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundStyle(HorcruxTheme.warningAmber)
            Text(text)
                .font(.caption)
                .foregroundStyle(HorcruxTheme.subtleText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Circular signer slot used in the threshold progress row.
private struct SignerSlot: View {
    let filled: Bool
    let isSelf: Bool
    var tint: Color = HorcruxTheme.accentPurple

    var body: some View {
        ZStack {
            Circle()
                .fill(filled ? tint.opacity(0.2) : Color.white.opacity(0.05))
                .overlay(
                    Circle().stroke(
                        filled ? tint : Color.white.opacity(0.15),
                        lineWidth: 1.5
                    )
                )
                .frame(width: 36, height: 36)
            Image(systemName: isSelf ? "iphone" : (filled ? "checkmark" : "person"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(filled ? tint : HorcruxTheme.subtleText)
        }
    }
}

// MARK: - Step 3: Signing Progress

struct SigningProgressView: View {
    @ObservedObject var viewModel: SigningViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var completionPulse = false

    /// Shard states for ShardOrbit: index 0 is self, rest are joined peers
    /// in the same order they appear in the status list below.
    private var shardStates: [ShardOrbit.DotState] {
        var states: [ShardOrbit.DotState] = [
            viewModel.signingProgress >= 1.0 ? .done : .active
        ]
        for peer in viewModel.joinedSigners {
            switch viewModel.peerStates[peer.id] {
            case .waiting, .none: states.append(.waiting)
            case .signing:        states.append(.active)
            case .done:           states.append(.done)
            case .failed:         states.append(.failed)
            }
        }
        // Pad with .waiting up to threshold so the orbit shows the full
        // t-of-n constellation from the start instead of popping in as
        // peers join.
        let target = Int(viewModel.wallet.threshold)
        while states.count < target { states.append(.waiting) }
        return states
    }

    var body: some View {
        let chainTint = viewModel.wallet.chain.color
        VStack(spacing: 24) {
            Spacer(minLength: 8)

            ZStack {
                // Orbiting shard constellation — sits just outside the ring.
                ShardOrbit(
                    total: max(Int(viewModel.wallet.threshold), 1),
                    states: shardStates,
                    radius: 84,
                    tint: chainTint
                )
                ProgressRing(progress: viewModel.signingProgress, tint: chainTint, showPercentage: false)
                    .frame(width: 120, height: 120)
                    .accessibilityLabel(L10n.Signing.signingProgress)
                    .accessibilityValue("\(Int(viewModel.signingProgress * 100)) percent")
                // Chain logo centered inside the ring — ties the ceremony
                // to the specific asset being signed.
                ChainIcon(chain: viewModel.wallet.chain, size: 44)
                    .scaleEffect(completionPulse ? 1.12 : 1.0)
                    .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.5), value: completionPulse)
            }
            .frame(height: 200)

            VStack(spacing: 8) {
                Text(L10n.Signing.signingTransaction)
                    .font(.title2.bold())

                Text(viewModel.signingStatusMessage)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Text(L10n.Signing.roundOf(viewModel.currentRound, viewModel.totalRounds))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(L10n.Signing.signingRound(viewModel.currentRound, viewModel.totalRounds))
                if viewModel.signingStartedAt != nil {
                    Text("·").foregroundStyle(.tertiary)
                    SigningElapsedLabel(startedAt: viewModel.signingStartedAt ?? Date())
                }
            }

            if let started = viewModel.signingStartedAt {
                SigningElapsedHint(startedAt: started)
            }

            // Co-signer status list
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "person.2.fill")
                        .foregroundStyle(chainTint)
                    Text(L10n.Signing.coSigners)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(viewModel.joinedSigners.count + 1) / \(viewModel.wallet.threshold)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                CosignerStatusRow(
                    name: L10n.Signing.selfLabel,
                    status: viewModel.signingProgress >= 1.0 ? .done : .signing,
                    round: viewModel.currentRound,
                    totalRounds: viewModel.totalRounds,
                    isSelf: true,
                    tint: chainTint
                )

                ForEach(viewModel.joinedSigners) { peer in
                    CosignerStatusRow(
                        name: DeviceIdentity.split(peer.name).label,
                        status: viewModel.peerStates[peer.id].flatMap(mapState) ?? .waiting,
                        round: viewModel.peerRounds[peer.id] ?? 0,
                        totalRounds: viewModel.totalRounds,
                        isSelf: false,
                        tint: chainTint
                    )
                }
            }
            .tintedGlassCard(color: chainTint, cornerRadius: 12, padding: 14)
            .padding(.horizontal)

            Spacer()

            Button(L10n.Signing.cancelSigning, role: .destructive) {
                Haptics.warning()
                viewModel.cancelSigning()
            }
            .font(.caption)
            .padding(.bottom)
        }
        .padding()
        .onChange(of: viewModel.signingProgress) { _, new in
            // Celebratory pulse + success haptic the moment the ceremony
            // reaches full threshold. Single-fire via the pulse toggle.
            if new >= 1.0 && !completionPulse {
                Haptics.success()
                completionPulse = true
            }
        }
    }

    private func mapState(_ s: SigningViewModel.PeerSigningState) -> CosignerStatusRow.Status {
        switch s {
        case .waiting: return .waiting
        case .signing: return .signing
        case .done: return .done
        case .failed: return .failed
        }
    }
}

/// Renders a live "mm:ss" elapsed counter from a start date.
private struct SigningElapsedLabel: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1.0)) { ctx in
            let secs = max(0, Int(ctx.date.timeIntervalSince(startedAt)))
            Text(formatted(secs))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private func formatted(_ secs: Int) -> String {
        String(format: "%02d:%02d", secs / 60, secs % 60)
    }
}

/// Shows contextual guidance after signing has been running for a while.
private struct SigningElapsedHint: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1.0)) { ctx in
            let secs = Int(ctx.date.timeIntervalSince(startedAt))
            if secs >= 60 {
                hint(
                    icon: "exclamationmark.triangle.fill",
                    tint: HorcruxTheme.warningAmber,
                    text: L10n.Signing.slowHint
                )
            } else if secs >= 30 {
                hint(
                    icon: "hourglass",
                    tint: HorcruxTheme.accentBlue,
                    text: L10n.Signing.waitingCoSigner
                )
            }
        }
    }

    private func hint(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.12)))
        .padding(.horizontal)
    }
}

private struct CosignerStatusRow: View {
    let name: String
    enum Status { case waiting, signing, done, failed }
    let status: Status
    let round: Int
    let totalRounds: Int
    let isSelf: Bool
    var tint: Color = HorcruxTheme.accentPurple

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isSelf ? "iphone" : "laptopcomputer")
                .foregroundStyle(tint)
                .frame(width: 20)
            Text(name)
                .font(.caption)
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if status == .signing, round > 0 {
                Text("R\(round)/\(totalRounds)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(tint.opacity(0.18)))
            }
            switch status {
            case .waiting:
                Text(L10n.Signing.waiting)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .signing:
                ProgressView().scaleEffect(0.7).tint(tint)
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(HorcruxTheme.successGreen)
            case .failed:
                Image(systemName: "xmark.circle.fill").foregroundStyle(HorcruxTheme.dangerRed)
            }
        }
    }
}

// MARK: - Step 4: Complete

struct SigningCompleteView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var viewModel: SigningViewModel
    @ScaledMetric(relativeTo: .largeTitle) private var largeIconSize: CGFloat = 72
    let dismiss: DismissAction

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @State private var pulse = false
    @State private var sealScale: CGFloat = 0.4
    @State private var hashRevealed = false
    @State private var hashCopied = false

    var body: some View {
        let chainTint = viewModel.wallet.chain.color
        VStack(spacing: 32) {
            Spacer()

            ZStack {
                // Two expanding pulse rings radiate outward when the view
                // appears, then settle into a slow ambient pulse. Tints
                // follow the chain being signed.
                ForEach(0..<2, id: \.self) { i in
                    Circle()
                        .stroke(chainTint.opacity(0.35), lineWidth: 2)
                        .frame(width: largeIconSize * 1.6, height: largeIconSize * 1.6)
                        .scaleEffect(pulse ? 1.35 : 0.9)
                        .opacity(pulse ? 0.0 : 0.9)
                        .animation(
                            reduceMotion ? nil :
                                .easeOut(duration: 1.8)
                                .repeatForever(autoreverses: false)
                                .delay(Double(i) * 0.9),
                            value: pulse
                        )
                }
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [HorcruxTheme.successGreen.opacity(0.35), chainTint.opacity(0.0)],
                            center: .center,
                            startRadius: 2,
                            endRadius: largeIconSize
                        )
                    )
                    .frame(width: largeIconSize * 1.4, height: largeIconSize * 1.4)

                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: largeIconSize))
                    .foregroundStyle(HorcruxTheme.successGreen)
                    .accessibilityHidden(true)
                    .scaleEffect(sealScale)
                    .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.55), value: sealScale)
            }
            .onAppear {
                pulse = true
                sealScale = 1.0
                Haptics.success()
                // Delay the hash reveal so the seal animation lands first —
                // then the tx hash chip floats in with its action row.
                if reduceMotion {
                    hashRevealed = true
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) {
                            hashRevealed = true
                        }
                    }
                }
            }

            VStack(spacing: 8) {
                Text(L10n.Signing.transactionSigned)
                    .font(.title.bold())

                Text(CurrencyFormatter.crypto(Double(viewModel.amount) ?? 0, symbol: viewModel.wallet.chain.symbol))
                    .font(.title2)

                if let txHash = viewModel.txHash {
                    txHashReveal(hash: txHash)
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
                        .foregroundStyle(status.contains("OK") ? HorcruxTheme.successGreen : HorcruxTheme.dangerRed)
                        .multilineTextAlignment(.center)
                } else {
                    Button {
                        Task {
                            // Optional biometric gate — toggle in Settings.
                            let biometricGate = UserDefaults.standard.bool(forKey: "biometricSigningGate")
                            if biometricGate && BiometricAuth.shared.availableType != .none {
                                let ok = await BiometricAuth.shared.authenticate(
                                    reason: L10n.Signing.bioReason
                                )
                                if !ok {
                                    viewModel.broadcastStatus = L10n.SigningExtra.bioFailedIcon
                                    return
                                }
                            }
                            viewModel.broadcastTransaction()
                        }
                    } label: {
                        Label(L10n.Signing.broadcastToNetwork, systemImage: "antenna.radiowaves.left.and.right")
                            .frame(maxWidth: .infinity)
                            .font(.headline)
                    }
                    .buttonStyle(GradientButtonStyle())
                    .tint(HorcruxTheme.successGreen)
                    .padding(.horizontal)
                    .accessibilityHint(L10n.Signing.broadcastHint)
                    .accessibilityIdentifier("complete_broadcastButton")

                    Button {
                        viewModel.saveForLaterBroadcast(queue: appState.pendingBroadcastQueue)
                        dismiss()
                    } label: {
                        Label(L10n.Signing.saveForLater, systemImage: "clock.arrow.circlepath")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(HorcruxTheme.subtleText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .padding(.horizontal)
                    .accessibilityHint(L10n.Signing.saveForLaterHint)
                    .accessibilityIdentifier("complete_saveForLaterButton")
                }
            }

            Spacer()

            // "Send again to same recipient" is offered once the tx has
            // been (a) broadcast successfully OR (b) explicitly saved for
            // later — in either case the current signed tx is done and
            // the user might want to fire another transfer to the same
            // address (e.g. paying the same merchant, recurring transfer).
            // Gated on `txHash != nil` so it only shows on success, and
            // on `!isBroadcasting` so we don't let them leave while the
            // broadcast is in flight.
            if viewModel.txHash != nil, !viewModel.isBroadcasting {
                Button {
                    viewModel.resignToSameRecipient()
                } label: {
                    Label(
                        L10n.Signing.signAgainSameRecipient,
                        systemImage: "arrow.clockwise"
                    )
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(HorcruxTheme.accentCyan)
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal)
                .accessibilityIdentifier("complete_signAgainButton")
            }

            Button { dismiss() } label: {
                Text(L10n.Common.done)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(GradientButtonStyle())
            .padding(.horizontal)
            .accessibilityIdentifier("complete_doneButton")
        }
        .padding()
    }

    /// Tx hash reveal: monospace chip chunked 6-4 with spring fade-in,
    /// copy button, and a conditional explorer link. Anchors the seal
    /// animation — appears 450ms after onAppear so the seal stamps
    /// first, then the receipt chip floats in.
    @ViewBuilder
    private func txHashReveal(hash: String) -> some View {
        let explorerURL = AddressFormatter.txExplorerURL(txHash: hash, chain: viewModel.wallet.chain)
        HStack(spacing: 10) {
            Image(systemName: "number")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(HorcruxTheme.subtleText)
            Text(shortHash(hash))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button {
                SecureClipboard.copy(hash)
                Haptics.success()
                withAnimation(.easeInOut(duration: 0.2)) { hashCopied = true }
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await MainActor.run { withAnimation { hashCopied = false } }
                }
            } label: {
                Image(systemName: hashCopied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(hashCopied ? HorcruxTheme.successGreen : HorcruxTheme.accentBlue)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.WalletDetail.copyAddress)

            if let url = explorerURL {
                Button {
                    Haptics.tap()
                    openURL(url)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                        .foregroundStyle(HorcruxTheme.accentBlue)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.TxDetail.viewOnExplorer)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(HorcruxTheme.hairline, lineWidth: 1)
                )
        )
        .padding(.horizontal, 24)
        .opacity(hashRevealed ? 1.0 : 0.0)
        .offset(y: hashRevealed ? 0 : 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("complete_txHashChip")
    }

    private func shortHash(_ h: String) -> String {
        guard h.count > 14 else { return h }
        return "\(h.prefix(8))…\(h.suffix(6))"
    }
}

struct SigningErrorView: View {
    @ObservedObject var viewModel: SigningViewModel
    @ScaledMetric(relativeTo: .largeTitle) private var errorIconSize: CGFloat = 64

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: errorIconSize))
                .foregroundStyle(HorcruxTheme.dangerRed)
                .accessibilityHidden(true)
            Text(L10n.Signing.signingFailed)
                .font(.title2.bold())
            Text(viewModel.errorMessage)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(L10n.Common.retry) { viewModel.step = .invite }
                .buttonStyle(GradientButtonStyle())
                .padding(.horizontal)
                .accessibilityHint(L10n.Signing.retryHint)
                .accessibilityIdentifier("signingError_retryButton")
            Spacer()
        }
        .padding()
    }
}

// MARK: - Transaction Preview Card (simulation)

/// Decodes and displays the transaction the user is about to sign.
/// For ERC-20 transfers, shows resolved token + recipient + amount.
/// Surfaces warnings for unusual patterns (unknown contract, dust, etc.).
struct TransactionPreviewCard: View {
    @ObservedObject var viewModel: SigningViewModel

    private var isTokenTransfer: Bool { viewModel.selectedToken != nil }

    /// Per-chain / per-standard label shown in the preview card.
    private var operationLabel: String {
        if !isTokenTransfer { return L10n.Signing.nativeTransfer }
        switch viewModel.wallet.chain {
        case .tron: return L10n.SigningExtra.tokenTransferTRC20
        case .solana: return L10n.SigningExtra.tokenTransferSPL
        default: return L10n.SigningExtra.tokenTransferERC20
        }
    }

    private var warnings: [String] {
        var w: [String] = []
        if let amount = Decimal(string: viewModel.amount) {
            if amount == 0 { w.append(L10n.Signing.warnZeroAmount) }
        }
        if viewModel.recipientAddress.lowercased() == viewModel.wallet.address.lowercased() {
            w.append(L10n.Signing.warnSelfTransfer)
        }
        if isTokenTransfer && viewModel.wallet.chain == .ethereum {
            // Already a known token from our curated list = safe. If the list later
            // supports custom tokens, add "未验证合约" warning here.
        }
        return w
    }

    private var plainSummary: String {
        let symbol = viewModel.transferSymbol
        let amount = viewModel.amount.isEmpty ? "0" : viewModel.amount
        if isTokenTransfer {
            return L10n.Signing.tokenTransferDescContract("\(amount)", symbol)
        } else {
            return L10n.Signing.tokenTransferDesc("\(amount)", symbol)
        }
    }

    var body: some View {
        let tint = viewModel.wallet.chain.color
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(tint)
                Text(L10n.Signing.preview)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                Spacer()
                Text(L10n.Signing.offlineDecoded)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Plain-Chinese summary (item 10)
            Text(plainSummary)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.9))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.15)))

            Divider().background(Color.white.opacity(0.08))

            previewRow(label: L10n.Signing.rowOperation, value: operationLabel)
            previewRow(label: L10n.Signing.rowAsset, value: viewModel.transferSymbol)
            previewRow(label: L10n.Signing.rowAmount, value: "\(viewModel.amount) \(viewModel.transferSymbol)")

            // Balance impact — shows "current → after" for native-coin transfers.
            // Skipped for ERC-20: the native balance isn't what's moving, so the
            // comparison would mislead. Fiat value included when a USD quote is cached.
            if !isTokenTransfer, let before = viewModel.preTxBalance {
                balanceImpactRow(before: before)
            }

            // Gas-percentage warning — flag when network fee eats a meaningful share
            // of the send amount. Keep native-only to avoid confusing comparisons
            // between ERC-20 amounts and ETH gas.
            if !isTokenTransfer, let pct = gasPercent(), pct >= 0.05 {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(HorcruxTheme.warningAmber)
                    Text(L10n.Signing.feeWarnPct(pct * 100))
                        .font(.caption)
                        .foregroundStyle(HorcruxTheme.warningAmber)
                }
            }

            // Full recipient — chunked, monospaced, copyable, with explorer link.
            // Intentionally verbose: truncation has caused address-phishing losses.
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L10n.Signing.recipientSegments)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        CopyFeedback.copy(
                            AddressFormatter.canonical(viewModel.recipientAddress, chain: viewModel.wallet.chain),
                            label: L10n.Signing.addressCopied
                        )
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(HorcruxTheme.accentBlue)
                    }
                    .accessibilityLabel(L10n.Signing.a11yCopyRecipient)
                    if let url = viewModel.recipientExplorerURL {
                        Link(destination: url) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption)
                                .foregroundStyle(HorcruxTheme.accentBlue)
                        }
                        .accessibilityLabel(L10n.Signing.a11yExplorer)
                    }
                }
                Text(viewModel.displayRecipient)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))
            }

            if isTokenTransfer, let token = viewModel.selectedToken {
                previewRow(label: L10n.Signing.rowContract, value: shorten(token.id), monospaced: true)
            }
            previewRow(label: L10n.Signing.rowNetworkFee, value: viewModel.estimatedFee)

            if !warnings.isEmpty {
                Divider().background(Color.white.opacity(0.08))
                ForEach(warnings, id: \.self) { msg in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(HorcruxTheme.warningAmber)
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(HorcruxTheme.warningAmber)
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(tint.opacity(0.25), lineWidth: 1)
                )
        )
        .padding(.horizontal)
    }

    @ViewBuilder
    private func previewRow(label: String, value: String, monospaced: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(monospaced ? .system(.caption, design: .monospaced) : .caption.weight(.medium))
                .foregroundStyle(.white)
        }
    }

    private func shorten(_ s: String) -> String {
        guard s.count > 12 else { return s }
        return "\(s.prefix(6))…\(s.suffix(4))"
    }

    /// Extracts the numeric component from `balance()` strings like "1.234 ETH".
    private func parseBalance(_ s: String) -> Double? {
        let cleaned = s.replacingOccurrences(of: ",", with: "")
        let first = cleaned.split(separator: " ").first.map(String.init) ?? cleaned
        return Double(first)
    }

    /// Extracts numeric fee from `estimatedFee` string ("0.0003 ETH" or "~0.0003 ETH").
    private func parseFee(_ s: String) -> Double? {
        let trimmed = s.replacingOccurrences(of: "~", with: "")
            .trimmingCharacters(in: .whitespaces)
        return parseBalance(trimmed)
    }

    /// Gas fee as a fraction of transfer amount (native-coin only).
    private func gasPercent() -> Double? {
        guard let amt = Double(viewModel.amount), amt > 0 else { return nil }
        guard let fee = parseFee(viewModel.estimatedFee), fee > 0 else { return nil }
        return fee / amt
    }

    @ViewBuilder
    private func balanceImpactRow(before: String) -> some View {
        let beforeVal = parseBalance(before) ?? 0
        let amt = Double(viewModel.amount) ?? 0
        let fee = parseFee(viewModel.estimatedFee) ?? 0
        let after = max(0, beforeVal - amt - fee)
        let symbol = viewModel.wallet.chain.symbol
        let priceService = PriceService.shared
        let beforeUSD = priceService.fiatString(amount: beforeVal, symbol: symbol)
        let afterUSD = priceService.fiatString(amount: after, symbol: symbol)

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L10n.Signing.balanceChange)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 6) {
                    Text(String(format: "%.6f %@", beforeVal, symbol))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                        .strikethrough(true)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.6f %@", after, symbol))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                }
            }
            if let beforeUSD, let afterUSD {
                HStack {
                    Spacer()
                    Text("\(beforeUSD) → \(afterUSD)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Transport-selection card for the signing invite step. Two toggles:
/// "中继服务器" routes the ceremony through the public relay (works
/// across networks, requires server reachability) and "同一 Wi-Fi"
/// advertises via Bonjour on the local network (no relay, no server,
/// limited to same LAN). At least one must be on — we enforce that
/// here so the user can't accidentally strand the flow with both off.
private struct SigningTransportPicker: View {
    @ObservedObject var viewModel: SigningViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                VaultSectionHeader(L10n.Signing.transportTitle, icon: "antenna.radiowaves.left.and.right")
                Spacer()
                Text(transportModeLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(HorcruxTheme.accentCyan)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(HorcruxTheme.accentCyan.opacity(0.15))
                    )
            }

            transportToggle(
                .relay,
                title: L10n.Signing.transportRelayTitle,
                subtitle: L10n.Signing.transportRelaySubtitle
            )
            transportToggle(
                .wifiLAN,
                title: L10n.Signing.transportLANTitle,
                subtitle: L10n.Signing.transportLANSubtitle
            )

            if viewModel.selectedTransports.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(HorcruxTheme.warningAmber)
                    Text(L10n.Signing.transportAtLeastOne)
                        .font(.caption)
                        .foregroundStyle(HorcruxTheme.warningAmber)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(HorcruxTheme.hairline, lineWidth: 1))
        )
    }

    /// Compact label summarising the current toggle state, shown in the
    /// header as a pill. Makes "both on" (the recommended default) a
    /// first-class, named mode instead of an untitled checkbox combo.
    private var transportModeLabel: String {
        let set = viewModel.selectedTransports
        let hasRelay = set.contains(.relay)
        let hasLAN = set.contains(.wifiLAN)
        if hasRelay && hasLAN { return L10n.Signing.transportModeAuto }
        if hasRelay { return L10n.Signing.transportModeRelayOnly }
        if hasLAN { return L10n.Signing.transportModeLANOnly }
        return L10n.Signing.transportAtLeastOne
    }

    @ViewBuilder
    private func transportToggle(
        _ type: TransportType,
        title: String,
        subtitle: String
    ) -> some View {
        Toggle(isOn: Binding(
            get: { viewModel.selectedTransports.contains(type) },
            set: { on in
                var next = viewModel.selectedTransports
                if on {
                    next.insert(type)
                } else {
                    next.remove(type)
                }
                // Defensive: if the user just disabled the last channel,
                // snap relay back on so the ceremony can still reach a
                // cosigner. UX-safer than silently accepting an unusable
                // configuration.
                if next.isEmpty { next.insert(.relay) }
                viewModel.selectedTransports = next
                viewModel.prepareInvite()
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: type.iconName)
                        .foregroundStyle(HorcruxTheme.accentCyan)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(HorcruxTheme.subtleText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(HorcruxTheme.accentPurple)
    }
}

/// Share card for the 3-word signing room code. Mirrors the pattern used
/// in DKG/refresh flows: copy-to-clipboard button + tap-to-expand QR so a
/// co-signer can scan instead of typing.
private struct SigningRoomCodeCard: View {
    let code: String
    @State private var copied = false
    @State private var expanded = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.CreateShard.roomCodeLabel)
                    .font(.caption)
                    .foregroundStyle(HorcruxTheme.subtleText)
                Text(code)
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer()
            Button {
                SecureClipboard.copy(code, toast: L10n.Signing.roomCodeCopied)
                Haptics.success()
                withAnimation { copied = true }
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await MainActor.run { withAnimation { copied = false } }
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(copied ? HorcruxTheme.successGreen : HorcruxTheme.accentCyan)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.06)))
            }
            .accessibilityLabel(L10n.CreateShard.copyRoomCode)
            Button {
                expanded = true
            } label: {
                SigningRoomCodeQR(code: code)
                    .frame(width: 44, height: 44)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
            }
            .accessibilityLabel(L10n.CreateShard.showQR)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(HorcruxTheme.hairline, lineWidth: 1))
        )
        .sheet(isPresented: $expanded) {
            SigningRoomCodeExpandedSheet(code: code)
                .presentationDetents([.medium])
        }
    }
}

private struct SigningRoomCodeQR: View {
    let code: String
    var body: some View {
        if let img = Self.generate(code) {
            Image(uiImage: img)
                .interpolation(.none)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "qrcode")
                .foregroundStyle(.black)
        }
    }

    private static func generate(_ text: String) -> UIImage? {
        let data = Data("horcrux-room:\(text)".utf8)
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ci = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

private struct SigningRoomCodeExpandedSheet: View {
    let code: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ZStack {
                HorcruxTheme.backgroundGradient.ignoresSafeArea()
                VStack(spacing: 20) {
                    Text(L10n.CreateShard.roomCodeLabel)
                        .font(.caption)
                        .foregroundStyle(HorcruxTheme.subtleText)
                    Text(code)
                        .font(.system(.title, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.white)
                    SigningRoomCodeQR(code: code)
                        .frame(width: 240, height: 240)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
                    Text(L10n.Signing.shareRoomCodeHint)
                        .font(.footnote)
                        .foregroundStyle(HorcruxTheme.subtleText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .padding()
            }
            .navigationTitle(L10n.Signing.inviteCoSigners)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.Common.done) { dismiss() }
                }
            }
        }
    }
}

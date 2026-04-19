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
                }
                .darkListRow()
            }

            Section {
                Button {
                    viewModel.estimateGas()
                    viewModel.step = .invite
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

    /// How many peers (excluding self) are needed to reach threshold.
    private var peersNeeded: Int { Int(viewModel.wallet.threshold) - 1 }
    private var peersJoined: Int { viewModel.joinedSigners.count }
    private var thresholdMet: Bool { peersJoined >= peersNeeded }

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

                    // Joined peers list
                    if !viewModel.joinedSigners.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            VaultSectionHeader(L10n.Signing.coSigners, icon: "person.2.fill")
                            ForEach(viewModel.joinedSigners) { peer in
                                HStack(spacing: 10) {
                                    Image(systemName: "person.circle.fill")
                                        .foregroundStyle(HorcruxTheme.successGreen)
                                    Text(peer.name)
                                        .foregroundStyle(.white)
                                    Spacer()
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(HorcruxTheme.successGreen)
                                }
                                .tintedGlassCard(color: chainTint)
                            }
                        }
                    }

                    // Waiting indicator until threshold met
                    if !thresholdMet {
                        HStack(spacing: 10) {
                            ProgressView()
                                .tint(chainTint)
                            Text(L10n.Signing.waitingForCoSigners)
                                .font(.subheadline)
                                .foregroundStyle(HorcruxTheme.subtleText)
                        }
                        .padding(.vertical, 8)
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
                ProgressRing(progress: viewModel.signingProgress, tint: chainTint)
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
                        name: peer.name,
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
    @State private var pulse = false
    @State private var sealScale: CGFloat = 0.4

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
            }

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
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(HorcruxTheme.accentBlue)
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
                .background(RoundedRectangle(cornerRadius: 8).fill(HorcruxTheme.accentBlue.opacity(0.15)))

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
                        .stroke(HorcruxTheme.accentBlue.opacity(0.25), lineWidth: 1)
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

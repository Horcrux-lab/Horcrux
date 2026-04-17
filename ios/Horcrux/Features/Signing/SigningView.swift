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
    @State private var showAddressBook = false
    @State private var ensStatus: String?
    @StateObject private var priceService = PriceService.shared

    private var addressError: String? {
        guard !viewModel.recipientAddress.isEmpty else { return nil }
        // Skip validation while ENS resolution is pending/used
        if viewModel.recipientAddress.hasSuffix(".eth") { return nil }
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
                        .onChange(of: viewModel.recipientAddress) { _, newVal in
                            if newVal.hasSuffix(".eth"), viewModel.wallet.chain == .ethereum {
                                resolveENS(newVal)
                            } else {
                                ensStatus = nil
                            }
                        }

                    if viewModel.wallet.chain != .bitcoin {
                        Button {
                            showAddressBook = true
                        } label: {
                            Image(systemName: "person.crop.circle")
                                .font(.title2)
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("从地址簿选择")
                        .accessibilityIdentifier("compose_addressBookButton")
                    } else {
                        Button {
                            showAddressBook = true
                        } label: {
                            Image(systemName: "person.crop.circle")
                                .font(.title2)
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("从地址簿选择")
                    }

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

                if let ensStatus {
                    HStack(spacing: 6) {
                        Image(systemName: "at.circle")
                            .foregroundStyle(.blue)
                        Text(ensStatus)
                            .font(.caption)
                    }
                }

                if let primaryName = viewModel.resolvedRecipientENS {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text("ENS: \(primaryName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("compose_resolvedENS")
                }

                if let addressError {
                    Text(addressError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section(L10n.Signing.amount) {
                if !viewModel.availableTokens.isEmpty {
                    Picker("资产", selection: Binding(
                        get: { viewModel.selectedToken?.id ?? "__native__" },
                        set: { newId in
                            if newId == "__native__" {
                                viewModel.selectedToken = nil
                            } else {
                                viewModel.selectedToken = viewModel.availableTokens.first { $0.id == newId }
                            }
                        }
                    )) {
                        Text(viewModel.wallet.chain.symbol + "（原生代币）").tag("__native__")
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
                        Button("Max") {
                            viewModel.fillMax()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("compose_maxButton")
                    }
                    Text(viewModel.transferSymbol)
                        .foregroundStyle(.secondary)
                }
            }

            if viewModel.wallet.chain.isEVM {
                Section(L10n.Signing.gas) {
                    Picker("费用优先级", selection: $viewModel.feeTier) {
                        ForEach(SigningViewModel.FeeTier.allCases) { tier in
                            Text(tier.label).tag(tier)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("compose_feeTierPicker")

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
        ensStatus = "解析 \(name) …"
        Task {
            let resolved = await ENSResolver.resolve(name)
            await MainActor.run {
                if let addr = resolved {
                    ensStatus = "→ \(addr.prefix(10))…\(addr.suffix(6))"
                    viewModel.recipientAddress = addr
                } else {
                    ensStatus = "ENS 解析失败，请手动粘贴地址。"
                }
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

            // Transaction preview (simulation)
            TransactionPreviewCard(viewModel: viewModel)

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
                    // Fast path: SWK is cached from the unlock session.
                    if let swk = appState.cachedShardKey() {
                        viewModel.setShardKey(swk)
                        viewModel.startSigning()
                    } else {
                        showPinPrompt = true
                    }
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
                // `verifyPin` populated the cache; grab the SWK and start.
                guard let swk = appState.cachedShardKey() else {
                    pinError = L10n.Signing.incorrectPin
                    pin = ""
                    showPinPrompt = true
                    return
                }
                viewModel.setShardKey(swk)
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
        VStack(spacing: 24) {
            Spacer(minLength: 8)

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

            // Elapsed hint — MPC ceremonies can feel "stuck" because there's no
            // traditional progress bar during the cross-device round-trips. These
            // thresholds tell the user whether "still waiting" is normal or not.
            if let started = viewModel.signingStartedAt {
                SigningElapsedHint(startedAt: started)
            }

            // Co-signer status list
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "person.2.fill")
                        .foregroundStyle(HorcruxTheme.accentPurple)
                    Text("共同签名方")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(viewModel.joinedSigners.count + 1) / \(viewModel.wallet.threshold)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                // Self — always "signing" while ceremony runs, "done" once complete.
                CosignerStatusRow(
                    name: "本机（你）",
                    status: viewModel.signingProgress >= 1.0 ? .done : .signing,
                    round: viewModel.currentRound,
                    totalRounds: viewModel.totalRounds,
                    isSelf: true
                )

                // Remote signers — state driven by real MPC message arrivals.
                ForEach(viewModel.joinedSigners) { peer in
                    CosignerStatusRow(
                        name: peer.name,
                        status: viewModel.peerStates[peer.id].flatMap(mapState) ?? .waiting,
                        round: viewModel.peerRounds[peer.id] ?? 0,
                        totalRounds: viewModel.totalRounds,
                        isSelf: false
                    )
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.04))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 1))
            )
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
                    tint: .orange,
                    text: "签名用时偏长。可尝试取消后重新发起，或检查共同签名方的网络。"
                )
            } else if secs >= 30 {
                hint(
                    icon: "hourglass",
                    tint: HorcruxTheme.accentBlue,
                    text: "正在等待共同签名方完成本轮计算……"
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

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isSelf ? "iphone" : "laptopcomputer")
                .foregroundStyle(HorcruxTheme.accentPurple)
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
                    .background(Capsule().fill(HorcruxTheme.accentPurple.opacity(0.15)))
            }
            switch status {
            case .waiting:
                Text("等待中")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .signing:
                ProgressView().scaleEffect(0.7)
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
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

// MARK: - Transaction Preview Card (simulation)

/// Decodes and displays the transaction the user is about to sign.
/// For ERC-20 transfers, shows resolved token + recipient + amount.
/// Surfaces warnings for unusual patterns (unknown contract, dust, etc.).
struct TransactionPreviewCard: View {
    @ObservedObject var viewModel: SigningViewModel

    private var isTokenTransfer: Bool { viewModel.selectedToken != nil }

    private var warnings: [String] {
        var w: [String] = []
        if let amount = Decimal(string: viewModel.amount) {
            if amount == 0 { w.append("金额为 0，交易不会转移任何资产") }
        }
        if viewModel.recipientAddress.lowercased() == viewModel.wallet.address.lowercased() {
            w.append("收款地址是你自己")
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
            return "你将把 \(amount) \(symbol) 从本钱包发送到下面的收款地址（调用合约 transfer 方法，不会改变其他资产）。请仔细核对地址每一段。"
        } else {
            return "你将把 \(amount) \(symbol) 从本钱包发送到下面的收款地址。请仔细核对地址每一段。"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(HorcruxTheme.accentBlue)
                Text("交易预览")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                Spacer()
                Text("离线解码")
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

            previewRow(label: "操作", value: isTokenTransfer ? "ERC-20 转账" : "原生代币转账")
            previewRow(label: "资产", value: viewModel.transferSymbol)
            previewRow(label: "金额", value: "\(viewModel.amount) \(viewModel.transferSymbol)")

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
                        .foregroundStyle(.orange)
                    Text(String(format: "网络费占转账金额 %.1f%%，建议确认后再签名。", pct * 100))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            // Full recipient — chunked, monospaced, copyable, with explorer link.
            // Intentionally verbose: truncation has caused address-phishing losses.
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("收款地址（请逐段核对）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        CopyFeedback.copy(
                            AddressFormatter.canonical(viewModel.recipientAddress, chain: viewModel.wallet.chain),
                            label: "地址已复制"
                        )
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(HorcruxTheme.accentBlue)
                    }
                    .accessibilityLabel("复制收款地址")
                    if let url = viewModel.recipientExplorerURL {
                        Link(destination: url) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption)
                                .foregroundStyle(HorcruxTheme.accentBlue)
                        }
                        .accessibilityLabel("在区块浏览器中查看")
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
                previewRow(label: "合约", value: shorten(token.id), monospaced: true)
            }
            previewRow(label: "网络费", value: viewModel.estimatedFee)

            if !warnings.isEmpty {
                Divider().background(Color.white.opacity(0.08))
                ForEach(warnings, id: \.self) { msg in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.orange)
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
                Text("余额变化")
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

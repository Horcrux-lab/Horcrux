import SwiftUI
import Combine
import UIKit

/// Entry point for a **co-signer** joining a multi-party hot signing
/// ceremony started by another device. Mirrors the initiator-side
/// `InviteSignersView` but approached from the opposite end:
///
/// 1. User enters the three-word room code shared by the initiator.
/// 2. We join the relay room and start listening for a `SignRequestDTO`
///    beacon (the initiator re-broadcasts one periodically).
/// 3. On receive, we identify which of this device's local wallets
///    matches the initiator's `groupPublicKey` and render a
///    transaction preview for user review.
/// 4. On approve → PIN/biometric unlock → spin up a local
///    `SigningViewModel`, mirror the initiator's tx inputs via
///    `applySignRequest(_:)`, and call `startSigning()` so the cosigner
///    participates in the MPC rounds over the already-joined relay.
///
/// Stays out of the signing path entirely if the user dismisses before
/// approving, so an unsolicited or scam room code can't start a
/// ceremony without explicit human confirmation.
struct JoinSigningView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    enum Phase {
        case enterCode
        case joining
        case waiting
        case reviewing(SignRequestDTO, Wallet)
        case unmatchedWallet(SignRequestDTO)
        case signing(SigningViewModel)
        case error(String)
    }

    @State private var phase: Phase = .enterCode
    @State private var roomCode: String = ""
    @State private var listenerTask: Task<Void, Never>?
    @State private var showPinSheet = false

    var body: some View {
        NavigationStack {
            ZStack {
                HorcruxTheme.backgroundGradient.ignoresSafeArea()
                content
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }
            .navigationTitle(L10n.JoinSigning.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.cancel) {
                        cleanup()
                        dismiss()
                    }
                }
            }
            .onDisappear { cleanup() }
            .preferredColorScheme(.dark)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .enterCode:
            enterCodeView
        case .joining:
            statusView(icon: "network", title: L10n.Signing.joiningRoom)
        case .waiting:
            waitingView
        case let .reviewing(dto, wallet):
            reviewView(dto: dto, wallet: wallet)
        case let .unmatchedWallet(dto):
            unmatchedView(dto: dto)
        case let .signing(vm):
            SigningProgressView(viewModel: vm)
                .onAppear { _ = vm }
        case let .error(message):
            errorView(message)
        }
    }

    // MARK: - Enter code

    private var enterCodeView: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.JoinSigning.intro)
                    .font(.body)
                    .foregroundStyle(.white)
                Text(L10n.JoinSigning.introHint)
                    .font(.footnote)
                    .foregroundStyle(HorcruxTheme.subtleText)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.CreateShard.roomCodeLabel)
                    .font(.caption)
                    .foregroundStyle(HorcruxTheme.subtleText)
                HStack {
                    TextField(L10n.CreateShard.roomCodePlaceholder, text: $roomCode)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: roomCode) { _, newValue in
                            let normalized = RoomCode.normalize(newValue)
                            if normalized != newValue { roomCode = normalized }
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
                    Button {
                        if let pasted = UIPasteboard.general.string {
                            roomCode = RoomCode.normalize(pasted)
                            Haptics.success()
                        } else {
                            Haptics.warning()
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .foregroundStyle(HorcruxTheme.accentCyan)
                    }
                    .buttonStyle(.bordered)
                }
                if !roomCode.isEmpty && !RoomCode.isValid(roomCode) {
                    Text(L10n.CreateShard.roomCodeInvalid)
                        .font(.caption2)
                        .foregroundStyle(HorcruxTheme.warningAmber)
                }
            }

            Button {
                joinRoom()
            } label: {
                Text(L10n.JoinSigning.joinButton)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(GradientButtonStyle(
                isEnabled: RoomCode.isValid(roomCode),
                tint: HorcruxTheme.accentPurple
            ))
            .disabled(!RoomCode.isValid(roomCode))

            Spacer()
        }
    }

    // MARK: - Waiting

    private var waitingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(HorcruxTheme.accentPurple)
                .padding(.top, 40)
            Text(L10n.JoinSigning.waitingForRequest)
                .font(.headline)
                .foregroundStyle(.white)
            Text(L10n.JoinSigning.waitingForRequestHint)
                .font(.footnote)
                .foregroundStyle(HorcruxTheme.subtleText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Text(roomCode)
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(HorcruxTheme.accentCyan)
                .padding(.top, 8)
            Spacer()
        }
    }

    // MARK: - Review

    private func reviewView(dto: SignRequestDTO, wallet: Wallet) -> some View {
        let chainTint = wallet.chain.color
        let tokenSymbol = dto.tokenSymbol ?? wallet.chain.symbol
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.JoinSigning.reviewTitle)
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                    Text(L10n.JoinSigning.fromDevice(dto.initiatorDeviceName))
                        .font(.footnote)
                        .foregroundStyle(HorcruxTheme.subtleText)
                }

                VStack(alignment: .leading, spacing: 12) {
                    previewRow(label: L10n.JoinSigning.wallet,
                               value: "\(wallet.chain.displayName) · \(wallet.address.prefix(8))…\(wallet.address.suffix(6))")
                    previewRow(label: L10n.JoinSigning.recipient,
                               value: "\(dto.recipient.prefix(10))…\(dto.recipient.suffix(6))",
                               mono: true)
                    previewRow(label: L10n.JoinSigning.amount,
                               value: "\(dto.amount) \(tokenSymbol)")
                    if let fee = dto.feeDisplay {
                        previewRow(label: L10n.Signing.estFee, value: fee)
                    }
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.white.opacity(0.05))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(HorcruxTheme.hairline, lineWidth: 1))
                )

                Text(L10n.JoinSigning.verifyWarning)
                    .font(.footnote)
                    .foregroundStyle(HorcruxTheme.warningAmber)
                    .padding(.horizontal, 4)

                Button {
                    approve(dto: dto, wallet: wallet)
                } label: {
                    Text(L10n.JoinSigning.approve)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GradientButtonStyle(tint: chainTint))

                Button {
                    cleanup()
                    dismiss()
                } label: {
                    Text(L10n.JoinSigning.reject)
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(HorcruxTheme.warningAmber)
                        .padding(.vertical, 12)
                }
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
                DispatchQueue.main.async {
                    self.startSigningWithSWK(swk, dto: dto, wallet: wallet)
                }
                return nil
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func previewRow(label: String, value: String, mono: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(HorcruxTheme.subtleText)
            Spacer()
            Text(value)
                .font(mono ? .system(.footnote, design: .monospaced) : .footnote)
                .foregroundStyle(.white)
                .multilineTextAlignment(.trailing)
        }
    }

    private func unmatchedView(dto: SignRequestDTO) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "questionmark.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(HorcruxTheme.warningAmber)
            Text(L10n.JoinSigning.unmatchedTitle)
                .font(.headline)
                .foregroundStyle(.white)
            Text(L10n.JoinSigning.unmatchedBody(dto.groupPublicKey.prefix(16) + "…"))
                .font(.footnote)
                .foregroundStyle(HorcruxTheme.subtleText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button(L10n.Common.close) {
                cleanup()
                dismiss()
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .padding(.top, 40)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(HorcruxTheme.warningAmber)
            Text(message)
                .font(.footnote)
                .foregroundStyle(HorcruxTheme.subtleText)
                .multilineTextAlignment(.center)
            Button(L10n.Common.retry) {
                phase = .enterCode
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .padding(.top, 40)
    }

    private func statusView(icon: String, title: String) -> some View {
        VStack(spacing: 16) {
            ProgressView().scaleEffect(1.5).tint(HorcruxTheme.accentPurple)
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
            Spacer()
        }
        .padding(.top, 40)
    }

    // MARK: - Actions

    private func joinRoom() {
        let code = roomCode
        phase = .joining
        Task {
            do {
                try await appState.peerManager.joinRelayRoom(roomId: code)
                appState.peerManager.relay.startDiscovery()
                await MainActor.run {
                    phase = .waiting
                    startListening(code: code)
                }
            } catch {
                await MainActor.run {
                    phase = .error(error.localizedDescription)
                }
            }
        }
    }

    private func startListening(code: String) {
        listenerTask?.cancel()
        let (_, stream) = appState.peerManager.mpcMessageStream()
        listenerTask = Task { [appState] in
            for await (_, data) in stream {
                if Task.isCancelled { return }
                guard let dto = try? JSONDecoder().decode(SignRequestDTO.self, from: data),
                      dto.magic == SignRequestDTO.magic,
                      dto.sessionId == code else { continue }
                // Match to a local wallet by groupPublicKey.
                let chain = Chain(rawValue: dto.chain)
                let match = appState.walletStore.wallets.first { w in
                    let hex = w.groupPublicKey.map { String(format: "%02x", $0) }.joined()
                    return hex == dto.groupPublicKey && (chain == nil || w.chain == chain)
                }
                await MainActor.run {
                    if let wallet = match {
                        self.phase = .reviewing(dto, wallet)
                    } else {
                        self.phase = .unmatchedWallet(dto)
                    }
                }
                return
            }
        }
    }

    private func approve(dto: SignRequestDTO, wallet: Wallet) {
        // Fast path: cached SWK from a prior unlock.
        if let swk = appState.cachedShardKey() {
            startSigningWithSWK(swk, dto: dto, wallet: wallet)
        } else {
            showPinSheet = true
        }
    }

    private func startSigningWithSWK(_ swk: Data, dto: SignRequestDTO, wallet: Wallet) {
        let vm = SigningViewModel(wallet: wallet)
        vm.bind(to: appState)
        vm.applySignRequest(dto)
        vm.setShardKey(swk)
        // Skip the invite step — cosigner has already approved the tx and
        // the relay room is already joined.
        vm.step = .signing
        phase = .signing(vm)
        vm.startSigning()
    }

    private func cleanup() {
        listenerTask?.cancel()
        listenerTask = nil
    }
}

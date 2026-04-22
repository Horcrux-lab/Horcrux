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
    @State private var listenerSubId: UUID?
    @State private var showPinSheet = false
    @State private var showScanner = false
    @State private var didAutoJoin = false
    /// Mirror of `appState.peerManager.wifiLAN.discoveredPeers`. SwiftUI does
    /// not automatically observe nested ObservableObjects, so reading the
    /// @Published array through `appState` does not trigger re-renders when
    /// Bonjour turns up a new peer — which is why LAN devices only showed
    /// after a view re-entry. We subscribe explicitly in `onAppear`.
    @State private var nearbyPeers: [Peer] = []

    /// Optional code to prefill from a deep link (`horcrux://join?session=…`).
    /// If provided and valid, we auto-click the join button once on appear.
    let prefilledCode: String?

    init(prefilledCode: String? = nil) {
        self.prefilledCode = prefilledCode
        _roomCode = State(initialValue: RoomCode.normalize(prefilledCode ?? ""))
    }

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
            .onAppear {
                // Start LAN discovery so Bonjour-advertised initiators
                // appear in the nearby list. The user can still type a
                // room code and use the relay — both paths coexist.
                appState.peerManager.wifiLAN.startDiscovery()
                // Seed with whatever Bonjour has already found before we
                // subscribe; the onReceive handler below keeps it fresh.
                nearbyPeers = appState.peerManager.wifiLAN.discoveredPeers
                if !didAutoJoin, let code = prefilledCode,
                   RoomCode.isValid(RoomCode.normalize(code)) {
                    didAutoJoin = true
                    joinRoom()
                }
            }
            .onReceive(appState.peerManager.wifiLAN.$discoveredPeers) { peers in
                nearbyPeers = peers
            }
            .onDisappear { cleanup() }
            .sheet(isPresented: $showScanner) {
                QRScannerView(onScan: handleScannedPayload)
            }
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
            JoinSigningProgressBridge(viewModel: vm, onComplete: {
                cleanup()
                dismiss()
            })
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
                    .accessibilityLabel(L10n.CreateShard.copyRoomCode)

                    Button {
                        showScanner = true
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                            .foregroundStyle(HorcruxTheme.accentCyan)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(L10n.JoinSigning.scanButton)
                    .accessibilityIdentifier("joinSigning_scanButton")
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

            nearbyPeersSection

            Spacer()
        }
    }

    /// Same-LAN discovery: Bonjour-advertised initiators in `.invite`
    /// step show up here. Tapping connects over Wi-Fi LAN directly
    /// without needing the relay or a typed room code — the approval
    /// card still gates the actual signing so a malicious nearby
    /// device cannot silently start a ceremony.
    @ViewBuilder
    private var nearbyPeersSection: some View {
        let peers = nearbyPeers
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "wifi")
                    .font(.caption)
                    .foregroundStyle(HorcruxTheme.accentCyan)
                Text(L10n.JoinSigning.nearbyDevices)
                    .font(.caption)
                    .foregroundStyle(HorcruxTheme.subtleText)
            }
            if peers.isEmpty {
                Text(L10n.JoinSigning.nearbySearching)
                    .font(.footnote)
                    .foregroundStyle(HorcruxTheme.subtleText.opacity(0.6))
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 6) {
                    ForEach(peers, id: \.id) { peer in
                        Button {
                            connectToNearby(peer)
                        } label: {
                            HStack {
                                Image(systemName: "iphone")
                                    .foregroundStyle(HorcruxTheme.accentCyan)
                                VStack(alignment: .leading, spacing: 2) {
                                    let parts = DeviceIdentity.split(peer.name)
                                    Text(parts.label)
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.white)
                                    if let sid = parts.shortId {
                                        Text("ID: \(sid) · Wi-Fi LAN")
                                            .font(.caption2)
                                            .foregroundStyle(HorcruxTheme.subtleText)
                                            .monospaced()
                                    } else {
                                        Text("Wi-Fi LAN")
                                            .font(.caption2)
                                            .foregroundStyle(HorcruxTheme.subtleText)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(HorcruxTheme.subtleText)
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("joinSigning_nearbyPeer_\(peer.id)")
                    }
                }
            }
        }
        .padding(.top, 6)
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
        // 8-char fingerprint of the wallet's group public key. Gives the
        // cosigner a short string to compare out-of-band with the
        // initiator — protects against a malicious initiator who knows
        // the room code but is trying to get signatures from the wrong
        // wallet (would produce a different fingerprint → mismatch).
        let gpkFingerprint = wallet.groupPublicKey
            .prefix(4)
            .map { String(format: "%02x", $0) }
            .joined()
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
                    // Wallet identity: show the user's own nickname for
                    // this wallet + short fingerprint so the cosigner
                    // confirms *which* wallet is signing, not just that
                    // the address roughly matches.
                    previewRow(label: L10n.JoinSigning.wallet,
                               value: wallet.name.isEmpty
                                   ? wallet.chain.displayName
                                   : "\(wallet.name) · \(wallet.chain.displayName)")
                    previewRow(label: L10n.JoinSigning.walletFingerprint,
                               value: gpkFingerprint,
                               mono: true)
                    previewRow(label: L10n.JoinSigning.fromAddress,
                               value: AddressFormatter.chunked(wallet.address),
                               mono: true)
                    previewRow(label: L10n.JoinSigning.recipient,
                               value: AddressFormatter.chunked(dto.recipient),
                               mono: true)
                    // Token contract fingerprint — catches a malicious
                    // initiator swapping USDC for a fake token with the
                    // same symbol but a different contract address.
                    if let contract = dto.tokenContract, !contract.isEmpty {
                        previewRow(label: L10n.JoinSigning.tokenContract,
                                   value: "\(contract.prefix(8))…\(contract.suffix(6))",
                                   mono: true)
                    }
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
                    ApprovalRequestStore.shared.enqueue(from: dto)
                    Haptics.success()
                    cleanup()
                    dismiss()
                } label: {
                    Text(L10n.Approvals.saveForLater)
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(HorcruxTheme.accentCyan)
                        .padding(.vertical, 10)
                }

                Button {
                    ApprovalRequestStore.shared.log(from: dto, status: .rejected)
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

    /// Handles a decoded QR payload from `QRScannerView`. Accepts two
    /// formats symmetrically with what the initiator's invite screen
    /// produces:
    ///
    /// 1. `horcrux-room:<code>` — the plain prefix used by
    ///    `SigningRoomCodeQR` (compact, high-density QR).
    /// 2. `horcrux://join?session=<code>` — the deep-link URL that a
    ///    user might also share via iMessage / email.
    ///
    /// Anything else is rejected with a haptic warning; the scanner
    /// sheet stays dismissed either way so the user can try again
    /// explicitly.
    private func handleScannedPayload(_ raw: String) {
        showScanner = false
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        var candidate: String? = nil
        if trimmed.hasPrefix("horcrux-room:") {
            candidate = String(trimmed.dropFirst("horcrux-room:".count))
        } else if let url = URL(string: trimmed),
                  url.scheme == "horcrux",
                  url.host == "join" || url.host == "sign",
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  let session = items.first(where: { $0.name == "session" })?.value {
            candidate = session
        } else {
            candidate = trimmed
        }

        guard let raw = candidate else {
            Haptics.warning()
            return
        }
        let normalized = RoomCode.normalize(raw)
        guard RoomCode.isValid(normalized) else {
            Haptics.warning()
            phase = .error(L10n.JoinSigning.scannedInvalid)
            return
        }
        Haptics.success()
        roomCode = normalized
        joinRoom()
    }

    private func joinRoom() {
        let code = roomCode
        phase = .joining
        Task {
            do {
                try await appState.peerManager.joinRelayRoom(roomId: code)
                appState.peerManager.relay.startDiscovery()
                await MainActor.run {
                    phase = .waiting
                    startListening(expectedCode: code)
                }
                await sendPresencePing(sessionId: code)
            } catch {
                await MainActor.run {
                    phase = .error(error.localizedDescription)
                }
            }
        }
    }

    /// Join a signing ceremony via a same-LAN peer. No room code is
    /// required: after the Noise handshake the initiator's periodic
    /// `SignRequestDTO` beacon reaches us over the direct link, the
    /// review card still gates approval, and the session ID is taken
    /// from the DTO — matching the initiator's MPC bridge session.
    private func connectToNearby(_ peer: Peer) {
        phase = .joining
        Task {
            do {
                try await appState.peerManager.connect(to: peer)
                await MainActor.run {
                    phase = .waiting
                    // Accept any SignRequestDTO (no code filter) — the
                    // initiator's DTO carries the session ID we'll adopt.
                    startListening(expectedCode: nil)
                }
                // Without a pre-negotiated session id we can't scope the
                // ping to one ceremony, so use a wildcard; the initiator
                // treats any presence ping as "a peer showed up".
                await sendPresencePing(sessionId: "")
            } catch {
                await MainActor.run {
                    phase = .error(error.localizedDescription)
                }
            }
        }
    }

    /// Fire-and-forget "I'm here" DTO so the initiator's `connectedPeers`
    /// gets populated and its invite UI moves from "等待共签方加入" to
    /// "1 加入". Uses `broadcastMpcMessage`, which falls back to
    /// `allPeers` when `connectedPeers` is empty — so the packet reaches
    /// the initiator over whichever transport(s) we just joined.
    private func sendPresencePing(sessionId: String) async {
        let name = DeviceIdentity.displayName
        let dto = SignPresenceDTO(sessionId: sessionId, deviceName: name)
        guard let payload = try? JSONEncoder().encode(dto) else { return }
        try? await appState.peerManager.broadcastMpcMessage(payload)
    }

    private func startListening(expectedCode: String?) {
        listenerTask?.cancel()
        if let oldSubId = listenerSubId {
            appState.peerManager.unsubscribeMpc(oldSubId)
        }
        let peerManager = appState.peerManager
        let (subId, stream) = peerManager.mpcMessageStream()
        listenerSubId = subId
        listenerTask = Task { [appState] in
            defer { peerManager.unsubscribeMpc(subId) }
            for await (_, data) in stream {
                if Task.isCancelled { return }
                guard let dto = try? JSONDecoder().decode(SignRequestDTO.self, from: data),
                      dto.magic == SignRequestDTO.magic else { continue }
                // If the user typed a room code, enforce it so an
                // unrelated ceremony can't hijack the session. For
                // LAN-direct joins (no typed code) we trust that the
                // tapped peer is the intended initiator — the approval
                // card's device name + out-of-band verification is the
                // guard.
                if let expected = expectedCode, dto.sessionId != expected { continue }
                // Match to a local wallet by groupPublicKey.
                let chain = Chain(rawValue: dto.chain)
                let match = appState.walletStore.wallets.first { w in
                    let hex = w.groupPublicKey.map { String(format: "%02x", $0) }.joined()
                    return hex == dto.groupPublicKey && (chain == nil || w.chain == chain)
                }
                await MainActor.run {
                    SecureLog.debug("[join] reviewing dto session=\(dto.sessionId) amount=\(dto.amount) chain=\(dto.chain) expected=\(expectedCode ?? "nil")")
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
        // Prevent double-approve (button double-tap, SwiftUI re-render)
        // from spawning two SigningViewModels / two signingTasks that
        // would race on every incoming MPC packet.
        if case .signing = phase { return }
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
        phase = .signing(vm)
        // Cosigner path: wait for the initiator's `SignBeginDTO` before
        // entering MPC. Calling `startSigning()` directly here would emit
        // our round-1 messages before the initiator has subscribed to
        // the message stream, so their side would never receive them.
        vm.awaitInitiatorStart()

        // Fire a second presence ping, this one carrying our `partyIndex`,
        // so the initiator can map `peer.id → party` when it builds its
        // `participants` list for `bridge.startSigning`. Without this the
        // initiator would fall back to "smallest-unused-index" guessing
        // — fine for 2-of-2 but ambiguous for 3-of-N+.
        let sessionId = dto.sessionId
        let name = DeviceIdentity.displayName
        let partyIndex = wallet.partyIndex
        Task { [appState] in
            let confirm = SignPresenceDTO(
                sessionId: sessionId,
                deviceName: name,
                partyIndex: partyIndex
            )
            if let payload = try? JSONEncoder().encode(confirm) {
                try? await appState.peerManager.broadcastMpcMessage(payload)
            }
        }
    }

    private func cleanup() {
        listenerTask?.cancel()
        listenerTask = nil
        if let subId = listenerSubId {
            appState.peerManager.unsubscribeMpc(subId)
            listenerSubId = nil
        }
        // Only the browsing part stops; an already-established LAN
        // connection stays alive for any in-progress ceremony.
        appState.peerManager.wifiLAN.stopDiscovery()
        // Drop the relay room so we don't leak a second connection
        // with the same device_id on the next join attempt.
        appState.peerManager.leaveRelayRoom()
    }
}

/// Thin wrapper around `SigningProgressView` that observes the
/// cosigner's `SigningViewModel.step` and fires `onComplete` once the
/// ceremony finishes successfully. Without this, `JoinSigningView`
/// remains parked on the progress ring forever even after the MPC
/// bridge has produced a final signature on this side — because
/// `SigningProgressView` itself doesn't reflect `step` transitions.
private struct JoinSigningProgressBridge: View {
    @ObservedObject var viewModel: SigningViewModel
    let onComplete: () -> Void
    @State private var didFire = false

    var body: some View {
        SigningProgressView(viewModel: viewModel)
            .onChange(of: viewModel.step) { newStep in
                guard !didFire, newStep == .complete else { return }
                didFire = true
                Haptics.success()
                // Brief pause so the user sees the 100% ring + "done"
                // states before the sheet dismisses.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    onComplete()
                }
            }
    }
}

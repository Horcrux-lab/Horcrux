import SwiftUI

/// Sheet UI for proactive shard refresh. Pairs PIN unlock + peer-presence
/// gating with a live progress indicator while the CGGMP21 ceremony runs.
struct RefreshShardSheet: View {
    let wallet: Wallet
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var coord: RefreshShardCoordinator

    @State private var showPinPrompt = false
    @State private var showLongWaitHint = false

    /// Live timer + pool snapshot for the running-phase remaining label.
    /// Snapshot at ceremony start so later pool consumption doesn't flip
    /// the estimate mid-run.
    @State private var refreshElapsedSeconds: Int = 0
    @State private var refreshPrimePoolReady: Bool = false

    /// Transports to use for bringing the two devices into the same room.
    /// Mirrors the DKG flow: BLE + Wi-Fi LAN work out-of-the-box on the
    /// same network, Relay is the cross-network fallback (requires a
    /// shared 6-char room code the user types on both devices).
    @State private var selectedTransports: Set<TransportType> = [.ble, .wifiLAN]
    @State private var roomCode: String = ""
    /// Tracks whether we've already fired `startDiscovery` so re-renders
    /// don't double-announce (which can cause duplicate room presence).
    @State private var discoveryStarted = false

    init(wallet: Wallet, appState: AppState) {
        self.wallet = wallet
        _coord = StateObject(wrappedValue: RefreshShardCoordinator(
            wallet: wallet,
            appState: appState
        ))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                header

                phaseBody

                Spacer()

                buttons
            }
            .padding()
            .navigationTitle(L10n.Refresh.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.cancel) {
                        coord.cancel()
                        dismiss()
                    }
                }
            }
        }
        .sheet(isPresented: $showPinPrompt) {
            PinUnlockSheet(
                title: L10n.Refresh.pinTitle,
                subtitle: L10n.Refresh.pinMessage
            ) { pin in
                guard appState.verifyPin(pin) else {
                    return L10n.Refresh.pinIncorrect
                }
                guard let swk = appState.cachedShardKey() else {
                    return L10n.Refresh.pinIncorrect
                }
                coord.setShardKey(swk)
                DispatchQueue.main.async { coord.start() }
                return nil
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(HorcruxTheme.accentCyan)
            Text(L10n.Refresh.subtitle(shardDisplayName))
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(L10n.Refresh.explainer)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    /// Strip the chain suffix from the wallet name so the header names the
    /// shard (= DKG account) rather than any single-chain wallet. Rotation
    /// is account-level: one ceremony refreshes the key share shared by
    /// every chain derived from it.
    private var shardDisplayName: String {
        wallet.name
            .replacingOccurrences(of: " (\(wallet.chain.rawValue))", with: "")
            .replacingOccurrences(of: " (\(wallet.chain.symbol))", with: "")
    }

    @ViewBuilder
    private var phaseBody: some View {
        switch coord.phase {
        case .idle:
            VStack(spacing: 16) {
                statusRow(icon: "lock.shield", text: L10n.Refresh.idle, tint: .secondary)
                connectForm
            }
        case .waitingForPeer:
            VStack(spacing: 12) {
                statusRow(icon: "antenna.radiowaves.left.and.right",
                          text: L10n.Refresh.waitingPeer, tint: .yellow)
                if showLongWaitHint {
                    VStack(alignment: .leading, spacing: 6) {
                        Label {
                            Text(L10n.Refresh.waitingPeerHintTitle)
                                .font(.footnote.weight(.semibold))
                        } icon: {
                            Image(systemName: "lightbulb.fill")
                                .foregroundStyle(.yellow)
                        }
                        Text(L10n.Refresh.waitingPeerHintBody)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.yellow.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.yellow.opacity(0.25), lineWidth: 1))
                    .padding(.horizontal)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .task(id: String(describing: coord.phase)) {
                // Surface an actionable hint if the wait exceeds ~10s so
                // solo users understand rotation needs a second device that
                // has also started the same flow.
                showLongWaitHint = false
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if case .waitingForPeer = coord.phase {
                    withAnimation { showLongWaitHint = true }
                }
            }
        case .running:
            VStack(spacing: 12) {
                ProgressView(
                    value: Double(coord.roundsCompleted),
                    total: Double(coord.approxTotalRounds)
                )
                HStack {
                    Text(L10n.Refresh.runningRound(coord.roundsCompleted, coord.approxTotalRounds))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(refreshRemainingLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal)
            .task(id: String(describing: coord.phase)) {
                refreshElapsedSeconds = 0
                refreshPrimePoolReady = DkgEstimate.primePoolReady(
                    for: Int(wallet.totalParties)
                )
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if case .running = coord.phase {
                        refreshElapsedSeconds += 1
                    } else { break }
                }
            }
        case .persisting:
            statusRow(icon: "lock.rotation", text: L10n.Refresh.persisting, tint: .blue)
        case .complete:
            statusRow(icon: "checkmark.seal.fill", text: L10n.Refresh.complete, tint: .green)
        case .error(let msg):
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(L10n.Refresh.errorTitle)
                        .font(.headline)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.red.opacity(0.08)))
        }
    }

    private func statusRow(icon: String, text: String, tint: Color) -> some View {
        Label {
            Text(text).font(.subheadline)
        } icon: {
            Image(systemName: icon).foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
    }

    /// Dynamic estimate derived from wallet party count + pool readiness
    /// snapshot. Counts down in real time; once the estimate is exceeded
    /// we fall back to the generic "wrapping up" string rather than lying
    /// with "0s" while CGGMP21 is still finalising.
    private var refreshRemainingLabel: String {
        let total = DkgEstimate.refreshSeconds(
            totalParties: Int(wallet.totalParties),
            primePoolReady: refreshPrimePoolReady
        )
        let remaining = total - refreshElapsedSeconds
        if remaining > 0 { return "~\(remaining)s" }
        return L10n.DKG.wrappingUp
    }

    /// Transport + room-code picker shown before the ceremony starts.
    /// Mirrors the Create Shard / Join flow so both devices can bring
    /// themselves into the same room before hitting "Start now".
    @ViewBuilder
    private var connectForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(L10n.Refresh.connectTitle)
                    .font(.subheadline.weight(.semibold))
                InfoHint(title: L10n.Refresh.connectTitle,
                         body: L10n.Refresh.connectHint)
                Spacer()
            }

            ForEach(TransportType.allCases) { t in
                Toggle(isOn: Binding(
                    get: { selectedTransports.contains(t) },
                    set: { on in
                        if on { selectedTransports.insert(t) }
                        else { selectedTransports.remove(t) }
                    }
                )) {
                    Label(t.rawValue, systemImage: t.iconName)
                        .font(.subheadline)
                }
            }

            if selectedTransports.contains(.relay) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.CreateShard.roomCodeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        TextField(L10n.CreateShard.roomCodePlaceholder, text: $roomCode)
                            .font(.system(.body, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onChange(of: roomCode) { _, newValue in
                                let normalized = RoomCode.normalize(newValue)
                                if normalized != newValue { roomCode = normalized }
                            }
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
                    Text(L10n.Refresh.roomCodeHint)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
    }

    /// True once the user has configured a valid transport combo.
    private var canStartRotation: Bool {
        guard !selectedTransports.isEmpty else { return false }
        if selectedTransports.contains(.relay) && !RoomCode.isValid(roomCode) {
            return false
        }
        return true
    }

    /// Kick off PeerManager discovery for the transports the user picked.
    /// Idempotent — safe to call on every Start tap.
    private func beginDiscoveryIfNeeded() {
        guard !discoveryStarted else { return }
        discoveryStarted = true
        appState.peerManager.startDiscovery(transports: selectedTransports)
        if selectedTransports.contains(.relay) && RoomCode.isValid(roomCode) {
            Task {
                try? await appState.peerManager.joinRelayRoom(roomId: roomCode)
                appState.peerManager.relay.startDiscovery()
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch coord.phase {
        case .idle, .waitingForPeer, .error:
            Button {
                beginDiscoveryIfNeeded()
                if let swk = appState.cachedShardKey() {
                    coord.setShardKey(swk)
                    coord.start()
                } else {
                    showPinPrompt = true
                }
            } label: {
                Text(L10n.Refresh.startButton)
                    .frame(maxWidth: .infinity)
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .disabled(coord.phase == .idle && !canStartRotation)
        case .running, .persisting:
            ProgressView().frame(maxWidth: .infinity)
        case .complete:
            Button {
                dismiss()
            } label: {
                Text(L10n.Common.done)
                    .frame(maxWidth: .infinity)
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
        }
    }

}

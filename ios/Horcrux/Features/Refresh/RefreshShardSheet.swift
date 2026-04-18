import SwiftUI

/// Sheet UI for proactive shard refresh. Pairs PIN unlock + peer-presence
/// gating with a live progress indicator while the CGGMP21 ceremony runs.
struct RefreshShardSheet: View {
    let wallet: Wallet
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var coord: RefreshShardCoordinator

    @State private var showPinPrompt = false
    @State private var pin = ""
    @State private var pinError: String?

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
        .alert(L10n.Refresh.pinTitle, isPresented: $showPinPrompt) {
            SecureField(L10n.Common.pin, text: $pin)
                .keyboardType(.numberPad)
            Button(L10n.Refresh.unlock) { performUnlockAndStart() }
            Button(L10n.Common.cancel, role: .cancel) { pin = "" }
        } message: {
            if let pinError {
                Text(pinError)
            } else {
                Text(L10n.Refresh.pinMessage)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(HorcruxTheme.accentCyan)
            Text(L10n.Refresh.subtitle(wallet.name))
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(L10n.Refresh.explainer)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    @ViewBuilder
    private var phaseBody: some View {
        switch coord.phase {
        case .idle:
            statusRow(icon: "lock.shield", text: L10n.Refresh.idle, tint: .secondary)
        case .waitingForPeer:
            statusRow(icon: "antenna.radiowaves.left.and.right",
                      text: L10n.Refresh.waitingPeer, tint: .yellow)
        case .running:
            VStack(spacing: 12) {
                ProgressView(
                    value: Double(coord.roundsCompleted),
                    total: Double(coord.approxTotalRounds)
                )
                Text(L10n.Refresh.runningRound(coord.roundsCompleted, coord.approxTotalRounds))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
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

    @ViewBuilder
    private var buttons: some View {
        switch coord.phase {
        case .idle, .waitingForPeer, .error:
            Button {
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

    private func performUnlockAndStart() {
        guard appState.verifyPin(pin) else {
            pinError = L10n.Refresh.pinIncorrect
            pin = ""
            showPinPrompt = true
            return
        }
        guard let swk = appState.cachedShardKey() else {
            pinError = L10n.Refresh.pinIncorrect
            pin = ""
            showPinPrompt = true
            return
        }
        coord.setShardKey(swk)
        pin = ""
        coord.start()
    }
}

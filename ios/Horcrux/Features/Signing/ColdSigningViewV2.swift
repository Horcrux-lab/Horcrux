import SwiftUI
import CoreImage

/// View for the v2 (≥3 parties) cold-signing ceremony. Drives
/// `ColdSigningCoordinatorV2`. See that file for protocol details.
///
/// Currently labelled "experimental" in the UI because this path has
/// only been exercised by the state-machine logic; the 3-device live
/// dress rehearsal is still pending. Do not remove the beta badge
/// until at least one 3-of-3 ETH tx has been signed end-to-end.
struct ColdSigningViewV2: View {
    let wallet: Wallet
    let messageHash: Data?
    let shardData: Data
    let initialRole: ColdSigningCoordinatorV2.Role?

    @StateObject private var coordinator: ColdSigningCoordinatorV2
    @Environment(\.dismiss) private var dismiss

    @State private var showingScanner = false
    @State private var pickedRole: ColdSigningCoordinatorV2.Role?

    init(
        wallet: Wallet,
        messageHash: Data?,
        shardData: Data,
        bridge: HorcruxBridge,
        initialRole: ColdSigningCoordinatorV2.Role? = nil
    ) {
        self.wallet = wallet
        self.messageHash = messageHash
        self.shardData = shardData
        self.initialRole = initialRole
        _coordinator = StateObject(wrappedValue: ColdSigningCoordinatorV2(bridge: bridge))
    }

    var body: some View {
        NavigationStack {
            Group {
                if pickedRole == nil {
                    rolePicker
                } else {
                    ceremony
                }
            }
            .padding()
            .navigationTitle(L10n.ColdSignV2.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.close) { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    Text(L10n.ColdSignV2.experimentalBadge)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.orange.opacity(0.2)))
                        .foregroundStyle(.orange)
                }
            }
            .sheet(isPresented: $showingScanner) {
                QRScannerSheet { payload in
                    showingScanner = false
                    coordinator.handleScanned(payload)
                }
            }
            .onAppear {
                if pickedRole == nil, let r = initialRole {
                    start(as: r)
                }
            }
        }
    }

    // MARK: - Role picker

    private var rolePicker: some View {
        VStack(spacing: 16) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text(L10n.ColdSign.rolePrompt)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(L10n.ColdSignV2.intro)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                roleCard(
                    title: L10n.ColdSign.roleInitiator,
                    subtitle: L10n.ColdSign.roleInitiatorHint,
                    systemImage: "paperplane.fill",
                    enabled: messageHash != nil
                ) { start(as: .initiator) }

                roleCard(
                    title: L10n.ColdSign.roleCosigner,
                    subtitle: L10n.ColdSign.roleCosignerHint,
                    systemImage: "qrcode.viewfinder"
                ) { start(as: .cosigner) }
            }
            Spacer()
        }
    }

    private func roleCard(
        title: String,
        subtitle: String,
        systemImage: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 12).fill(.thinMaterial))
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func start(as role: ColdSigningCoordinatorV2.Role) {
        pickedRole = role
        do {
            switch role {
            case .initiator:
                guard let msg = messageHash else {
                    throw ColdSigningCoordinator.ColdError.noSignatureProduced
                }
                // For MVP, assume all parties participate (t == n-of-n).
                let participants: [UInt16] = (1...wallet.totalParties).map { UInt16($0) }
                try coordinator.startAsInitiator(
                    wallet: wallet,
                    messageHash: msg,
                    shardData: shardData,
                    participants: participants
                )
            case .cosigner:
                try coordinator.startAsCosigner(wallet: wallet, shardData: shardData)
            }
        } catch {
            SecureLog.error("Cold v2 init failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Ceremony

    private var ceremony: some View {
        VStack(spacing: 20) {
            header
            Divider()
            content
            Spacer()
            footer
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .foregroundStyle(.orange)
                Text(L10n.ColdSign.offlineMode).font(.headline)
                Spacer()
                Text(coordinator.stepDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
            Text(L10n.ColdSignV2.intro)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.phase {
        case .showing:
            qrDisplay
        case .awaitingScan:
            scannerPrompt
        case .complete:
            completeView
        case .failed:
            errorView
        case .idle:
            ProgressView(L10n.ColdSign.initializing)
        }
    }

    private var qrDisplay: some View {
        VStack(spacing: 12) {
            if let payload = coordinator.currentQRPayload,
               let img = generateRawQR(base64Bytes: payload) {
                Image(decorative: img, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 320, maxHeight: 320)
                    .padding(8)
                    .background(.white)
                    .cornerRadius(12)
            } else {
                Text(L10n.ColdSign.generatingQR).foregroundStyle(.secondary)
            }
        }
    }

    private func generateRawQR(base64Bytes: Data) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(base64Bytes, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ci = filter.outputImage else { return nil }
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }

    private var scannerPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
            Text(coordinator.stepDescription)
                .multilineTextAlignment(.center)
            Button {
                showingScanner = true
            } label: {
                Label(L10n.ColdSign.scanPeer, systemImage: "camera.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var completeView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text(L10n.ColdSignV2.signatureReady)
                .font(.title3.weight(.semibold))
            if let sig = coordinator.finalSignature {
                Text(L10n.ColdSign.sigLength(sig.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    SecureClipboard.copy(sig.map { String(format: "%02x", $0) }.joined())
                } label: {
                    Label(L10n.ColdSign.copyHex, systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var errorView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text(coordinator.errorMessage ?? L10n.ColdSign.unknownError)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch coordinator.phase {
        case .showing:
            Button(L10n.ColdSign.readyToScan) {
                coordinator.readyToScan()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        default:
            EmptyView()
        }
    }
}

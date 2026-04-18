import SwiftUI
import CoreImage

/// 冷签名（离线 QR 链式签名）入口 — 2-of-2 专用。
///
/// dev.50 起同时支持 **initiator / cosigner** 两种角色：两台设备上都
/// 打开本视图，一台选「发起方」、一台选「协签方」，通过 4 张二维码
/// 轮流交换即可完成签名，全程飞行模式、无任何网络。
///
/// 设计目标：在不信任任何中继、不暴露任何网络请求的前提下，
/// 仍能完成阈值签名 —— 适用于高价值 / 受监控环境下的冷钱包。
struct ColdSigningView: View {
    let wallet: Wallet
    /// Initiator 必填；cosigner 会等 invite QR 里的 hash 到达。
    let messageHash: Data?
    let shardData: Data
    /// 预设角色。为 nil 时先弹出角色选择页，让用户决定。
    let initialRole: ColdSigningCoordinator.Role?

    @EnvironmentObject private var appState: AppState
    @StateObject private var coordinator: ColdSigningCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var showingScanner = false
    @State private var pickedRole: ColdSigningCoordinator.Role?

    init(
        wallet: Wallet,
        messageHash: Data?,
        shardData: Data,
        bridge: HorcruxBridge,
        initialRole: ColdSigningCoordinator.Role? = nil
    ) {
        self.wallet = wallet
        self.messageHash = messageHash
        self.shardData = shardData
        self.initialRole = initialRole
        _coordinator = StateObject(wrappedValue: ColdSigningCoordinator(bridge: bridge))
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
            .navigationTitle(L10n.ColdSign.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.close) { dismiss() }
                }
            }
            .sheet(isPresented: $showingScanner) {
                QRScannerSheet { payload in
                    showingScanner = false
                    coordinator.handleScanned(payload)
                }
            }
            .onAppear {
                // A caller that knows the role up-front (e.g. a signing
                // flow that already chose initiator) can skip the picker.
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

    private func start(as role: ColdSigningCoordinator.Role) {
        pickedRole = role
        do {
            switch role {
            case .initiator:
                guard let msg = messageHash else {
                    throw ColdSigningCoordinator.ColdError.noSignatureProduced
                }
                try coordinator.startAsInitiator(
                    wallet: wallet,
                    messageHash: msg,
                    shardData: shardData
                )
            case .cosigner:
                try coordinator.startAsCosigner(
                    wallet: wallet,
                    shardData: shardData
                )
            }
        } catch {
            SecureLog.error("Cold signing init failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Ceremony

    private var ceremony: some View {
        VStack(spacing: 20) {
            header
            Divider()
            content
            Spacer()
            footerActions
        }
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .foregroundStyle(.orange)
                Text(L10n.ColdSign.offlineMode)
                    .font(.headline)
                Spacer()
                Text(stepLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(L10n.ColdSign.intro)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var stepLabel: String {
        switch coordinator.phase {
        case .idle: return L10n.ColdSign.stepPrep
        // initiator
        case .showingInvite: return L10n.ColdSign.step1of4
        case .awaitingRound1: return L10n.ColdSign.step2of4
        case .showingRound2: return L10n.ColdSign.step3of4
        case .awaitingRound2: return L10n.ColdSign.step4of4
        // cosigner
        case .awaitingInvite: return L10n.ColdSign.cosignerStep1of3
        case .showingCosignerRound1: return L10n.ColdSign.cosignerStep2of3
        case .awaitingInitiatorRound2: return L10n.ColdSign.cosignerStep2of3
        case .showingCosignerRound2: return L10n.ColdSign.cosignerStep3of3
        case .complete: return L10n.ColdSign.stepComplete
        case .failed: return L10n.ColdSign.stepFailed
        }
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.phase {
        case .showingInvite, .showingRound2,
             .showingCosignerRound1, .showingCosignerRound2:
            qrDisplay
        case .awaitingRound1, .awaitingRound2,
             .awaitingInvite, .awaitingInitiatorRound2:
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
            Text(qrGuidance)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // Coordinator already emits a base64 blob; hand it straight to the
    // CIFilter so we don't re-encode (which would bloat the QR).
    private func generateRawQR(base64Bytes: Data) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(base64Bytes, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ci = filter.outputImage else { return nil }
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }

    private var qrGuidance: String {
        switch coordinator.phase {
        case .showingInvite:
            return L10n.ColdSign.guideInvite
        case .showingRound2:
            return L10n.ColdSign.guideRound2
        case .showingCosignerRound1:
            return L10n.ColdSign.guideCosignerRound1
        case .showingCosignerRound2:
            return L10n.ColdSign.guideCosignerRound2
        default:
            return ""
        }
    }

    private var scannerPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
            Text(scannerGuidance)
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

    private var scannerGuidance: String {
        switch coordinator.phase {
        case .awaitingRound1: return L10n.ColdSign.promptRound1
        case .awaitingRound2: return L10n.ColdSign.promptRound2
        case .awaitingInvite: return L10n.ColdSign.promptInvite
        case .awaitingInitiatorRound2: return L10n.ColdSign.promptInitiatorRound2
        default: return ""
        }
    }

    private var completeView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text(coordinator.role == .cosigner
                 ? L10n.ColdSign.cosignerComplete
                 : L10n.ColdSign.signSuccess)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
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
            if coordinator.role == .initiator {
                Text(L10n.ColdSign.sendBack)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
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
    private var footerActions: some View {
        switch coordinator.phase {
        case .showingInvite, .showingRound2,
             .showingCosignerRound1, .showingCosignerRound2:
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

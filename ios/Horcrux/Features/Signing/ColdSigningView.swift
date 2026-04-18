import SwiftUI
import CoreImage

/// 冷签名（离线 QR 链式签名）入口 — 实验性。
///
/// 目前仅支持 **2-of-2 钱包** 的发起方（initiator）流程。
/// 对端（cosigner）的状态机在 dev.40 发布，届时两台设备都运行
/// 本视图即可在完全离线（飞行模式 / 断网）的环境完成签名。
///
/// 设计目标：在不信任任何中继、不暴露任何网络请求的前提下，
/// 仍能完成阈值签名 —— 适用于高价值 / 受监控环境下的冷钱包。
struct ColdSigningView: View {
    let wallet: Wallet
    let messageHash: Data
    let shardData: Data

    @EnvironmentObject private var appState: AppState
    @StateObject private var coordinator: ColdSigningCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var showingScanner = false

    init(wallet: Wallet, messageHash: Data, shardData: Data, bridge: HorcruxBridge) {
        self.wallet = wallet
        self.messageHash = messageHash
        self.shardData = shardData
        _coordinator = StateObject(wrappedValue: ColdSigningCoordinator(bridge: bridge))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                header
                Divider()
                content
                Spacer()
                footerActions
            }
            .padding()
            .navigationTitle("冷签名（实验）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .sheet(isPresented: $showingScanner) {
                QRScannerSheet { payload in
                    showingScanner = false
                    coordinator.handleScanned(payload)
                }
            }
            .task {
                do {
                    try coordinator.startAsInitiator(
                        wallet: wallet,
                        messageHash: messageHash,
                        shardData: shardData
                    )
                } catch {
                    // errorMessage already set by coordinator
                    SecureLog.error("Cold signing init failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .foregroundStyle(.orange)
                Text("离线模式")
                    .font(.headline)
                Spacer()
                Text(stepLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("在两台设备间轮流扫描二维码完成签名，全程不依赖中继。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var stepLabel: String {
        switch coordinator.phase {
        case .idle: return "准备中"
        case .showingInvite: return "第 1/4 步"
        case .awaitingRound1: return "第 2/4 步"
        case .showingRound2: return "第 3/4 步"
        case .awaitingRound2: return "第 4/4 步"
        case .complete: return "完成"
        case .failed: return "错误"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.phase {
        case .showingInvite, .showingRound2:
            qrDisplay
        case .awaitingRound1, .awaitingRound2:
            scannerPrompt
        case .complete:
            completeView
        case .failed:
            errorView
        case .idle:
            ProgressView("初始化…")
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
                Text("正在生成二维码…").foregroundStyle(.secondary)
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
            return "让另一台 Horcrux 扫描此码，它会生成一个回传码供你扫描。"
        case .showingRound2:
            return "让另一台设备扫描此码，它会产生最终签名回传码。"
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
                Label("扫描对端二维码", systemImage: "camera.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var scannerGuidance: String {
        switch coordinator.phase {
        case .awaitingRound1: return "请扫描对端设备产生的第 1 轮回传码。"
        case .awaitingRound2: return "请扫描对端设备产生的第 2 轮回传码。"
        default: return ""
        }
    }

    private var completeView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("签名成功")
                .font(.title3.weight(.semibold))
            if let sig = coordinator.finalSignature {
                Text("长度：\(sig.count) bytes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    SecureClipboard.copy(sig.map { String(format: "%02x", $0) }.joined())
                } label: {
                    Label("复制签名（hex）", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
            }
            Text("将签名回传至需广播该交易的设备完成上链。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var errorView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text(coordinator.errorMessage ?? "未知错误")
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var footerActions: some View {
        switch coordinator.phase {
        case .showingInvite, .showingRound2:
            Button("对方已扫完，轮到我扫码") {
                coordinator.readyToScan()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        default:
            EmptyView()
        }
    }
}

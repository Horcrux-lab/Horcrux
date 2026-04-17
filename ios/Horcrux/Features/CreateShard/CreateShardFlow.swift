import SwiftUI
import CoreImage.CIFilterBuiltins
import UIKit

/// Multi-step flow for creating a new MPC wallet (DKG ceremony).
struct CreateShardFlow: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = CreateShardViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.step {
                case .configure:
                    ConfigureView(viewModel: viewModel)
                case .discover:
                    PeerDiscoveryView(viewModel: viewModel)
                case .dkg:
                    DKGProgressView(viewModel: viewModel)
                case .complete:
                    DKGCompleteView(viewModel: viewModel, dismiss: dismiss)
                case .error:
                    DKGErrorView(viewModel: viewModel)
                }
            }
            .navigationTitle(L10n.CreateShard.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.cancel) { dismiss() }
                        .accessibilityIdentifier("createShard_cancelButton")
                }
            }
            .environmentObject(appState)
            .onAppear {
                viewModel.bind(to: appState)
            }
        }
    }
}

// MARK: - Step 1: Configure

struct ConfigureView: View {
    @ObservedObject var viewModel: CreateShardViewModel
    @State private var showAdvanced = false
    @State private var showExplainer = false
    @State private var showQRScanner = false

    var body: some View {
        Form {
            // Value-prop header (item 2: convey MPC core value)
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "shield.lefthalf.filled")
                            .foregroundStyle(.green)
                        Text("门限签名钱包")
                            .font(.headline)
                        Spacer()
                        Button {
                            showExplainer = true
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .accessibilityLabel("什么是门限签名")
                    }
                    Text("无需助记词。密钥分成 \(viewModel.totalParties) 片分发到不同设备，任意 \(viewModel.threshold) 片即可签名 —— 丢失任一设备仍可恢复。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section(L10n.CreateShard.walletName) {
                TextField(L10n.CreateShard.walletNamePlaceholder, text: $viewModel.walletName)
                    .accessibilityLabel(L10n.CreateShard.walletNameAccessibility)
                    .accessibilityHint(L10n.CreateShard.walletNameHint)
                    .accessibilityIdentifier("configure_walletNameField")
            }

            Section(L10n.CreateShard.blockchain) {
                Picker(L10n.CreateShard.chain, selection: $viewModel.selectedCurve) {
                    Text("EVM 链 + Bitcoin")
                        .tag(FfiCurveType.secp256k1)
                    Text("Solana")
                        .tag(FfiCurveType.ed25519)
                }
                .pickerStyle(.inline)

                Text(viewModel.selectedCurve == .secp256k1
                     ? "将生成：ETH · BTC 地址（共享同一密钥分片）"
                     : "将生成：SOL 地址")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Advanced settings (item 1: reduce cognitive load)
            Section {
                DisclosureGroup("高级设置", isExpanded: $showAdvanced) {
                    advancedThresholdStepper
                    advancedTransportToggles
                }
            } footer: {
                if !showAdvanced {
                    Text("默认：2-of-3 · 通过中继服务器发现设备 · 房间码已自动生成")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    viewModel.step = .discover
                    viewModel.startDiscovery()
                } label: {
                    Text(L10n.CreateShard.nextFindPeers)
                        .frame(maxWidth: .infinity)
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.walletName.isEmpty || (viewModel.selectedTransports.contains(.relay) && viewModel.roomCode.isEmpty))
                .accessibilityHint(L10n.CreateShard.findPeersHint)
                .accessibilityIdentifier("configure_nextButton")
            }
        }
        .sheet(isPresented: $showExplainer) {
            MPCExplainerSheet()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showQRScanner) {
            RoomCodeScanSheet { scanned in
                let parsed = scanned.hasPrefix("horcrux-room:")
                    ? String(scanned.dropFirst("horcrux-room:".count))
                    : scanned
                let normalized = RoomCode.normalize(parsed)
                if RoomCode.isValid(normalized) {
                    viewModel.roomCode = normalized
                }
                showQRScanner = false
            }
        }
    }

    @ViewBuilder
    private var advancedThresholdStepper: some View {
        Stepper(L10n.CreateShard.totalParties(viewModel.totalParties),
                value: $viewModel.totalParties, in: 2...10)
        Stepper(L10n.CreateShard.signingThreshold(viewModel.threshold),
                value: $viewModel.threshold, in: 2...viewModel.totalParties)

        Text(L10n.CreateShard.requiresDevices(viewModel.threshold, viewModel.totalParties))
            .font(.caption)
            .foregroundStyle(.secondary)

        if viewModel.totalParties == 3 && viewModel.threshold == 2 {
            Label {
                Text("推荐：3 台生成，任意 2 台即可签名。")
                    .font(.caption)
            } icon: {
                Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
            }
        } else if viewModel.totalParties == viewModel.threshold {
            Label {
                Text("警告：\(viewModel.threshold)-of-\(viewModel.totalParties) 无冗余，任一设备丢失将永久失去钱包。")
                    .font(.caption)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var advancedTransportToggles: some View {
        ForEach(TransportType.allCases) { transport in
            Toggle(isOn: Binding(
                get: { viewModel.selectedTransports.contains(transport) },
                set: { enabled in
                    if enabled {
                        viewModel.selectedTransports.insert(transport)
                    } else {
                        viewModel.selectedTransports.remove(transport)
                    }
                }
            )) {
                Label(transport.rawValue, systemImage: transport.iconName)
            }
        }

        if viewModel.selectedTransports.contains(.relay) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("中继服务器")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(RelayConfig.effectiveURL)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text("如需更改服务器地址，前往 设置 → 中继服务器")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Text("房间码（3 个单词）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

                HStack {
                    TextField("apple-tiger-moon", text: $viewModel.roomCode)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("configure_roomCodeField")
                        .onChange(of: viewModel.roomCode) { _, newValue in
                            let normalized = RoomCode.normalize(newValue)
                            if normalized != newValue {
                                viewModel.roomCode = normalized
                            }
                        }
                    Button {
                        viewModel.roomCode = RoomCode.generate()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("生成新房间码")

                    Button {
                        showQRScanner = true
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("扫码加入房间")
                    .accessibilityIdentifier("configure_scanRoomCodeButton")

                    Button {
                        SecureClipboard.copy(viewModel.roomCode)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("复制房间码")
                }

                if RoomCode.isValid(viewModel.roomCode) {
                    HStack {
                        Spacer()
                        RoomCodeQRView(code: viewModel.roomCode)
                            .frame(width: 140, height: 140)
                        Spacer()
                    }
                    .padding(.top, 4)
                    Text("让对方扫码即可快速输入房间码")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else if !viewModel.roomCode.isEmpty {
                    Text("房间码应为 3 个用连字符分隔的单词")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

/// Sheet wrapping QRScannerView with a cancel button.
private struct RoomCodeScanSheet: View {
    let onScan: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            QRScannerView(onScan: onScan)
                .ignoresSafeArea()
                .navigationTitle("扫描房间码")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.Common.cancel) { dismiss() }
                    }
                }
        }
    }
}

/// Generates a QR code for a room code so peers can scan to join.
private struct RoomCodeQRView: View {
    let code: String

    var body: some View {
        if let image = generate(code) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .background(Color.white)
                .cornerRadius(6)
        } else {
            Image(systemName: "qrcode")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
        }
    }

    private func generate(_ text: String) -> UIImage? {
        let data = Data("horcrux-room:\(text)".utf8)
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ci = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// Explainer sheet — surfaces the "why" of MPC threshold signing.
private struct MPCExplainerSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    explainerRow(
                        icon: "xmark.seal.fill",
                        color: .red,
                        title: "无助记词",
                        body: "传统钱包依赖 12/24 个助记词，写在纸上一旦泄露 = 钱包丢失。Horcrux 不生成助记词，无法被拍照、偷看或钓鱼。"
                    )
                    explainerRow(
                        icon: "rectangle.split.3x1.fill",
                        color: .blue,
                        title: "密钥分片",
                        body: "DKG（分布式密钥生成）算法让每台设备只持有部分密钥。任何单台设备被攻破都不会泄露完整私钥。"
                    )
                    explainerRow(
                        icon: "checkmark.shield.fill",
                        color: .green,
                        title: "丢设备也能恢复",
                        body: "2-of-3 配置下，任何 2 台设备即可签名。丢失 1 台，用剩下 2 台签发交易，把资产转到新钱包。"
                    )
                    explainerRow(
                        icon: "link.circle.fill",
                        color: .purple,
                        title: "一次 DKG，多链共享",
                        body: "secp256k1 曲线一次生成即可同时用于 ETH 与 BTC 地址，无需重复创建。"
                    )
                }
                .padding()
            }
            .navigationTitle("什么是门限签名？")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func explainerRow(icon: String, color: Color, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(body).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Step 2: Peer Discovery

struct PeerDiscoveryView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var viewModel: CreateShardViewModel
    private let totalTimeout = 60
    @State private var timeRemaining = 60
    @State private var timerTask: Task<Void, Never>?

    private var progress: Double {
        let needed = max(viewModel.totalParties - 1, 1)
        return min(Double(viewModel.foundPeers.count) / Double(needed), 1.0)
    }

    var body: some View {
        VStack(spacing: 20) {
            // Ring shows % of peers discovered; countdown is adjacent (no overlap).
            HStack(spacing: 24) {
                ProgressRing(progress: progress)
                    .frame(width: 100, height: 100)

                VStack(spacing: 2) {
                    Text("\(timeRemaining)")
                        .font(.system(size: 44, weight: .bold, design: .monospaced))
                        .foregroundStyle(timeRemaining < 15 ? Color.red : Color.primary)
                    Text("秒后超时")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()

            Text(L10n.Discovery.lookingForDevices)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .foregroundStyle(HorcruxTheme.accentCyan)
                Text("My ID: \(viewModel.localPeerId)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(HorcruxTheme.accentCyan)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(HorcruxTheme.accentCyan.opacity(0.1), in: Capsule())

            Text(L10n.Discovery.peersFound(viewModel.foundPeers.count, viewModel.totalParties - 1))
                .font(.headline)
                .accessibilityLabel(L10n.Discovery.peersFoundAccessibility(viewModel.foundPeers.count, viewModel.totalParties - 1))

            List(viewModel.foundPeers) { peer in
                HStack {
                    Image(systemName: "person.circle.fill")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading) {
                        Text(peer.name)
                            .font(.headline)
                        Text("\(peer.channel) · \(String(peer.id.prefix(8)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            if viewModel.foundPeers.count >= viewModel.totalParties - 1 {
                Button {
                    timerTask?.cancel()
                    viewModel.startDKG()
                } label: {
                    Text(L10n.Discovery.startKeyGeneration)
                        .frame(maxWidth: .infinity)
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
                .accessibilityHint(L10n.Discovery.startKeyGenHint)
                .accessibilityIdentifier("discover_startDKGButton")
            } else {
                Text("提示：另一台设备需在同一房间码下开启创建流程")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Button(L10n.Common.cancel, role: .cancel) {
            }
            .foregroundStyle(.secondary)
        }
        .padding()
        .onAppear {
            timeRemaining = totalTimeout
            timerTask = Task {
                while timeRemaining > 0 && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    timeRemaining -= 1
                }
                if timeRemaining <= 0 && !Task.isCancelled {
                    viewModel.errorMessage = L10n.DKG.peerTimeout
                    viewModel.step = .error
                }
            }
        }
        .onDisappear {
            timerTask?.cancel()
        }
    }
}

// MARK: - Step 3: DKG Progress

struct DKGProgressView: View {
    @ObservedObject var viewModel: CreateShardViewModel
    @State private var elapsedSeconds = 0
    @State private var elapsedTask: Task<Void, Never>?

    private var estimatedTotal: Int {
        viewModel.selectedCurve == .ed25519 ? 15 : 45
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ProgressRing(progress: viewModel.dkgProgress)
                .frame(width: 120, height: 120)
                .accessibilityLabel(L10n.DKG.keyGenProgress)
                .accessibilityValue("\(Int(viewModel.dkgProgress * 100)) percent")

            VStack(spacing: 8) {
                Text(L10n.DKG.generatingKeyShards)
                    .font(.title2.bold())

                Text(viewModel.dkgStatusMessage)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Text(L10n.DKG.roundOf(viewModel.currentRound, viewModel.totalRounds))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityLabel(L10n.DKG.keyGenRound(viewModel.currentRound, viewModel.totalRounds))

            // Elapsed timer (item 12: no feedback during 40s keygen)
            HStack(spacing: 16) {
                VStack {
                    Text("\(elapsedSeconds)s")
                        .font(.headline.monospacedDigit())
                    Text("已用时").font(.caption2).foregroundStyle(.secondary)
                }
                Divider().frame(height: 30)
                VStack {
                    Text("~\(max(estimatedTotal - elapsedSeconds, 0))s")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("预计剩余").font(.caption2).foregroundStyle(.secondary)
                }
            }

            if viewModel.selectedCurve == .secp256k1 &&
               viewModel.currentRound >= 3 && viewModel.currentRound <= 5 {
                Label("第 3-5 步计算 Paillier 同态密钥，为整个流程最耗时阶段", systemImage: "lightbulb.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
                    .padding(.horizontal)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            Text(L10n.DKG.keepDevicesNearby)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(L10n.DKG.cancelCeremony, role: .destructive) {
                viewModel.cancel()
            }
            .font(.caption)
            .padding(.bottom)
        }
        .padding()
        .onAppear {
            elapsedSeconds = 0
            elapsedTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    elapsedSeconds += 1
                }
            }
        }
        .onDisappear { elapsedTask?.cancel() }
    }
}

// MARK: - Step 4: Complete

struct DKGCompleteView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var viewModel: CreateShardViewModel
    let dismiss: DismissAction
    @State private var pin = ""
    @State private var showPinPrompt = false
    @State private var pinError: String?
    @ScaledMetric(relativeTo: .largeTitle) private var successIconSize: CGFloat = 72

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: successIconSize))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(L10n.DKG.walletCreated)
                    .font(.title.bold())

                ForEach(viewModel.generatedAddresses, id: \.chain) { entry in
                    HStack(spacing: 6) {
                        ChainIcon(chain: entry.chain, size: 20)
                        Text(entry.address)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .textSelection(.enabled)
                    .padding(.horizontal)
                }
            }

            VStack(spacing: 4) {
                Text(L10n.DKG.yourShardIs(viewModel.partyIndex))
                    .font(.headline)
                Text(L10n.DKG.thresholdOf(viewModel.threshold, viewModel.totalParties))
                    .foregroundStyle(.secondary)
            }

            // Backup nudge (item 6)
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text("下一步：立即备份分片").font(.subheadline.bold())
                } icon: {
                    Image(systemName: "icloud.and.arrow.up").foregroundStyle(.blue)
                }
                Text("保存分片后，前往「分片」页导出到 iCloud Drive 或加密文件，丢失设备时可从备份恢复。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.1)))
            .padding(.horizontal)

            Spacer()

            Button {
                showPinPrompt = true
            } label: {
                Text(L10n.DKG.saveEncryptShard)
                    .frame(maxWidth: .infinity)
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
            .accessibilityHint(L10n.DKG.saveEncryptHint)
            .accessibilityIdentifier("dkgComplete_saveButton")
        }
        .padding()
        .alert(L10n.DKG.enterPinEncrypt, isPresented: $showPinPrompt) {
            SecureField(L10n.Common.pin, text: $pin)
                .keyboardType(.numberPad)
            Button(L10n.DKG.encryptSave) {
                guard appState.verifyPin(pin) else {
                    pinError = L10n.DKG.incorrectPin
                    return
                }
                viewModel.saveWallet(to: appState, pin: pin)
                pin = ""
                dismiss()
            }
            Button(L10n.Common.cancel, role: .cancel) { pin = "" }
        } message: {
            if let pinError {
                Text(pinError)
            } else {
                Text(L10n.DKG.pinNeededEncrypt)
            }
        }
    }
}

// MARK: - Error

struct DKGErrorView: View {
    @ObservedObject var viewModel: CreateShardViewModel
    @ScaledMetric(relativeTo: .largeTitle) private var errorIconSize: CGFloat = 64

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: errorIconSize))
                .foregroundStyle(.red)
                .accessibilityHidden(true)

            Text(L10n.DKG.keyGenFailed)
                .font(.title2.bold())

            Text(viewModel.errorMessage)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(L10n.Common.retry) {
                viewModel.step = .discover
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint(L10n.DKG.retryHint)
            .accessibilityIdentifier("dkgError_retryButton")

            Spacer()
        }
        .padding()
    }
}

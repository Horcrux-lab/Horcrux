import SwiftUI
import CoreImage.CIFilterBuiltins
import UIKit

/// Multi-step flow for creating a new MPC wallet (DKG ceremony).
struct CreateShardFlow: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = CreateShardViewModel()
    @Environment(\.dismiss) private var dismiss

    private var stepIndex: Int {
        switch viewModel.step {
        case .configure: return 0
        case .discover: return 1
        case .dkg: return 2
        case .complete, .error: return 3
        }
    }

    private var stepLabels: [String] {
        [
            L10n.CreateShard.stepConfigure,
            L10n.CreateShard.stepDiscover,
            L10n.CreateShard.stepGenerate,
            L10n.CreateShard.stepDone,
        ]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                HorcruxTheme.backgroundGradient.ignoresSafeArea()

                VStack(spacing: 0) {
                    StepProgressBar(steps: stepLabels, currentIndex: stepIndex)

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
                }
            }
            .navigationTitle(L10n.CreateShard.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
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
        .preferredColorScheme(.dark)
    }
}

// MARK: - Step 1: Configure

struct ConfigureView: View {
    @ObservedObject var viewModel: CreateShardViewModel
    @State private var showAdvanced = false
    @State private var showExplainer = false
    @State private var showQRScanner = false
    @State private var showNofNConfirm = false
    @State private var acknowledgedNofN = false

    var body: some View {
        Form {
            // Role selector — creator (chooses m/n/curve) vs joiner
            // (adopts creator's SessionBegin broadcast automatically).
            Section {
                Picker(L10n.CreateShard.rolePicker, selection: $viewModel.role) {
                    Text(L10n.CreateShard.roleCreate).tag(CreateShardViewModel.Role.create)
                    Text(L10n.CreateShard.roleJoin).tag(CreateShardViewModel.Role.join)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("configure_rolePicker")
            } footer: {
                Text(viewModel.role == .create
                     ? L10n.CreateShard.creatorFooter
                     : L10n.CreateShard.joinerFooter)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .darkListRow()

            // Value-prop header (item 2: convey MPC core value)
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "shield.lefthalf.filled")
                            .foregroundStyle(HorcruxTheme.successGreen)
                        Text(L10n.CreateShard.mpcTitle)
                            .font(.headline)
                        Spacer()
                        Button {
                            showExplainer = true
                        } label: {
                            Image(systemName: "info.circle")
                                .foregroundStyle(HorcruxTheme.accentBlue)
                        }
                        .accessibilityLabel(L10n.CreateShard.mpcExplainerA11y)
                    }
                    if viewModel.role == .create {
                        Text(L10n.CreateShard.creatorValueProp(viewModel.totalParties, viewModel.threshold))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(L10n.CreateShard.joinerValueProp)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            .darkListRow()

            Section(L10n.CreateShard.walletName) {
                TextField(L10n.CreateShard.walletNamePlaceholder, text: $viewModel.walletName)
                    .accessibilityLabel(L10n.CreateShard.walletNameAccessibility)
                    .accessibilityHint(L10n.CreateShard.walletNameHint)
                    .accessibilityIdentifier("configure_walletNameField")
            }
            .darkListRow()

            if viewModel.role == .create {
                Section(L10n.CreateShard.blockchain) {
                    Picker(L10n.CreateShard.chain, selection: $viewModel.selectedCurve) {
                        Text(L10n.CreateShard.chainEvmBtc)
                            .tag(FfiCurveType.secp256k1)
                        Text(L10n.CreateShard.chainSolana)
                            .tag(FfiCurveType.ed25519)
                    }
                    .pickerStyle(.inline)

                    Text(viewModel.selectedCurve == .secp256k1
                         ? L10n.CreateShard.addrsEvmBtc
                         : L10n.CreateShard.addrSolana)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .darkListRow()

                // Advanced settings (item 1: reduce cognitive load)
                Section {
                    DisclosureGroup(L10n.CreateShard.advancedSettings, isExpanded: $showAdvanced) {
                        advancedThresholdStepper
                        advancedTransportToggles
                    }
                } footer: {
                    if !showAdvanced {
                        Text(L10n.CreateShard.advancedDefaults)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .darkListRow()
            } else {
                // Joiner only exposes transports + room code; m/n and
                // curve will be dictated by the creator's SessionBegin.
                Section {
                    DisclosureGroup(L10n.CreateShard.connectMethod, isExpanded: $showAdvanced) {
                        advancedTransportToggles
                    }
                } footer: {
                    Text(L10n.CreateShard.joinerSimpleHint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .darkListRow()
            }

            Section {
                Button {
                    if viewModel.role == .create
                        && viewModel.threshold == viewModel.totalParties
                        && viewModel.totalParties > 1 {
                        showNofNConfirm = true
                    } else {
                        viewModel.step = .discover
                        viewModel.startDiscovery()
                    }
                } label: {
                    Text(viewModel.role == .create
                         ? L10n.CreateShard.nextFindPeers
                         : L10n.CreateShard.nextWaitCreator)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GradientButtonStyle(
                    isEnabled: !(viewModel.walletName.isEmpty || (viewModel.selectedTransports.contains(.relay) && viewModel.roomCode.isEmpty))
                ))
                .disabled(viewModel.walletName.isEmpty || (viewModel.selectedTransports.contains(.relay) && viewModel.roomCode.isEmpty))
                .accessibilityHint(L10n.CreateShard.findPeersHint)
                .accessibilityIdentifier("configure_nextButton")
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
        .darkFormStyle()
        .alert(L10n.CreateShard.nofnAlertTitle, isPresented: $showNofNConfirm) {
            Button(L10n.CreateShard.nofnContinue, role: .destructive) {
                viewModel.step = .discover
                viewModel.startDiscovery()
            }
            Button(L10n.CreateShard.nofnRevert, role: .cancel) {
                viewModel.totalParties = 3
                viewModel.threshold = 2
            }
        } message: {
            Text(L10n.CreateShard.nofnAlertBody(viewModel.threshold, viewModel.totalParties))
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
        .onAppear { autofillRoomCodeIfNeeded() }
        .onChange(of: viewModel.role) { _, newRole in
            if newRole == .join { viewModel.roomCode = "" }
            autofillRoomCodeIfNeeded()
        }
        .onChange(of: viewModel.selectedTransports) { _, _ in autofillRoomCodeIfNeeded() }
    }

    /// Creator path always needs a non-empty room code when Relay is a
    /// selected transport; auto-generate one so the user never sees an
    /// empty field or has to hunt for the regenerate button.
    private func autofillRoomCodeIfNeeded() {
        guard viewModel.role == .create,
              viewModel.selectedTransports.contains(.relay),
              viewModel.roomCode.isEmpty
        else { return }
        viewModel.roomCode = RoomCode.generate()
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
                Text(L10n.CreateShard.recommendedNof3)
                    .font(.caption)
            } icon: {
                Image(systemName: "checkmark.shield.fill").foregroundStyle(HorcruxTheme.successGreen)
            }
        } else if viewModel.totalParties == viewModel.threshold {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.CreateShard.noRedundancyTitle(viewModel.threshold, viewModel.totalParties))
                        .font(.caption.bold())
                    Text(L10n.CreateShard.noRedundancyBody)
                        .font(.caption2)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(HorcruxTheme.dangerRed)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(HorcruxTheme.dangerRed.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
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
                    Text(L10n.CreateShard.relayServer)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(RelayConfig.effectiveURL)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(L10n.CreateShard.relayServerHint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Text(L10n.CreateShard.roomCodeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

                if viewModel.role == .create {
                    Text(L10n.CreateShard.roomCodeCreatorHint)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    HStack {
                        TextField(L10n.CreateShard.roomCodePlaceholder, text: $viewModel.roomCode)
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
                            showQRScanner = true
                        } label: {
                            Image(systemName: "qrcode.viewfinder")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel(L10n.CreateShard.scanRoomA11y)
                        .accessibilityIdentifier("configure_scanRoomCodeButton")

                        Button {
                            if let pasted = UIPasteboard.general.string {
                                let normalized = RoomCode.normalize(pasted)
                                viewModel.roomCode = normalized
                                Haptics.success()
                            } else {
                                Haptics.warning()
                            }
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                                .foregroundStyle(HorcruxTheme.accentCyan)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel(L10n.CreateShard.pasteRoomCodeA11y)
                        .accessibilityIdentifier("configure_pasteRoomCodeButton")
                    }

                    if !viewModel.roomCode.isEmpty && !RoomCode.isValid(viewModel.roomCode) {
                        Text(L10n.CreateShard.roomCodeInvalid)
                            .font(.caption2)
                            .foregroundStyle(HorcruxTheme.warningAmber)
                    }
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
                .navigationTitle(L10n.CreateShard.scanRoomTitle)
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
                        title: L10n.CreateShard.explainerNoMnemonicTitle,
                        body: L10n.CreateShard.explainerNoMnemonicBody
                    )
                    explainerRow(
                        icon: "rectangle.split.3x1.fill",
                        color: .blue,
                        title: L10n.CreateShard.explainerShardsTitle,
                        body: L10n.CreateShard.explainerShardsBody
                    )
                    explainerRow(
                        icon: "checkmark.shield.fill",
                        color: .green,
                        title: L10n.CreateShard.explainerRecoverTitle,
                        body: L10n.CreateShard.explainerRecoverBody
                    )
                    explainerRow(
                        icon: "link.circle.fill",
                        color: .purple,
                        title: L10n.CreateShard.explainerMultiChainTitle,
                        body: L10n.CreateShard.explainerMultiChainBody
                    )
                }
                .padding()
            }
            .navigationTitle(L10n.CreateShard.explainerNavTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.CreateShard.explainerDone) { dismiss() }
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
    private let totalTimeout = 180
    @State private var timeRemaining = 180
    @State private var timerTask: Task<Void, Never>?

    /// App-level presence count (unique deviceNames), not transport
    /// peers — so the same physical device on both relay and WiFi-LAN
    /// only counts once.
    private var presentCount: Int {
        viewModel.roomPresence.count
    }

    private var progress: Double {
        if viewModel.role == .join {
            return presentCount > 0 ? 1.0 : 0.0
        }
        let needed = max(viewModel.totalParties - 1, 1)
        return min(Double(presentCount) / Double(needed), 1.0)
    }

    private var creatorCanStart: Bool {
        presentCount >= viewModel.totalParties - 1
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
                    Text(L10n.Discovery.secondsTimeout)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()

            Text(L10n.Discovery.lookingForDevices)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Image(systemName: viewModel.role == .create
                      ? "crown.fill"
                      : "person.crop.circle.badge.checkmark")
                    .foregroundStyle(viewModel.role == .create ? .orange : HorcruxTheme.accentCyan)
                Text(viewModel.role == .create
                     ? L10n.Discovery.initiatorId(viewModel.localPeerId)
                     : L10n.Discovery.joinerId(viewModel.localPeerId))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(HorcruxTheme.accentCyan)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(HorcruxTheme.accentCyan.opacity(0.1), in: Capsule())

            // Initiator: keep the room code + QR visible in the waiting room
            // so joiners arriving mid-ceremony can still scan / type the code
            // without forcing the initiator to back out to the configure page.
            // Only the Relay transport actually needs a room code — Wi-Fi LAN,
            // Wi-Fi Direct and BLE do their own mDNS / radio-level discovery,
            // so hiding the card there keeps the screen clean.
            if viewModel.role == .create
                && viewModel.selectedTransports.contains(.relay)
                && RoomCode.isValid(viewModel.roomCode) {
                RoomCodeShareCard(code: viewModel.roomCode)
                    .padding(.horizontal)
            }

            if viewModel.role == .create {
                Text(L10n.Discovery.peersFound(presentCount, viewModel.totalParties - 1))
                    .font(.headline)
                    .accessibilityLabel(L10n.Discovery.peersFoundAccessibility(presentCount, viewModel.totalParties - 1))
            } else {
                HStack(spacing: 8) {
                    if presentCount == 0 {
                        ProgressView().controlSize(.small)
                        Text(L10n.Discovery.waitingInitiator)
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(.green)
                        Text(L10n.Discovery.connectedWaiting(presentCount))
                    }
                }
                .font(.headline)
            }

            // List of room-present devices (app-level beacon). Falls
            // back to transport-level foundPeers if no presence yet.
            let presenceList = viewModel.roomPresence.values.sorted { $0.deviceName < $1.deviceName }
            if !presenceList.isEmpty {
                List(presenceList, id: \.deviceName) { pres in
                    let parts = DeviceIdentity.split(pres.deviceName)
                    HStack {
                        Image(systemName: pres.role == "create" ? "crown.fill" : "person.circle.fill")
                            .foregroundStyle(pres.role == "create" ? .orange : .blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(parts.label)
                                .font(.headline)
                            if let sid = parts.shortId {
                                Text("ID: \(sid)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .monospaced()
                            }
                            Text(pres.role == "create" ? L10n.Discovery.initiatorLabel : L10n.Discovery.joinerLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            } else {
                List(viewModel.foundPeers) { peer in
                    let parts = DeviceIdentity.split(peer.name)
                    HStack {
                        Image(systemName: "person.circle.fill")
                            .foregroundStyle(.gray)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(parts.label)
                                .font(.headline)
                            if let sid = parts.shortId {
                                Text("ID: \(sid)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .monospaced()
                            }
                            Text("\(peer.channel) · \(String(peer.id.prefix(8)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }

            if viewModel.role == .create {
                if creatorCanStart {
                    Button {
                        timerTask?.cancel()
                        viewModel.creatorStartDKG()
                    } label: {
                        Text(L10n.Discovery.startKeyGeneration)
                            .frame(maxWidth: .infinity)
                            .font(.headline)
                    }
                    .buttonStyle(GradientButtonStyle())
                    .padding(.horizontal)
                    .accessibilityHint(L10n.Discovery.startKeyGenHint)
                    .accessibilityIdentifier("discover_startDKGButton")
                } else {
                    Text(L10n.Discovery.joinerHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            } else {
                // Joiner: no button. Auto-advances when the creator's
                // SessionBegin arrives (handled in the view model).
                Text(L10n.Discovery.joinerWaitStart)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
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

/// Compact room-code + QR pill used in the initiator's waiting room so
/// joiners arriving late can still scan/read the code without making
/// the initiator back out to the configure page.
private struct RoomCodeShareCard: View {
    let code: String
    @State private var expanded = false
    @State private var copied = false

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.CreateShard.roomCodeLabel)
                        .font(.caption)
                        .foregroundStyle(HorcruxTheme.subtleText)
                    Text(code)
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }

                Spacer()

                Button {
                    SecureClipboard.copy(code)
                    Haptics.success()
                    withAnimation { copied = true }
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        await MainActor.run { withAnimation { copied = false } }
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(copied ? HorcruxTheme.successGreen : HorcruxTheme.accentCyan)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.white.opacity(0.06)))
                }
                .accessibilityLabel(L10n.CreateShard.copyRoomCode)

                Button {
                    expanded = true
                } label: {
                    RoomCodeQRView(code: code)
                        .frame(width: 44, height: 44)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
                }
                .accessibilityLabel(L10n.CreateShard.showQR)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(HorcruxTheme.hairline, lineWidth: 1))
        )
        .sheet(isPresented: $expanded) {
            RoomCodeExpandedSheet(code: code)
                .presentationDetents([.medium])
        }
    }
}

private struct RoomCodeExpandedSheet: View {
    let code: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                HorcruxTheme.backgroundGradient.ignoresSafeArea()
                VStack(spacing: 20) {
                    Text(L10n.CreateShard.roomCodeLabel)
                        .font(.caption)
                        .foregroundStyle(HorcruxTheme.subtleText)
                    Text(code)
                        .font(.system(.title, design: .monospaced).weight(.bold))
                        .foregroundStyle(.white)

                    RoomCodeQRView(code: code)
                        .frame(width: 240, height: 240)

                    Text(L10n.CreateShard.scanToJoin)
                        .font(.footnote)
                        .foregroundStyle(HorcruxTheme.subtleText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Text(L10n.CreateShard.roomCodeEphemeralHint)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.Common.done) { dismiss() }
                }
            }
        }
    }
}

// MARK: - Step 3: DKG Progress

struct DKGProgressView: View {
    @ObservedObject var viewModel: CreateShardViewModel
    @State private var elapsedSeconds = 0
    @State private var elapsedTask: Task<Void, Never>?
    @State private var completionPulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var estimatedTotal: Int {
        DkgEstimate.dkgSeconds(
            curve: viewModel.selectedCurve,
            totalParties: viewModel.totalParties,
            primePoolReady: DkgEstimate.primePoolReady(for: viewModel.totalParties)
        )
    }

    /// Show a slow-path disclosure after we've exceeded the estimate.
    /// Reassures the user that safe prime generation is probabilistic
    /// and the wait is expected, not a hang.
    private var showSlowPathHint: Bool {
        viewModel.selectedCurve != .ed25519 && elapsedSeconds > estimatedTotal
    }

    /// Smooth display progress derived from both the round index and
    /// wall-clock elapsed. Individual rounds (esp. Paillier rounds 3-5)
    /// can take 10-15s; a pure round-based ring would freeze for that
    /// entire window while the seconds tick up, which looks like a hang
    /// and is inconsistent with the timer. We take the max of the two
    /// estimates and cap at 95% until the ceremony actually reports done.
    private var displayProgress: Double {
        let timeBased = min(Double(elapsedSeconds) / Double(estimatedTotal), 0.95)
        let roundBased = viewModel.dkgProgress
        // Once the view model has jumped to the finalization states
        // (0.95/1.0), let those values through so the ring completes.
        if roundBased >= 0.95 { return roundBased }
        return max(roundBased, timeBased)
    }

    private var remainingLabel: String {
        let remaining = estimatedTotal - elapsedSeconds
        if remaining > 0 {
            return "~\(remaining)s"
        }
        // We've already exceeded the estimate — don't lie with "0s".
        return L10n.DKG.wrappingUp
    }

    /// Curve-family tint: secp256k1 gets Ethereum blue-purple (its home
    /// family), ed25519 gets Solana violet. DKG doesn't run per-chain so
    /// the tint picks the dominant chain associated with the chosen curve.
    private var curveTint: Color {
        viewModel.selectedCurve == .ed25519
            ? Chain.solana.color
            : Chain.ethereum.color
    }

    /// Per-shard orbit states. DKG is a collective ceremony without
    /// independent per-peer progress reporting — while running, every
    /// party is .active; on completion all flip to .done. Gives the
    /// orbit visible rhythm during the long Paillier wait.
    private var shardStates: [ShardOrbit.DotState] {
        let done = displayProgress >= 1.0
        return Array(repeating: done ? ShardOrbit.DotState.done : .active,
                     count: max(viewModel.totalParties, 1))
    }

    var body: some View {
        let tint = curveTint
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                ShardOrbit(
                    total: max(viewModel.totalParties, 1),
                    states: shardStates,
                    radius: 84,
                    tint: tint
                )
                ProgressRing(progress: displayProgress, tint: tint, showPercentage: false)
                    .frame(width: 120, height: 120)
                    .accessibilityLabel(L10n.DKG.keyGenProgress)
                    .accessibilityValue("\(Int(displayProgress * 100)) percent")
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(tint)
                    .scaleEffect(completionPulse ? 1.15 : 1.0)
                    .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.5), value: completionPulse)
            }
            .frame(height: 200)

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

            // Elapsed timer card — tint-wrapped for visual continuity with
            // signing ceremony and wallet home.
            HStack(spacing: 16) {
                VStack {
                    Text("\(elapsedSeconds)s")
                        .font(.headline.monospacedDigit())
                    Text(L10n.DKG.elapsedLabel).font(.caption2).foregroundStyle(.secondary)
                }
                Divider().frame(height: 30)
                VStack {
                    Text(remainingLabel)
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(L10n.DKG.remainingLabel).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .tintedGlassCard(color: tint, cornerRadius: 12, padding: 12)
            .padding(.horizontal)

            Spacer()

            if showSlowPathHint {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(HorcruxTheme.accentCyan)
                    Text(L10n.DKG.slowPathHint)
                        .font(.caption)
                        .foregroundStyle(HorcruxTheme.subtleText)
                        .multilineTextAlignment(.leading)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(HorcruxTheme.accentCyan.opacity(0.08))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(HorcruxTheme.accentCyan.opacity(0.25), lineWidth: 1))
                )
                .padding(.horizontal)
            }

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
        .onChange(of: displayProgress) { _, new in
            if new >= 1.0 && !completionPulse {
                Haptics.success()
                completionPulse = true
            }
        }
    }
}

// MARK: - Step 4: Complete

struct DKGCompleteView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var viewModel: CreateShardViewModel
    let dismiss: DismissAction
    @State private var showPinPrompt = false
    @State private var showBackupGate = false
    @State private var showSkipBackupWarn = false
    @State private var acknowledgedBackup = false
    @State private var saveError: String?
    @ScaledMetric(relativeTo: .largeTitle) private var successIconSize: CGFloat = 72
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    @State private var sealScale: CGFloat = 0.4

    private var ceremonyTint: Color {
        viewModel.selectedCurve == .ed25519
            ? Chain.solana.color
            : Chain.ethereum.color
    }

    var body: some View {
        let tint = ceremonyTint
        VStack(spacing: 32) {
            Spacer()

            ZStack {
                ForEach(0..<2, id: \.self) { i in
                    Circle()
                        .stroke(tint.opacity(0.35), lineWidth: 2)
                        .frame(width: successIconSize * 1.6, height: successIconSize * 1.6)
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
                            colors: [HorcruxTheme.successGreen.opacity(0.35), tint.opacity(0.0)],
                            center: .center,
                            startRadius: 2,
                            endRadius: successIconSize
                        )
                    )
                    .frame(width: successIconSize * 1.4, height: successIconSize * 1.4)

                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: successIconSize))
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
                Text(L10n.DKG.walletCreated)
                    .font(.title.bold())
            }

            VStack(spacing: 4) {
                Text(L10n.DKG.yourShardIs(viewModel.partyIndex))
                    .font(.headline)
                Text(L10n.DKG.thresholdOf(viewModel.threshold, viewModel.totalParties))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await saveTapped() }
            } label: {
                Text(L10n.DKG.saveEncryptShard)
                    .frame(maxWidth: .infinity)
                    .font(.headline)
            }
            .buttonStyle(GradientButtonStyle())
            .padding(.horizontal)
            .accessibilityHint(L10n.DKG.saveEncryptHint)
            .accessibilityIdentifier("dkgComplete_saveButton")
        }
        .padding()
        .sheet(isPresented: $showPinPrompt) {
            PinUnlockSheet(
                title: L10n.DKG.enterPinEncrypt,
                subtitle: L10n.DKG.pinNeededEncrypt
            ) { entered in
                guard appState.verifyPin(entered) else {
                    return L10n.DKG.incorrectPin
                }
                do {
                    try viewModel.saveWallet(to: appState, pin: entered)
                    DispatchQueue.main.async { showBackupGate = true }
                    return nil
                } catch {
                    DispatchQueue.main.async { saveError = error.localizedDescription }
                    return L10n.DKG.incorrectPin
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showBackupGate) {
            BackupGateSheet(
                acknowledged: $acknowledgedBackup,
                onBackupNow: {
                    showBackupGate = false
                    dismiss()
                },
                onSkip: {
                    showSkipBackupWarn = true
                }
            )
            .interactiveDismissDisabled(true)
        }
        .alert(L10n.DKG.unbackedExitTitle, isPresented: $showSkipBackupWarn) {
            Button(L10n.DKG.unbackedExitContinue, role: .destructive) {
                showBackupGate = false
                dismiss()
            }
            Button(L10n.DKG.unbackedExitReturn, role: .cancel) { }
        } message: {
            Text(L10n.DKG.unbackedExitBody)
        }
        .alert(L10n.DKG.saveFailedTitle, isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button(L10n.DKG.saveFailedOk, role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    /// Try to save silently (cache → biometric). Only prompt for PIN as a
    /// last resort. This avoids a second PIN prompt when the SWK was just
    /// provisioned via onboarding or biometric unlock.
    private func saveTapped() async {
        if let key = appState.cachedShardKey() {
            do {
                try viewModel.saveWallet(to: appState, keyMaterial: key)
                Haptics.success()
                showBackupGate = true
            } catch {
                saveError = error.localizedDescription
            }
            return
        }
        // Cache was cleared (e.g. app backgrounded during DKG). Try
        // biometric silently before bothering the user for a PIN.
        if SecureKeyVault.hasSESealed {
            if await appState.unlockShardKeyWithBiometric(),
               let key = appState.cachedShardKey() {
                do {
                    try viewModel.saveWallet(to: appState, keyMaterial: key)
                    Haptics.success()
                    showBackupGate = true
                } catch {
                    saveError = error.localizedDescription
                }
                return
            }
        }
        showPinPrompt = true
    }
}

/// Mandatory post-save backup gate. User must either:
/// - Acknowledge they've made an off-device backup (then proceed), OR
/// - Explicitly skip with a destructive confirmation.
private struct BackupGateSheet: View {
    @Binding var acknowledged: Bool
    let onBackupNow: () -> Void
    let onSkip: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Label {
                        Text(L10n.Backup.lastStep).font(.title2.bold())
                    } icon: {
                        Image(systemName: "icloud.and.arrow.up.fill")
                            .foregroundStyle(.blue)
                    }

                    Text(L10n.Backup.whyBody)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 10) {
                        bullet(L10n.Backup.bullet1)
                        bullet(L10n.Backup.bullet2)
                        bullet(L10n.Backup.bullet3)
                    }
                    .font(.callout)

                    Toggle(isOn: $acknowledged) {
                        Text(L10n.Backup.ackToggle)
                            .font(.callout)
                    }
                    .tint(HorcruxTheme.accentBlue)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(HorcruxTheme.cardSurface.opacity(0.5)))

                    Button(action: onBackupNow) {
                        Label(L10n.Backup.doneButton, systemImage: "checkmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GradientButtonStyle(isEnabled: acknowledged))
                    .disabled(!acknowledged)

                    Button(role: .destructive, action: onSkip) {
                        Text(L10n.Backup.skipButton)
                            .frame(maxWidth: .infinity)
                            .font(.callout)
                            .foregroundStyle(HorcruxTheme.dangerRed)
                            .padding(.vertical, 10)
                    }
                }
                .padding()
            }
            .navigationTitle(L10n.Backup.navTitle)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(HorcruxTheme.accentBlue)
            Text(text)
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
                .foregroundStyle(HorcruxTheme.dangerRed)
                .accessibilityHidden(true)

            Text(L10n.DKG.keyGenFailed)
                .font(.title2.bold())

            Text(viewModel.errorMessage)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(L10n.Common.retry) {
                viewModel.step = .discover
            }
            .buttonStyle(GradientButtonStyle())
            .padding(.horizontal)
            .accessibilityHint(L10n.DKG.retryHint)
            .accessibilityIdentifier("dkgError_retryButton")

            Spacer()
        }
        .padding()
    }
}

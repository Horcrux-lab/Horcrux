import SwiftUI

/// Auto-drives the DKG ceremony for testing. Launch with:
///   -DKGTest -DKGRoom <room> -DKGParty <1|2>
struct DKGTestView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = CreateShardViewModel()

    private let room: String
    private let partyIndex: Int

    init() {
        let args = ProcessInfo.processInfo.arguments
        if let idx = args.firstIndex(of: "-DKGRoom"), idx + 1 < args.count {
            room = args[idx + 1]
        } else {
            room = "test-dkg"
        }
        if let idx = args.firstIndex(of: "-DKGParty"), idx + 1 < args.count {
            partyIndex = Int(args[idx + 1]) ?? 1
        } else {
            partyIndex = 1
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("DKG Test Mode")
                    .font(.headline)
                    .foregroundStyle(.orange)

                Text("Room: \(room) | Party: \(partyIndex)")
                    .font(.caption.monospaced())

                Divider()

                Group {
                    switch viewModel.step {
                    case .configure:
                        Text("Configuring...")
                            .onAppear { autoConfigure() }
                    case .discover:
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Discovering peers...")
                            Text("Found: \(viewModel.foundPeers.count)/\(viewModel.totalParties - 1)")
                                .font(.caption)
                        }
                    case .dkg:
                        DKGProgressView(viewModel: viewModel)
                    case .complete:
                        VStack(spacing: 16) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 64))
                                .foregroundStyle(.green)
                            Text("DKG Complete!")
                                .font(.title.bold())
                            if let addr = viewModel.generatedAddress {
                                Text(addr)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                    case .error:
                        VStack(spacing: 16) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 64))
                                .foregroundStyle(.red)
                            Text("DKG Failed")
                                .font(.title.bold())
                            Text(viewModel.errorMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()
            }
            .padding()
            .preferredColorScheme(.dark)
        }
        .onAppear {
            viewModel.bind(to: appState)
        }
        .onChange(of: viewModel.foundPeers.count) { _, newCount in
            if newCount >= viewModel.totalParties - 1 && viewModel.step == .discover {
                print("[DKGTest] Peers found! Auto-starting DKG...")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    viewModel.startDKG()
                }
            }
        }
    }

    private func autoConfigure() {
        viewModel.walletName = "Test Wallet"
        viewModel.selectedChain = .ethereum
        viewModel.threshold = 2
        viewModel.totalParties = 2
        viewModel.partyIndex = partyIndex
        viewModel.selectedTransports = [.relay]
        viewModel.roomCode = room

        print("[DKGTest] Configured: room=\(room) party=\(partyIndex) 2-of-2 Ethereum")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            viewModel.step = .discover
            viewModel.startDiscovery()
            print("[DKGTest] Discovery started")
        }
    }
}

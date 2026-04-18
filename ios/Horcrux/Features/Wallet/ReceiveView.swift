import SwiftUI
import CoreImage.CIFilterBuiltins

/// Shows wallet address as a QR code for receiving funds — dark glass card design.
struct ReceiveView: View {
    let wallet: Wallet
    @State private var copiedAddress = false
    @State private var requestedAmount = ""
    @Environment(\.dismiss) private var dismiss

    /// BIP-21 / EIP-681 / Solana Pay style payload. Falls back to the plain
    /// address when no amount is entered or the chain has no well-known
    /// URI scheme.
    private var qrPayload: String {
        let amount = requestedAmount.trimmingCharacters(in: .whitespaces)
        guard !amount.isEmpty, Decimal(string: amount) != nil else { return wallet.address }
        switch wallet.chain {
        case .bitcoin:
            return "bitcoin:\(wallet.address)?amount=\(amount)"
        case .litecoin:
            return "litecoin:\(wallet.address)?amount=\(amount)"
        case .solana:
            return "solana:\(wallet.address)?amount=\(amount)"
        case .tron:
            // No standard URI scheme — stash amount as query for wallets that honour it.
            return "tron:\(wallet.address)?amount=\(amount)"
        default:
            // EVM: EIP-681. Convert ether → wei as decimal integer.
            guard wallet.chain.isEVM,
                  let ether = Decimal(string: amount) else { return wallet.address }
            let wei = ether * pow(Decimal(10), 18)
            let weiStr = NSDecimalNumber(decimal: wei).stringValue
            return "ethereum:\(wallet.address)?value=\(weiStr)"
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                HorcruxTheme.backgroundGradient.ignoresSafeArea()

                ScrollView {
                VStack(spacing: 24) {
                    Spacer().frame(height: 8)

                    ChainIcon(chain: wallet.chain, size: 48)

                    Text(L10n.Receive.receiveSymbol(wallet.chain.symbol))
                        .font(.title2.bold())
                        .foregroundStyle(.white)

                    // QR Code
                    if let qrImage = generateQRCode(from: qrPayload) {
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 200, height: 200)
                            .padding(20)
                            .background(
                                RoundedRectangle(cornerRadius: 20)
                                    .fill(.white)
                            )
                            .shadow(color: HorcruxTheme.accentPurple.opacity(0.3), radius: 16, y: 8)
                            .accessibilityLabel(L10n.Receive.qrCodeAccessibility(wallet.chain.symbol))
                            .accessibilityHint(L10n.Receive.qrShareHint)
                            .accessibilityIdentifier("receive_qrCode")
                    } else {
                        RoundedRectangle(cornerRadius: 20)
                            .fill(HorcruxTheme.cardSurface)
                            .frame(width: 200, height: 200)
                            .overlay {
                                Text(L10n.Receive.qrError)
                                    .foregroundStyle(HorcruxTheme.subtleText)
                            }
                            .accessibilityLabel(L10n.Receive.qrFailed)
                    }

                    // Amount request (optional)
                    HStack {
                        Text("请求金额")
                            .font(.subheadline)
                            .foregroundStyle(HorcruxTheme.subtleText)
                        TextField("可选", text: $requestedAmount)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.white)
                            .textFieldStyle(.plain)
                            .accessibilityIdentifier("receive_amountField")
                        Text(wallet.chain.symbol)
                            .font(.subheadline.monospaced())
                            .foregroundStyle(HorcruxTheme.subtleText)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(HorcruxTheme.cardSurface))
                    .padding(.horizontal, 32)

                    // Address
                    Text(wallet.address)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(HorcruxTheme.subtleText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .textSelection(.enabled)
                        .accessibilityLabel(L10n.WalletDetail.walletAddress)
                        .accessibilityValue(wallet.address)
                        .accessibilityIdentifier("receive_addressText")

                    // Copy button
                    Button {
                        SecureClipboard.copy(wallet.address)
                        copiedAddress = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedAddress = false }
                    } label: {
                        Label(copiedAddress ? L10n.Receive.copiedClears(Int(SecureClipboard.defaultExpireSeconds)) : L10n.Receive.copyAddress,
                              systemImage: copiedAddress ? "checkmark.circle.fill" : "doc.on.doc")
                    }
                    .buttonStyle(GradientButtonStyle())
                    .padding(.horizontal, 32)
                    .accessibilityLabel(copiedAddress ? L10n.Receive.addressCopied : L10n.Receive.copyAddress)
                    .accessibilityHint(L10n.Receive.copiesHint)
                    .accessibilityIdentifier("receive_copyButton")

                    // Share button — shares payload (incl. requested amount) if set.
                    ShareLink(item: qrPayload) {
                        Label(L10n.Receive.shareAddress, systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(HorcruxTheme.accentPurple)
                            .padding(.vertical, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(HorcruxTheme.accentPurple.opacity(0.4), lineWidth: 1.5)
                            )
                    }
                    .padding(.horizontal, 32)
                    .accessibilityLabel(L10n.Receive.shareAddress)
                    .accessibilityHint(L10n.Receive.shareHint)
                    .accessibilityIdentifier("receive_shareButton")

                    Spacer().frame(height: 24)
                }
                }
            }
            .navigationTitle(L10n.Receive.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.Common.done) { dismiss() }
                        .foregroundStyle(HorcruxTheme.accentPurple)
                        .accessibilityIdentifier("receive_doneButton")
                }
            }
        }
    }

    private func generateQRCode(from string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let scale = 10.0
        let transformed = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

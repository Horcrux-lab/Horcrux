import SwiftUI
import CoreImage.CIFilterBuiltins

/// Shows wallet address as a QR code for receiving funds.
struct ReceiveView: View {
    let wallet: Wallet
    @State private var copiedAddress = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                ChainIcon(chain: wallet.chain, size: 48)

                Text("Receive \(wallet.chain.symbol)")
                    .font(.title2.bold())

                // QR Code
                if let qrImage = generateQRCode(from: wallet.address) {
                    Image(uiImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 220, height: 220)
                        .padding(16)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16))
                        .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
                } else {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.quaternary)
                        .frame(width: 220, height: 220)
                        .overlay {
                            Text("QR Error")
                                .foregroundStyle(.secondary)
                        }
                }

                // Address
                Text(wallet.address)
                    .font(.system(.caption, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .textSelection(.enabled)

                // Copy button
                Button {
                    SecureClipboard.copy(wallet.address)
                    copiedAddress = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedAddress = false }
                } label: {
                    Label(copiedAddress ? "Copied (clears in 60s)" : "Copy Address",
                          systemImage: copiedAddress ? "checkmark.circle.fill" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 32)

                // Share button
                ShareLink(item: wallet.address) {
                    Label("Share Address", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .font(.headline)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 32)

                Spacer()
            }
            .navigationTitle("Receive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Generate a QR code UIImage from a string.
    private func generateQRCode(from string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else { return nil }

        // Scale up for crisp rendering
        let scale = 10.0
        let transformed = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

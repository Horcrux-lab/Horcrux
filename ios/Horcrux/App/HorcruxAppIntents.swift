import AppIntents
import Foundation

/// App Intents / Siri Shortcuts integration.
///
/// These intents read directly from the wallet JSON file so they can
/// run without spinning up the full app state (`WalletStore` is owned
/// by `AppState` and not accessible from the intent extension context).
/// All operations are read-only; signing and broadcasting always
/// require the full app open for biometric + ceremony flow.
///
/// Users can expose these via Settings → Siri & Shortcuts, or invoke
/// by voice: "Hey Siri, open Horcrux wallet" / "嘿 Siri, 打开 Horcrux 钱包".

// MARK: - Minimal wallet record for intent reads

private struct IntentWallet: Decodable {
    let id: String
    let name: String
    let chain: String
    let address: String
    var isHidden: Bool?
}

private enum IntentWalletLoader {
    static func loadAll() -> [IntentWallet] {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let url = docs?.appendingPathComponent("horcrux_wallets.json"),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return []
        }
        return (try? JSONDecoder().decode([IntentWallet].self, from: data)) ?? []
    }
}

// MARK: - Chain query option provider

struct WalletChainEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Chain"
    static var defaultQuery = ChainQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: name))
    }
}

struct ChainQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WalletChainEntity] {
        IntentWalletLoader.loadAll()
            .filter { identifiers.contains($0.chain) }
            .map { WalletChainEntity(id: $0.chain, name: $0.chain) }
    }

    func suggestedEntities() async throws -> [WalletChainEntity] {
        // Deduplicate by chain — one row per chain even if the user
        // has multiple wallets on the same network.
        var seen = Set<String>()
        return IntentWalletLoader.loadAll().compactMap { w in
            guard !(w.isHidden ?? false), seen.insert(w.chain).inserted else { return nil }
            return WalletChainEntity(id: w.chain, name: w.chain)
        }
    }
}

// MARK: - Show wallet address intent

struct ShowWalletAddressIntent: AppIntent {
    static var title: LocalizedStringResource = LocalizedStringResource("intents.showAddr.title", defaultValue: "显示钱包地址")
    static var description = IntentDescription(
        LocalizedStringResource("intents.showAddr.desc", defaultValue: "读取指定链的钱包地址并复制到剪贴板，用于接收资产。只读操作，不触及分片。"),
        categoryName: LocalizedStringResource("intents.category.wallet", defaultValue: "钱包")
    )

    @Parameter(title: LocalizedStringResource("intents.param.chain", defaultValue: "链"))
    var chain: WalletChainEntity

    static var parameterSummary: some ParameterSummary {
        Summary("获取我的 \(\.$chain) 地址")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let match = IntentWalletLoader.loadAll().first(where: {
            !($0.isHidden ?? false) && $0.chain == chain.id
        })
        guard let wallet = match else {
            throw $chain.needsValueError(IntentDialog(LocalizedStringResource("intents.error.walletNotFound", defaultValue: "找不到该链上的钱包。")))
        }
        await MainActor.run {
            SecureClipboard.copy(wallet.address)
        }
        let short = shortAddress(wallet.address)
        let dialog = String(
            format: NSLocalizedString("intents.showAddr.dialog", comment: ""),
            wallet.chain, short
        )
        return .result(
            value: wallet.address,
            dialog: IntentDialog(stringLiteral: dialog)
        )
    }

    private func shortAddress(_ s: String) -> String {
        guard s.count > 12 else { return s }
        return "\(s.prefix(6))…\(s.suffix(4))"
    }
}

// MARK: - Open receive screen intent

struct OpenReceiveIntent: AppIntent {
    static var title: LocalizedStringResource = LocalizedStringResource("intents.openReceive.title", defaultValue: "打开收款二维码")
    static var description = IntentDescription(
        LocalizedStringResource("intents.openReceive.desc", defaultValue: "在 Horcrux 中打开指定链钱包的收款页面并显示二维码。"),
        categoryName: LocalizedStringResource("intents.category.wallet", defaultValue: "钱包")
    )
    static var openAppWhenRun: Bool = true

    @Parameter(title: LocalizedStringResource("intents.param.chain", defaultValue: "链"))
    var chain: WalletChainEntity

    static var parameterSummary: some ParameterSummary {
        Summary("打开 \(\.$chain) 收款二维码")
    }

    func perform() async throws -> some IntentResult {
        let match = IntentWalletLoader.loadAll().first(where: {
            !($0.isHidden ?? false) && $0.chain == chain.id
        })
        guard let wallet = match else {
            throw $chain.needsValueError(IntentDialog(LocalizedStringResource("intents.error.walletNotFound", defaultValue: "找不到该链上的钱包。")))
        }
        await MainActor.run {
            // DeepLinkRouter drives the UI once the app opens.
            DeepLinkRouter.shared.handle(.receive(address: wallet.address, chain: wallet.chain))
        }
        return .result()
    }
}

// MARK: - Shortcuts provider

struct HorcruxShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ShowWalletAddressIntent(),
            phrases: [
                "用 \(.applicationName) 复制地址",
                "在 \(.applicationName) 里复制钱包地址",
                "Copy address with \(.applicationName)",
                "Copy my wallet address in \(.applicationName)"
            ],
            shortTitle: LocalizedStringResource("intents.short.copyAddr", defaultValue: "复制地址"),
            systemImageName: "doc.on.doc"
        )
        AppShortcut(
            intent: OpenReceiveIntent(),
            phrases: [
                "用 \(.applicationName) 显示收款码",
                "打开 \(.applicationName) 收款",
                "Show receive QR in \(.applicationName)",
                "Open \(.applicationName) to receive"
            ],
            shortTitle: LocalizedStringResource("intents.short.receive", defaultValue: "收款二维码"),
            systemImageName: "qrcode"
        )
    }
}

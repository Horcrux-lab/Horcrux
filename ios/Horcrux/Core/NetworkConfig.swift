import Foundation
import Combine

/// Per-chain RPC endpoint configuration with sensible public defaults.
///
/// The module owns three sources of truth per chain:
///   1. A **network selector** (`evmChainId`, `btcTestnet`, `solDevnet`)
///   2. An optional **user-supplied RPC URL**
///   3. A built-in **default RPC** per (chain, network) derived from the selector
///
/// When the user switches networks (e.g. picks Polygon, toggles BTC testnet),
/// the URL field auto-swaps to the new default *iff* the current URL is one of
/// the recognized built-in defaults. If the user has typed a custom URL, it is
/// preserved — but in that case the UI should prompt them to update it.
///
/// Any mutation also fires `BalanceCache.shared.invalidateAll()` so cached
/// balances from the previous network never leak across a switch.
final class NetworkConfig: ObservableObject, @unchecked Sendable {
    static let shared = NetworkConfig()

    @Published var ethereumRPC: String {
        didSet {
            save(ethereumRPC, forKey: Keys.ethereumRPC)
            invalidateBalances()
        }
    }
    @Published var bitcoinAPI: String {
        didSet {
            save(bitcoinAPI, forKey: Keys.bitcoinAPI)
            invalidateBalances()
        }
    }
    @Published var litecoinAPI: String {
        didSet {
            save(litecoinAPI, forKey: Keys.litecoinAPI)
            invalidateBalances()
        }
    }
    @Published var tronAPI: String {
        didSet {
            save(tronAPI, forKey: Keys.tronAPI)
            invalidateBalances()
        }
    }
    @Published var solanaRPC: String {
        didSet {
            save(solanaRPC, forKey: Keys.solanaRPC)
            invalidateBalances()
        }
    }
    @Published var evmChainId: UInt64 {
        didSet {
            UserDefaults.standard.set(evmChainId, forKey: Keys.evmChainId)
            autoSwapEthereumRPCIfDefault(previousChainId: oldValue)
            invalidateBalances()
        }
    }
    @Published var btcTestnet: Bool {
        didSet {
            UserDefaults.standard.set(btcTestnet, forKey: Keys.btcTestnet)
            autoSwapBitcoinAPIIfDefault(previousTestnet: oldValue)
            invalidateBalances()
        }
    }
    @Published var solDevnet: Bool {
        didSet {
            UserDefaults.standard.set(solDevnet, forKey: Keys.solDevnet)
            autoSwapSolanaRPCIfDefault(previousDevnet: oldValue)
            invalidateBalances()
        }
    }

    /// Alchemy API key for EVM. Stored in Keychain (never UserDefaults).
    /// When `ethereumRPC` contains the `{KEY}` placeholder, this value is
    /// substituted in at RPC-call time. When this key transitions between
    /// empty and non-empty, recognised default URLs auto-swap between the
    /// Alchemy paid template and the free public endpoint so a freshly-
    /// entered key takes effect immediately without requiring the user to
    /// also update the URL field.
    @Published var alchemyAPIKey: String {
        didSet {
            saveKeychain(alchemyAPIKey, forKey: Keys.alchemyKey)
            autoSwapPaidPublicDefaultsOnKeyChange(oldKeyEmpty: oldValue.isEmpty)
            invalidateBalances()
        }
    }

    /// Helius API key for Solana. Same substitution pattern as `alchemyAPIKey`.
    @Published var heliusAPIKey: String {
        didSet {
            saveKeychain(heliusAPIKey, forKey: Keys.heliusKey)
            invalidateBalances()
        }
    }

    /// Etherscan V2 API key (optional). When set, transaction history sync
    /// for EVM chains hits api.etherscan.io with `chainid=<evmChainId>`.
    /// Without a key the free-tier endpoint is still reachable but
    /// rate-limited to 1 req / 5s.
    @Published var etherscanAPIKey: String {
        didSet { saveKeychain(etherscanAPIKey, forKey: Keys.etherscanKey) }
    }

    /// Infura project ID (aka API key). Used when the EVM URL points at an
    /// `*.infura.io` host containing the `{KEY}` placeholder. Stored in
    /// Keychain alongside the Alchemy key so users who pay both providers
    /// can switch between them in-place.
    @Published var infuraAPIKey: String {
        didSet {
            saveKeychain(infuraAPIKey, forKey: Keys.infuraKey)
            invalidateBalances()
        }
    }

    /// Ankr Premium API key. Used when the URL host contains `ankr.com`
    /// and the `{KEY}` placeholder. Ankr charges per-RPC-unit and covers
    /// both EVM and Solana under one key.
    @Published var ankrAPIKey: String {
        didSet {
            saveKeychain(ankrAPIKey, forKey: Keys.ankrKey)
            invalidateBalances()
        }
    }

    /// BlockPI API key. Used when the URL host contains `blockpi.network`
    /// and the `{KEY}` placeholder. BlockPI charges per request and is
    /// popular with users in Asia for its low latency.
    @Published var blockpiAPIKey: String {
        didSet {
            saveKeychain(blockpiAPIKey, forKey: Keys.blockpiKey)
            invalidateBalances()
        }
    }

    /// dRPC API key (aka `dkey`). Used with the `lb.drpc.org` load-balancer
    /// URL + `{KEY}` placeholder. dRPC is a decentralised RPC aggregator —
    /// the free tier is usable but paying users get priority routing and
    /// higher rate limits.
    @Published var drpcAPIKey: String {
        didSet {
            saveKeychain(drpcAPIKey, forKey: Keys.drpcKey)
            invalidateBalances()
        }
    }

    /// NodeReal MegaNode API key. Primarily used for BNB Smart Chain and
    /// opBNB where it's the dominant provider. Format substitutes `{KEY}`
    /// into the URL path.
    @Published var nodeRealAPIKey: String {
        didSet {
            saveKeychain(nodeRealAPIKey, forKey: Keys.nodeRealKey)
            invalidateBalances()
        }
    }

    /// GetBlock access token. Tokens are bound to a single chain on their
    /// dashboard, but the URL pattern is chain-agnostic
    /// (`https://go.getblock.io/{TOKEN}/`), so the same field works for
    /// EVM + BTC/LTC + Solana — the user just has to generate a separate
    /// token per chain in their GetBlock account.
    @Published var getblockAPIKey: String {
        didSet {
            saveKeychain(getblockAPIKey, forKey: Keys.getblockKey)
            invalidateBalances()
        }
    }

    /// Tenderly Gateway API key. Fits the `{KEY}` substitution pattern:
    /// `https://{chain}.gateway.tenderly.co/{KEY}`. Covers EVM only
    /// (Tenderly does not offer Solana). Single key works across all
    /// EVM chains on the user's Tenderly account.
    @Published var tenderlyAPIKey: String {
        didSet {
            saveKeychain(tenderlyAPIKey, forKey: Keys.tenderlyKey)
            invalidateBalances()
        }
    }

    /// 1RPC API key. URL pattern puts the key in the path:
    /// `https://1rpc.io/{KEY}/eth`. Same key works across all supported
    /// chains (EVM + Solana) — 1RPC is privacy-focused and routes
    /// requests through multiple upstreams to mask the caller.
    @Published var oneRPCAPIKey: String {
        didSet {
            saveKeychain(oneRPCAPIKey, forKey: Keys.oneRPCKey)
            invalidateBalances()
        }
    }

    /// Optional WebSocket endpoint for the selected EVM chain. Paid
    /// providers (Alchemy, Infura, QuickNode) expose `wss://` alongside
    /// `https://`. We don't auto-subscribe — the field is manually
    /// testable and reserved for future push-based features. Empty
    /// string = not configured.
    @Published var ethereumWSS: String {
        didSet { save(ethereumWSS, forKey: Keys.ethereumWSS) }
    }

    /// Optional WebSocket endpoint for Solana. Helius / QuickNode both
    /// support `wss://`. Same semantics as `ethereumWSS`.
    @Published var solanaWSS: String {
        didSet { save(solanaWSS, forKey: Keys.solanaWSS) }
    }

    private init() {
        let ud = UserDefaults.standard
        Self.migrateDeadEndpoints(ud)
        // Load API keys *first* so we can pick the right default URL for
        // EVM/Solana based on whether a paid key is already configured.
        // Users with an Alchemy key get the Alchemy template by default;
        // users without one get the free public endpoint — so "default"
        // really means "the best endpoint available given the user's
        // current credentials", not "always paid" or "always free".
        //
        // Swift requires every stored property be initialised before
        // `self` is referenced, so we stage the Keychain reads in local
        // variables first and only then assign them through.
        let alchemy = Self.loadKeychainString(key: Keys.alchemyKey)
        let helius = Self.loadKeychainString(key: Keys.heliusKey)
        let etherscan = Self.loadKeychainString(key: Keys.etherscanKey)
        let infura = Self.loadKeychainString(key: Keys.infuraKey)
        let ankr = Self.loadKeychainString(key: Keys.ankrKey)
        let blockpi = Self.loadKeychainString(key: Keys.blockpiKey)
        let drpc = Self.loadKeychainString(key: Keys.drpcKey)
        let nodeReal = Self.loadKeychainString(key: Keys.nodeRealKey)
        let getblock = Self.loadKeychainString(key: Keys.getblockKey)
        let tenderly = Self.loadKeychainString(key: Keys.tenderlyKey)
        let oneRPC = Self.loadKeychainString(key: Keys.oneRPCKey)

        let hasAlchemy = !alchemy.isEmpty
        let storedChainId = ud.integer(forKey: Keys.evmChainId)
        if storedChainId == 0 && ud.object(forKey: Keys.evmChainId) != nil {
            NSLog("[NetworkConfig] Stored EVM chainId was 0 (invalid) — falling back to mainnet (1)")
        }
        let chainId = UInt64(storedChainId == 0 ? 1 : storedChainId)
        let evmDefault = (EVMNetwork(rawValue: chainId) ?? .mainnet).effectiveDefaultRPC(hasPaidKey: hasAlchemy)
        let solDevnetFlag = ud.bool(forKey: Keys.solDevnet)
        let solDefault = (solDevnetFlag ? SolanaNetwork.devnet : .mainnet).effectiveDefaultRPC(hasPaidKey: hasAlchemy)

        self.alchemyAPIKey = alchemy
        self.heliusAPIKey = helius
        self.etherscanAPIKey = etherscan
        self.infuraAPIKey = infura
        self.ankrAPIKey = ankr
        self.blockpiAPIKey = blockpi
        self.drpcAPIKey = drpc
        self.nodeRealAPIKey = nodeReal
        self.getblockAPIKey = getblock
        self.tenderlyAPIKey = tenderly
        self.oneRPCAPIKey = oneRPC
        self.ethereumRPC = ud.string(forKey: Keys.ethereumRPC) ?? evmDefault
        self.bitcoinAPI = ud.string(forKey: Keys.bitcoinAPI) ?? Defaults.bitcoinAPI
        self.litecoinAPI = ud.string(forKey: Keys.litecoinAPI) ?? Defaults.litecoinAPI
        self.tronAPI = ud.string(forKey: Keys.tronAPI) ?? Defaults.tronAPI
        self.solanaRPC = ud.string(forKey: Keys.solanaRPC) ?? solDefault
        self.evmChainId = chainId
        self.btcTestnet = ud.bool(forKey: Keys.btcTestnet)
        self.solDevnet = solDevnetFlag
        self.ethereumWSS = ud.string(forKey: Keys.ethereumWSS) ?? ""
        self.solanaWSS = ud.string(forKey: Keys.solanaWSS) ?? ""
    }

    func rpcURL(for chain: Chain) -> String {
        let raw: String
        switch chain {
        case .ethereum: raw = ethereumRPC
        case .bnb, .polygon, .arbitrum, .base, .avalanche, .optimism, .zksync, .linea, .scroll:
            // New EVM chains use hardcoded defaults for now; no per-chain
            // override field yet. Users can reach the same node via RPC
            // fallbacks if the default is unreachable.
            raw = chain.defaultEVMNetwork?.defaultRPC ?? ""
        case .bitcoin: raw = bitcoinAPI
        case .litecoin: raw = litecoinAPI
        case .solana: raw = solanaRPC
        case .tron: raw = tronAPI
        }
        return substituteAPIKey(in: raw, chain: chain)
    }

    /// Resolve the user-configured WebSocket URL for a chain, performing
    /// the same `{KEY}` → Keychain-backed-key substitution we do for HTTP
    /// RPC. Returns `nil` when the field is empty or the chain has no
    /// dedicated WSS slot.
    ///
    /// Background: paid providers (Alchemy / Infura / Helius) gate their
    /// `wss://` endpoints on the same API key as HTTP, so the template
    /// form `wss://sepolia.infura.io/ws/v3/{KEY}` must be expanded at
    /// connect time. Earlier builds consumed `ethereumWSS` raw, which
    /// forced users to paste the literal key into UserDefaults (plaintext
    /// on disk) and also broke whenever the stored value still contained
    /// a `{KEY}` placeholder.
    func wssURL(for chain: Chain) -> String? {
        let raw: String
        switch chain {
        case .ethereum: raw = ethereumWSS
        case .solana: raw = solanaWSS
        default: return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let resolved = substituteAPIKey(in: trimmed, chain: chain)
        // `substituteAPIKey` may fall back to a public HTTP endpoint when
        // the key is missing; callers expect an actual `wss://` URL, so
        // refuse to return a degraded http(s):// result here.
        guard resolved.hasPrefix("wss://") || resolved.hasPrefix("ws://") else {
            return nil
        }
        return resolved
    }

    /// Raw URL stored for the chain's primary field (before `{KEY}` substitution).
    /// Used by the settings UI so the "Switch endpoint" menu can compare
    /// against the exact string the user sees in the TextField. Returns nil
    /// for chains that don't have a dedicated field (secondary EVM chains).
    func fieldValue(for chain: Chain) -> String? {
        switch chain {
        case .ethereum: return ethereumRPC
        case .bitcoin: return bitcoinAPI
        case .litecoin: return litecoinAPI
        case .solana: return solanaRPC
        case .tron: return tronAPI
        default: return nil
        }
    }

    /// Set the user-visible URL field for a chain. No-op for chains without
    /// a dedicated field. Used by the "Switch endpoint" menu to swap providers
    /// with one tap.
    func setFieldValue(_ url: String, for chain: Chain) {
        switch chain {
        case .ethereum: ethereumRPC = url
        case .bitcoin: bitcoinAPI = url
        case .litecoin: litecoinAPI = url
        case .solana: solanaRPC = url
        case .tron: tronAPI = url
        default: break
        }
    }

    /// Reset only this chain's field to its built-in default, leaving the
    /// other chains (and the EVM / BTC / SOL network selectors) alone.
    /// Used by the per-section "恢复默认" link. The default we reset to
    /// depends on whether the user has a paid key configured — key present
    /// → paid template; key absent → free public endpoint.
    func resetField(for chain: Chain) {
        let hasKey = !alchemyAPIKey.isEmpty
        // Wipe URL-level cooldowns for this chain so the freshly-reset URL
        // isn't immediately suppressed by a stale entry from the URL we
        // just discarded. Safe to clear all: cooldowns are in-memory only
        // and will re-populate on the first real failure.
        RPCEndpointHealth.clearAll()
        switch chain {
        case .ethereum:
            if let net = EVMNetwork(rawValue: evmChainId) {
                ethereumRPC = net.effectiveDefaultRPC(hasPaidKey: hasKey)
            } else {
                ethereumRPC = Defaults.ethereumRPC
            }
        case .bitcoin:
            bitcoinAPI = (btcTestnet ? BitcoinNetwork.testnet : BitcoinNetwork.mainnet).defaultAPI
        case .litecoin:
            litecoinAPI = Defaults.litecoinAPI
        case .solana:
            let net = solDevnet ? SolanaNetwork.devnet : SolanaNetwork.mainnet
            solanaRPC = net.effectiveDefaultRPC(hasPaidKey: hasKey)
        case .tron:
            tronAPI = Defaults.tronAPI
        default:
            break
        }
    }

    /// Replace `{KEY}` placeholder in a URL template with the appropriate
    /// per-provider Keychain-stored API key. The provider is picked by URL
    /// host so a user who stores both Alchemy and Infura keys can freely
    /// paste either provider's URL and have the substitution route to the
    /// right key.
    ///
    /// When the URL contains `{KEY}` but the matched key is empty, we fall
    /// back to the free public endpoint for that (chain, network) so the
    /// app remains usable out-of-the-box while strongly preferring the
    /// paid provider once a key is configured. Without this fallback the
    /// templated URL would be sent to the server with `{KEY}` literal in
    /// the path, producing cryptic HTTP 404 / 401 errors.
    func substituteAPIKey(in url: String, chain: Chain) -> String {
        guard url.contains("{KEY}") else { return url }
        let host = URL(string: url)?.host?.lowercased() ?? ""
        let key: String
        if chain.isEVM {
            if host.contains("infura.io") {
                key = infuraAPIKey
            } else if host.contains("ankr.com") {
                key = ankrAPIKey
            } else if host.contains("blockpi.network") {
                key = blockpiAPIKey
            } else if host.contains("drpc.org") {
                key = drpcAPIKey
            } else if host.contains("nodereal.io") {
                key = nodeRealAPIKey
            } else if host.contains("getblock.io") {
                key = getblockAPIKey
            } else if host.contains("tenderly.co") {
                key = tenderlyAPIKey
            } else if host.contains("1rpc.io") {
                key = oneRPCAPIKey
            } else {
                // Alchemy is the default EVM key slot; also covers bare
                // template URLs that users haven't pointed at a specific
                // provider yet.
                key = alchemyAPIKey
            }
        } else {
            switch chain {
            case .solana:
                if host.contains("infura.io") { key = infuraAPIKey }
                else if host.contains("alchemy.com") { key = alchemyAPIKey }
                else if host.contains("ankr.com") { key = ankrAPIKey }
                else if host.contains("drpc.org") { key = drpcAPIKey }
                else if host.contains("getblock.io") { key = getblockAPIKey }
                else if host.contains("1rpc.io") { key = oneRPCAPIKey }
                else { key = heliusAPIKey }
            default: key = ""
            }
        }
        if key.isEmpty {
            return publicFallbackURL(for: chain) ?? url
        }
        return url.replacingOccurrences(of: "{KEY}", with: key)
    }

    /// Free public endpoint to use when a paid-provider template is
    /// selected but no API key is configured. Returns nil for chains
    /// without a known fallback (the caller then leaves the templated
    /// URL unchanged, preserving legacy behaviour).
    private func publicFallbackURL(for chain: Chain) -> String? {
        switch chain {
        case .ethereum:
            return EVMNetwork(rawValue: evmChainId)?.publicDefaultRPC
        case .solana:
            return (solDevnet ? SolanaNetwork.devnet : SolanaNetwork.mainnet).publicDefaultRPC
        case .polygon, .arbitrum, .base, .optimism, .bnb, .avalanche, .zksync, .linea, .scroll:
            return chain.defaultEVMNetwork?.publicDefaultRPC
        default:
            return nil
        }
    }

    func resetToDefaults() {
        applyPreset(.mainnet)
        RPCEndpointHealth.clearAll()
    }

    /// Short testnet badge for a given chain, or nil when the current
    /// network selection for that chain is mainnet.
    ///
    /// Used by wallet UI (list rows + detail hero) so users can tell at
    /// a glance whether they're looking at real-value funds. Labels stay
    /// short so they fit in a capsule next to the chain name. For EVM
    /// chains other than Ethereum (Polygon, Base, Arbitrum, Optimism,
    /// BNB, Avalanche, zkSync Era, Linea, Scroll) we only have a single
    /// mainnet wiring today, so this returns nil. Litecoin/Tron detect
    /// testnet purely from the API URL (no dedicated flag).
    func testnetBadge(for chain: Chain) -> String? {
        switch chain {
        case .ethereum:
            return EVMNetwork(rawValue: evmChainId) == .sepolia ? "Sepolia" : nil
        case .bitcoin:
            return btcTestnet ? "Testnet" : nil
        case .litecoin:
            return litecoinAPI.lowercased().contains("testnet") ? "Testnet" : nil
        case .solana:
            return solDevnet ? "Devnet" : nil
        case .tron:
            let api = tronAPI.lowercased()
            return (api.contains("shasta") || api.contains("nile")) ? "Shasta" : nil
        default:
            return nil
        }
    }

    /// Apply a named network preset (mainnet or testnet). Preset URLs are
    /// stored as Alchemy paid-provider templates. If the user has no
    /// Alchemy key, we down-convert to the equivalent public endpoint so
    /// the stored URL stays immediately usable instead of showing a
    /// literal `{KEY}` placeholder.
    func applyPreset(_ preset: NetworkPreset) {
        let hasKey = !alchemyAPIKey.isEmpty
        if hasKey {
            ethereumRPC = preset.ethereumRPC
            solanaRPC = preset.solanaRPC
        } else {
            let evm = EVMNetwork(rawValue: preset.evmChainId) ?? .mainnet
            ethereumRPC = evm.publicDefaultRPC
            let sol: SolanaNetwork = preset.solDevnet ? .devnet : .mainnet
            solanaRPC = sol.publicDefaultRPC
        }
        bitcoinAPI = preset.bitcoinAPI
        evmChainId = preset.evmChainId
        btcTestnet = preset.btcTestnet
        solDevnet = preset.solDevnet
    }

    private func save(_ value: String, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    // Persist API keys to Keychain rather than UserDefaults. Empty string
    // means "no key set" — we delete the item instead of storing an empty
    // blob, so the Keychain never holds placeholder rows.
    private func saveKeychain(_ value: String, forKey key: String) {
        do {
            if value.isEmpty {
                try KeychainManager.shared.delete(key: key)
            } else if let data = value.data(using: .utf8) {
                try KeychainManager.shared.store(key: key, data: data)
            }
        } catch {
            NSLog("[NetworkConfig] Keychain write failed for \(key): \(error)")
        }
    }

    private static func loadKeychainString(key: String) -> String {
        do {
            guard let data = try KeychainManager.shared.retrieve(key: key) else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            NSLog("[NetworkConfig] Keychain read failed for \(key): \(error)")
            return ""
        }
    }

    private func invalidateBalances() {
        Task { @MainActor in
            BalanceCache.shared.invalidateAll()
        }
    }

    // MARK: - Auto-swap helpers

    /// Swap `ethereumRPC` to the new chain's default when the previous value was
    /// a recognized default (public or Alchemy template) for *any* known chain.
    /// User-customized URLs are preserved untouched.
    private func autoSwapEthereumRPCIfDefault(previousChainId: UInt64) {
        guard previousChainId != evmChainId else { return }
        let publicDefaults = Set(EVMNetwork.allCases.map(\.publicDefaultRPC))
        let alchemyTemplates = Set(EVMNetwork.allCases.compactMap { RPCProviderTemplate.alchemy(evm: $0) })

        guard let newNet = EVMNetwork(rawValue: evmChainId) else { return }

        if alchemyTemplates.contains(ethereumRPC) {
            // User is on the paid Alchemy default — stay on the Alchemy
            // template for the new chain if one exists, else fall back to
            // the new chain's default (which is publicDefaultRPC for BNB).
            ethereumRPC = RPCProviderTemplate.alchemy(evm: newNet) ?? newNet.defaultRPC
        } else if publicDefaults.contains(ethereumRPC) {
            // User deliberately picked a public endpoint; keep them on a
            // public endpoint for the new chain.
            ethereumRPC = newNet.publicDefaultRPC
        }
    }

    private func autoSwapBitcoinAPIIfDefault(previousTestnet: Bool) {
        guard previousTestnet != btcTestnet else { return }
        let known: Set<String> = [BitcoinNetwork.mainnet.defaultAPI, BitcoinNetwork.testnet.defaultAPI]
        guard known.contains(bitcoinAPI) else { return }
        bitcoinAPI = (btcTestnet ? BitcoinNetwork.testnet : BitcoinNetwork.mainnet).defaultAPI
    }

    private func autoSwapSolanaRPCIfDefault(previousDevnet: Bool) {
        guard previousDevnet != solDevnet else { return }
        let known: Set<String> = [
            SolanaNetwork.mainnet.defaultRPC,
            SolanaNetwork.devnet.defaultRPC,
            SolanaNetwork.mainnet.publicDefaultRPC,
            SolanaNetwork.devnet.publicDefaultRPC,
        ]
        guard known.contains(solanaRPC) else { return }
        let target = solDevnet ? SolanaNetwork.devnet : SolanaNetwork.mainnet
        // Preserve public-vs-paid choice across the flip.
        if solanaRPC == SolanaNetwork.mainnet.publicDefaultRPC
            || solanaRPC == SolanaNetwork.devnet.publicDefaultRPC
        {
            solanaRPC = target.publicDefaultRPC
        } else {
            solanaRPC = target.defaultRPC
        }
    }

    /// When an Alchemy key is pasted (empty → non-empty) or removed
    /// (non-empty → empty), flip any stored URL that is currently on the
    /// "other default" to the matching new default. A user who hasn't
    /// customised `ethereumRPC` / `solanaRPC` will see:
    ///
    ///   * "No key configured" → URL shows the free public endpoint.
    ///   * "Key configured"    → URL shows the Alchemy paid template.
    ///
    /// User-customised URLs (anything not in the recognised default sets)
    /// are preserved untouched so we never clobber a hand-picked endpoint.
    private func autoSwapPaidPublicDefaultsOnKeyChange(oldKeyEmpty: Bool) {
        let newHasKey = !alchemyAPIKey.isEmpty
        guard oldKeyEmpty == newHasKey else { return }  // key toggled

        // --- EVM side ---
        let evmTemplates = Set(EVMNetwork.allCases.compactMap {
            RPCProviderTemplate.alchemy(evm: $0)
        })
        let evmPublics = Set(EVMNetwork.allCases.map(\.publicDefaultRPC))
        if let net = EVMNetwork(rawValue: evmChainId) {
            if newHasKey, evmPublics.contains(ethereumRPC) {
                ethereumRPC = net.defaultRPC
            } else if !newHasKey, evmTemplates.contains(ethereumRPC) {
                ethereumRPC = net.publicDefaultRPC
            }
        }

        // --- Solana side ---
        let solTemplates: Set<String> = [
            SolanaNetwork.mainnet.defaultRPC,
            SolanaNetwork.devnet.defaultRPC,
        ]
        let solPublics: Set<String> = [
            SolanaNetwork.mainnet.publicDefaultRPC,
            SolanaNetwork.devnet.publicDefaultRPC,
        ]
        let solNet: SolanaNetwork = solDevnet ? .devnet : .mainnet
        if newHasKey, solPublics.contains(solanaRPC) {
            solanaRPC = solNet.defaultRPC
        } else if !newHasKey, solTemplates.contains(solanaRPC) {
            solanaRPC = solNet.publicDefaultRPC
        }
    }

    /// One-shot migration of explicitly-dead public RPC endpoints that
    /// were shipped as defaults in earlier builds. A stored value that
    /// equals one of these gets reset so the user falls through to the
    /// current default on next launch, without clobbering any URL the
    /// user has deliberately customised.
    ///
    /// Only endpoints that are **confirmed 100% dead** (API disabled,
    /// "tenant disabled", etc.) go here — merely slow or rate-limited
    /// endpoints should be left alone so users who selected them on
    /// purpose are not second-guessed.
    private static func migrateDeadEndpoints(_ ud: UserDefaults) {
        let deadEthereum: Set<String> = [
            "https://polygon-rpc.com",                 // "tenant disabled"
            "https://eth-sepolia.public.blastapi.io",  // "Blast API is no longer available"
        ]
        if let stored = ud.string(forKey: Keys.ethereumRPC),
           deadEthereum.contains(stored)
        {
            ud.removeObject(forKey: Keys.ethereumRPC)
        }
        migrateBrokenWSS(ud, key: Keys.ethereumWSS)
        migrateBrokenWSS(ud, key: Keys.solanaWSS)
    }

    /// Reset stored WSS entries that clearly contain a leaked / truncated
    /// API key instead of the `{KEY}` template placeholder.
    ///
    /// Prior to the WSS-templating fix, the Settings UI stored whatever
    /// the user typed verbatim. Users who pasted an Infura key directly
    /// into the WSS field (or who hit the field edit before it accepted
    /// the full paste) ended up with URLs like
    /// `wss://sepolia.infura.io/ws/v3/809b2` — a truncated key, no
    /// placeholder, unusable. We recognise those by: path ends in
    /// `/ws/v3/` + a short non-hex-length segment that isn't `{KEY}`, and
    /// wipe the slot so the template-form placeholder takes over.
    private static func migrateBrokenWSS(_ ud: UserDefaults, key: String) {
        guard let stored = ud.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !stored.isEmpty,
              stored.hasPrefix("wss://") || stored.hasPrefix("ws://"),
              !stored.contains("{KEY}"),
              let url = URL(string: stored)
        else { return }
        // Infura keys are 32 hex chars; Alchemy keys are 32+; any path
        // tail ≥ 20 chars is almost certainly a deliberate full key the
        // user wants to keep. Anything shorter that sits in a known
        // provider path slot is a malformed remnant.
        let lastComponent = url.lastPathComponent
        let queryKey = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name.lowercased() == "api-key" })?.value ?? ""
        let candidate = !queryKey.isEmpty ? queryKey : lastComponent
        if !candidate.isEmpty && candidate.count < 20 {
            NSLog("[NetworkConfig] Clearing malformed WSS '\(key)' = '\(stored)'")
            ud.removeObject(forKey: key)
        }
    }

    // MARK: - URL validation

    struct URLValidation {
        let ok: Bool
        let warning: String?   // non-nil when we want to surface caution
    }

    /// Validate a user-entered RPC URL. Returns a warning for http://, empty,
    /// or malformed values. An empty string is flagged as invalid.
    static func validate(url: String) -> URLValidation {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return URLValidation(ok: false, warning: "URL is empty")
        }
        guard let parsed = URL(string: trimmed), let scheme = parsed.scheme?.lowercased() else {
            return URLValidation(ok: false, warning: "Not a valid URL")
        }
        switch scheme {
        case "https", "wss":
            return URLValidation(ok: true, warning: nil)
        case "http", "ws":
            return URLValidation(ok: true, warning: "Insecure scheme — traffic can be tampered with")
        default:
            return URLValidation(ok: false, warning: "Unsupported scheme (\(scheme))")
        }
    }
}

// MARK: - EVM / BTC / SOL network tables

/// Supported EVM networks exposed in the Picker, each with a recommended
/// public RPC. Adding a row here makes it available in settings.
enum EVMNetwork: UInt64, CaseIterable, Identifiable {
    case mainnet = 1
    case optimism = 10
    case bnb = 56
    case polygon = 137
    case base = 8453
    case arbitrumOne = 42161
    case avalanche = 43114
    case zkSyncEra = 324
    case linea = 59144
    case scroll = 534352
    case sepolia = 11155111

    var id: UInt64 { rawValue }

    var displayName: String {
        switch self {
        case .mainnet: return "Ethereum Mainnet"
        case .sepolia: return "Sepolia Testnet"
        case .polygon: return "Polygon"
        case .arbitrumOne: return "Arbitrum One"
        case .base: return "Base"
        case .optimism: return "Optimism"
        case .bnb: return "BNB Smart Chain"
        case .avalanche: return "Avalanche C-Chain"
        case .zkSyncEra: return "zkSync Era"
        case .linea: return "Linea"
        case .scroll: return "Scroll"
        }
    }

    /// Preferred default: Alchemy paid-provider template with `{KEY}`
    /// placeholder, substituted from Keychain at RPC-call time. Paid nodes
    /// are required for reliable production traffic — free public endpoints
    /// are aggressively rate-limited, geo-throttled, and prone to "empty
    /// result" / "tenant disabled" errors that manifest as signing or
    /// balance-check failures for end users.
    ///
    /// When no Alchemy key is set, `NetworkConfig.substituteAPIKey` falls
    /// back to `publicDefaultRPC`, so unconfigured installs still function.
    /// BNB Chain has no Alchemy coverage, so it keeps the public endpoint.
    var defaultRPC: String {
        if let tmpl = RPCProviderTemplate.alchemy(evm: self) {
            return tmpl
        }
        return publicDefaultRPC
    }

    /// Context-aware default URL: returns the Alchemy paid template when
    /// the user has an Alchemy key configured, and the free public endpoint
    /// otherwise. Used at first-launch and on key-set/unset transitions so
    /// the stored URL field matches the user's available credentials.
    func effectiveDefaultRPC(hasPaidKey: Bool) -> String {
        return hasPaidKey ? defaultRPC : publicDefaultRPC
    }

    /// Last-resort free public endpoint, used either (a) when the user
    /// explicitly picks a free provider in Settings, or (b) implicitly as
    /// a fallback when the templated paid URL is present but no API key
    /// is configured.
    ///
    /// PublicNode runs a well-distributed anycast fleet and is the most
    /// reliable free option across chains, so we standardise on it where
    /// it exists. llama / blastapi / polygon-rpc.com have all had regional
    /// outages or "tenant disabled" errors (observed Apr 2026).
    var publicDefaultRPC: String {
        switch self {
        case .mainnet: return "https://ethereum-rpc.publicnode.com"
        case .sepolia: return "https://ethereum-sepolia-rpc.publicnode.com"
        case .polygon: return "https://polygon-bor-rpc.publicnode.com"
        case .arbitrumOne: return "https://arb1.arbitrum.io/rpc"
        case .base: return "https://mainnet.base.org"
        case .optimism: return "https://mainnet.optimism.io"
        case .bnb: return "https://bsc-dataseed.bnbchain.org"
        case .avalanche: return "https://api.avax.network/ext/bc/C/rpc"
        case .zkSyncEra: return "https://mainnet.era.zksync.io"
        case .linea: return "https://rpc.linea.build"
        case .scroll: return "https://rpc.scroll.io"
        }
    }

    /// Native currency ticker used by the UI for balance labels.
    var nativeSymbol: String {
        switch self {
        case .mainnet, .sepolia, .arbitrumOne, .base, .optimism, .zkSyncEra, .linea, .scroll:
            return "ETH"
        case .polygon: return "POL"
        case .bnb: return "BNB"
        case .avalanche: return "AVAX"
        }
    }
}

enum BitcoinNetwork {
    case mainnet, testnet
    var defaultAPI: String {
        // mempool.space runs the same esplora REST API as blockstream.info
        // and has better global CDN coverage — blockstream has had CN/SEA
        // reachability issues. AddressFormatter already links to mempool
        // for the web explorer, so the two now agree.
        switch self {
        case .mainnet: return "https://mempool.space/api"
        case .testnet: return "https://mempool.space/testnet/api"
        }
    }
}

enum SolanaNetwork {
    case mainnet, devnet

    /// Preferred default: Alchemy Solana paid-provider template. Same
    /// rationale as `EVMNetwork.defaultRPC` — free public Solana endpoints
    /// (including PublicNode and Labs' mainnet-beta) aggressively throttle
    /// or geo-reject requests, so a paid key is the baseline for a usable
    /// wallet. When no Alchemy key is set, `substituteAPIKey` falls back
    /// to `publicDefaultRPC`.
    var defaultRPC: String {
        return RPCProviderTemplate.alchemySolana(mainnet: self == .mainnet)
    }

    /// Fallback free endpoint when no paid key is configured.
    var publicDefaultRPC: String {
        switch self {
        case .mainnet: return "https://solana-rpc.publicnode.com"
        case .devnet: return "https://api.devnet.solana.com"
        }
    }

    /// Context-aware default: paid template when a key is configured,
    /// free public endpoint otherwise. See `EVMNetwork.effectiveDefaultRPC`.
    func effectiveDefaultRPC(hasPaidKey: Bool) -> String {
        return hasPaidKey ? defaultRPC : publicDefaultRPC
    }
}

// MARK: - Network Presets

struct NetworkPreset: Identifiable {
    let id: String
    let name: String
    let ethereumRPC: String
    let bitcoinAPI: String
    let solanaRPC: String
    let evmChainId: UInt64
    let btcTestnet: Bool
    let solDevnet: Bool

    static let mainnet = NetworkPreset(
        id: "mainnet", name: "Mainnet",
        ethereumRPC: EVMNetwork.mainnet.defaultRPC,
        bitcoinAPI: BitcoinNetwork.mainnet.defaultAPI,
        solanaRPC: SolanaNetwork.mainnet.defaultRPC,
        evmChainId: EVMNetwork.mainnet.rawValue, btcTestnet: false, solDevnet: false
    )

    static let testnet = NetworkPreset(
        id: "testnet", name: "Testnet",
        ethereumRPC: EVMNetwork.sepolia.defaultRPC,
        bitcoinAPI: BitcoinNetwork.testnet.defaultAPI,
        solanaRPC: SolanaNetwork.devnet.defaultRPC,
        evmChainId: EVMNetwork.sepolia.rawValue, btcTestnet: true, solDevnet: true
    )

    static let all: [NetworkPreset] = [.mainnet, .testnet]
}

// MARK: - Network Reachability

actor NetworkStatus {
    static let shared = NetworkStatus()

    /// Real reachability probe for a given chain. Uses the actual JSON-RPC
    /// health method instead of a meaningless HEAD request (RPC endpoints
    /// typically 405 HEAD which was previously treated as "connected").
    func check(chain: Chain, config: NetworkConfig) async -> Bool {
        let service = BlockchainService()
        do {
            if chain.isEVM {
                _ = try await service.ethBlockNumber(rpcURL: config.rpcURL(for: chain))
                return true
            }
            switch chain {
            case .bitcoin:
                let base = config.bitcoinAPI
                guard let url = URL(string: "\(base)/blocks/tip/height") else { return false }
                var req = URLRequest(url: url, timeoutInterval: 5)
                req.httpMethod = "GET"
                let (_, response) = try await PinnedURLSession.shared.session.data(for: req)
                if let http = response as? HTTPURLResponse { return (200...299).contains(http.statusCode) }
                return false
            case .litecoin:
                let base = config.litecoinAPI
                guard let url = URL(string: "\(base)/blocks/tip/height") else { return false }
                var req = URLRequest(url: url, timeoutInterval: 5)
                req.httpMethod = "GET"
                let (_, response) = try await PinnedURLSession.shared.session.data(for: req)
                if let http = response as? HTTPURLResponse { return (200...299).contains(http.statusCode) }
                return false
            case .solana:
                _ = try await service.solHealth(rpcURL: config.solanaRPC)
                return true
            case .tron:
                // TronGrid exposes `/wallet/getnowblock` as a lightweight liveness probe.
                let base = config.tronAPI
                guard let url = URL(string: "\(base)/wallet/getnowblock") else { return false }
                var req = URLRequest(url: url, timeoutInterval: 5)
                req.httpMethod = "POST"
                req.httpBody = Data("{}".utf8)
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let (_, response) = try await PinnedURLSession.shared.session.data(for: req)
                if let http = response as? HTTPURLResponse { return (200...299).contains(http.statusCode) }
                return false
            default:
                return false
            }
        } catch {
            return false
        }
    }

    /// Check if the active chain endpoints are reachable.
    func checkAll(config: NetworkConfig) async -> [Chain: Bool] {
        var result: [Chain: Bool] = [:]
        await withTaskGroup(of: (Chain, Bool).self) { group in
            for chain in Chain.allCases {
                group.addTask { (chain, await self.check(chain: chain, config: config)) }
            }
            for await (chain, ok) in group { result[chain] = ok }
        }
        return result
    }
}

// MARK: - Keys & Defaults

private extension NetworkConfig {
    enum Keys {
        static let ethereumRPC = "com.horcrux.rpc.ethereum"
        static let bitcoinAPI = "com.horcrux.rpc.bitcoin"
        static let litecoinAPI = "com.horcrux.rpc.litecoin"
        static let solanaRPC = "com.horcrux.rpc.solana"
        static let tronAPI = "com.horcrux.rpc.tron"
        static let evmChainId = "com.horcrux.rpc.evmChainId"
        static let btcTestnet = "com.horcrux.rpc.btcTestnet"
        static let solDevnet = "com.horcrux.rpc.solDevnet"
        static let alchemyKey = "com.horcrux.rpc.alchemyAPIKey"
        static let heliusKey = "com.horcrux.rpc.heliusAPIKey"
        static let etherscanKey = "com.horcrux.rpc.etherscanAPIKey"
        static let infuraKey = "com.horcrux.rpc.infuraAPIKey"
        static let ankrKey = "com.horcrux.rpc.ankrAPIKey"
        static let blockpiKey = "com.horcrux.rpc.blockpiAPIKey"
        static let drpcKey = "com.horcrux.rpc.drpcAPIKey"
        static let nodeRealKey = "com.horcrux.rpc.nodeRealAPIKey"
        static let getblockKey = "com.horcrux.rpc.getblockAPIKey"
        static let tenderlyKey = "com.horcrux.rpc.tenderlyAPIKey"
        static let oneRPCKey = "com.horcrux.rpc.oneRPCAPIKey"
        static let ethereumWSS = "com.horcrux.rpc.ethereumWSS"
        static let solanaWSS = "com.horcrux.rpc.solanaWSS"
    }

    enum Defaults {
        static let ethereumRPC = EVMNetwork.mainnet.defaultRPC
        static let bitcoinAPI = BitcoinNetwork.mainnet.defaultAPI
        static let litecoinAPI = "https://litecoinspace.org/api"
        static let solanaRPC = SolanaNetwork.mainnet.defaultRPC
        static let tronAPI = "https://api.trongrid.io"
    }
}

// MARK: - Provider templates (for API-key users)

/// URL templates with `{KEY}` placeholder for popular paid providers.
/// The key itself lives in Keychain via `NetworkConfig.alchemyAPIKey` /
/// `heliusAPIKey` and is substituted in at RPC-call time.
enum RPCProviderTemplate {
    /// Alchemy EVM template for the given chain. `{KEY}` is substituted at RPC time.
    static func alchemy(evm: EVMNetwork) -> String? {
        switch evm {
        case .mainnet: return "https://eth-mainnet.g.alchemy.com/v2/{KEY}"
        case .sepolia: return "https://eth-sepolia.g.alchemy.com/v2/{KEY}"
        case .polygon: return "https://polygon-mainnet.g.alchemy.com/v2/{KEY}"
        case .arbitrumOne: return "https://arb-mainnet.g.alchemy.com/v2/{KEY}"
        case .base: return "https://base-mainnet.g.alchemy.com/v2/{KEY}"
        case .optimism: return "https://opt-mainnet.g.alchemy.com/v2/{KEY}"
        case .avalanche: return "https://avax-mainnet.g.alchemy.com/v2/{KEY}"
        case .zkSyncEra: return "https://zksync-mainnet.g.alchemy.com/v2/{KEY}"
        case .linea: return "https://linea-mainnet.g.alchemy.com/v2/{KEY}"
        case .scroll: return "https://scroll-mainnet.g.alchemy.com/v2/{KEY}"
        // Alchemy does not serve BNB Chain; users must use public/QuickNode.
        case .bnb: return nil
        }
    }

    static func helius(mainnet: Bool) -> String {
        mainnet
            ? "https://mainnet.helius-rpc.com/?api-key={KEY}"
            : "https://devnet.helius-rpc.com/?api-key={KEY}"
    }

    /// Infura Solana template. Infura's Solana product lives on the same
    /// account as their EVM endpoints, so a single Project ID (stored in
    /// `infuraAPIKey`) works for both. `mainnet=false` yields the devnet
    /// host.
    static func infuraSolana(mainnet: Bool) -> String {
        mainnet
            ? "https://solana-mainnet.infura.io/v3/{KEY}"
            : "https://solana-devnet.infura.io/v3/{KEY}"
    }

    /// Alchemy Solana template. Same account + key as Alchemy EVM.
    static func alchemySolana(mainnet: Bool) -> String {
        mainnet
            ? "https://solana-mainnet.g.alchemy.com/v2/{KEY}"
            : "https://solana-devnet.g.alchemy.com/v2/{KEY}"
    }

    /// Infura EVM template for the given chain. `{KEY}` is the project ID.
    /// Infura covers a different set of L2s than Alchemy — notably they
    /// support Polygon PoS, Arbitrum, Optimism, Base, Linea, zkSync, BNB,
    /// and Avalanche, but not Scroll or Sepolia under the same host pattern.
    static func infura(evm: EVMNetwork) -> String? {
        switch evm {
        case .mainnet: return "https://mainnet.infura.io/v3/{KEY}"
        case .sepolia: return "https://sepolia.infura.io/v3/{KEY}"
        case .polygon: return "https://polygon-mainnet.infura.io/v3/{KEY}"
        case .arbitrumOne: return "https://arbitrum-mainnet.infura.io/v3/{KEY}"
        case .optimism: return "https://optimism-mainnet.infura.io/v3/{KEY}"
        case .base: return "https://base-mainnet.infura.io/v3/{KEY}"
        case .linea: return "https://linea-mainnet.infura.io/v3/{KEY}"
        case .avalanche: return "https://avalanche-mainnet.infura.io/v3/{KEY}"
        case .zkSyncEra: return "https://zksync-mainnet.infura.io/v3/{KEY}"
        case .bnb: return "https://bnbsmartchain-mainnet.infura.io/v3/{KEY}"
        case .scroll: return nil
        }
    }

    /// Ankr Premium EVM template. `{KEY}` is appended as the path suffix;
    /// without a key the same URL works as the public endpoint.
    static func ankr(evm: EVMNetwork) -> String? {
        let chain: String
        switch evm {
        case .mainnet: chain = "eth"
        case .sepolia: chain = "eth_sepolia"
        case .polygon: chain = "polygon"
        case .arbitrumOne: chain = "arbitrum"
        case .optimism: chain = "optimism"
        case .base: chain = "base"
        case .avalanche: chain = "avalanche"
        case .bnb: chain = "bsc"
        case .zkSyncEra: chain = "zksync_era"
        case .linea: chain = "linea"
        case .scroll: chain = "scroll"
        }
        return "https://rpc.ankr.com/\(chain)/{KEY}"
    }

    /// Ankr Premium Solana template.
    static func ankrSolana() -> String {
        "https://rpc.ankr.com/solana/{KEY}"
    }

    /// GetBlock EVM template. GetBlock's shared endpoint `go.getblock.io/{TOKEN}/`
    /// is chain-agnostic — the token itself is bound to a chain on their
    /// dashboard. Returns the same URL for every supported EVM chain;
    /// returns `nil` for chains not offered by GetBlock (none in practice,
    /// but kept for parity with other providers).
    static func getblock(evm: EVMNetwork) -> String? {
        "https://go.getblock.io/{KEY}/"
    }

    /// GetBlock Solana template. Same URL shape as EVM/BTC/LTC; the
    /// access token the user pastes must be a Solana-scoped one.
    static func getblockSolana(mainnet _: Bool) -> String {
        "https://go.getblock.io/{KEY}/"
    }

    /// Tenderly Gateway EVM template. Per-chain subdomain + `{KEY}` path.
    /// Same key works across all EVM chains on the user's Tenderly account.
    static func tenderly(evm: EVMNetwork) -> String? {
        switch evm {
        case .mainnet: return "https://mainnet.gateway.tenderly.co/{KEY}"
        case .sepolia: return "https://sepolia.gateway.tenderly.co/{KEY}"
        case .polygon: return "https://polygon.gateway.tenderly.co/{KEY}"
        case .arbitrumOne: return "https://arbitrum.gateway.tenderly.co/{KEY}"
        case .optimism: return "https://optimism.gateway.tenderly.co/{KEY}"
        case .base: return "https://base.gateway.tenderly.co/{KEY}"
        case .linea: return "https://linea.gateway.tenderly.co/{KEY}"
        case .avalanche: return "https://avalanche.gateway.tenderly.co/{KEY}"
        case .bnb: return "https://bnb.gateway.tenderly.co/{KEY}"
        case .zkSyncEra, .scroll: return nil
        }
    }

    /// 1RPC EVM template. Key is in the path segment before the chain slug:
    /// `https://1rpc.io/{KEY}/<chain>`.
    static func oneRPC(evm: EVMNetwork) -> String? {
        let slug: String
        switch evm {
        case .mainnet: slug = "eth"
        case .sepolia: slug = "sepolia"
        case .polygon: slug = "matic"
        case .arbitrumOne: slug = "arb"
        case .optimism: slug = "op"
        case .base: slug = "base"
        case .linea: slug = "linea"
        case .bnb: slug = "bnb"
        case .avalanche: slug = "avax"
        case .zkSyncEra: slug = "zksync-era"
        case .scroll: slug = "scroll"
        }
        return "https://1rpc.io/{KEY}/\(slug)"
    }

    /// 1RPC Solana template. Same key as 1RPC EVM — one account covers both.
    static func oneRPCSolana(mainnet: Bool) -> String? {
        mainnet ? "https://1rpc.io/{KEY}/sol" : nil
    }

    /// BlockPI EVM template. `{KEY}` is appended as the path suffix.
    /// BlockPI does not support Sepolia under the same pattern.
    static func blockpi(evm: EVMNetwork) -> String? {
        let chain: String
        switch evm {
        case .mainnet: chain = "ethereum"
        case .polygon: chain = "polygon"
        case .arbitrumOne: chain = "arbitrum"
        case .optimism: chain = "optimism"
        case .base: chain = "base"
        case .avalanche: chain = "avalanche"
        case .bnb: chain = "bsc"
        case .zkSyncEra: chain = "zksync"
        case .linea: chain = "linea"
        case .scroll: chain = "scroll"
        case .sepolia: return nil
        }
        return "https://\(chain).blockpi.network/v1/rpc/{KEY}"
    }

    /// dRPC load-balancer template. `{KEY}` is the user's `dkey`; the free
    /// tier works without it but is rate-limited.
    static func drpc(evm: EVMNetwork) -> String? {
        let network: String
        switch evm {
        case .mainnet: network = "ethereum"
        case .sepolia: network = "sepolia"
        case .polygon: network = "polygon"
        case .arbitrumOne: network = "arbitrum"
        case .optimism: network = "optimism"
        case .base: network = "base"
        case .avalanche: network = "avalanche"
        case .bnb: network = "bsc"
        case .zkSyncEra: network = "zksync"
        case .linea: network = "linea"
        case .scroll: network = "scroll"
        }
        return "https://lb.drpc.org/ogrpc?network=\(network)&dkey={KEY}"
    }

    static func drpcSolana() -> String {
        "https://lb.drpc.org/ogrpc?network=solana&dkey={KEY}"
    }

    /// NodeReal MegaNode template. NodeReal's coverage is strongest on BNB
    /// Smart Chain, opBNB and a handful of L2s; returns `nil` for chains
    /// where NodeReal doesn't offer a first-party endpoint.
    static func nodeReal(evm: EVMNetwork) -> String? {
        switch evm {
        case .mainnet: return "https://eth-mainnet.nodereal.io/v1/{KEY}"
        case .bnb: return "https://bsc-mainnet.nodereal.io/v1/{KEY}"
        case .polygon: return "https://polygon-mainnet.nodereal.io/v1/{KEY}"
        case .arbitrumOne: return "https://open-platform.nodereal.io/{KEY}/arbitrum-nitro/"
        case .optimism: return "https://opt-mainnet.nodereal.io/v1/{KEY}"
        case .base: return "https://base-mainnet.nodereal.io/v1/{KEY}"
        case .avalanche: return "https://avalanche-mainnet.nodereal.io/v1/{KEY}"
        case .sepolia, .zkSyncEra, .linea, .scroll: return nil
        }
    }
}

// MARK: - Provider identification

/// Recognises the provider behind an RPC URL so the UI can show a "Alchemy"
/// or "PublicNode (公共)" tag. Used purely for display — never for routing.
enum RPCProvider {
    case publicNode, alchemy, helius, infura, quickNode, blockPI, nodeReal, blockstream, mempoolSpace, llamaNodes,
         ankr, tronGrid, dRPC, baseOrg, optimismIO, bnbChain, litecoinSpace,
         avaxNetwork, zksync, linea, scroll, solanaLabs, unknown

    /// Human-readable label, e.g. "PublicNode"
    var label: String {
        switch self {
        case .publicNode: return "PublicNode"
        case .alchemy: return "Alchemy"
        case .helius: return "Helius"
        case .infura: return "Infura"
        case .quickNode: return "QuickNode"
        case .blockPI: return "BlockPI"
        case .nodeReal: return "NodeReal"
        case .blockstream: return "Blockstream"
        case .mempoolSpace: return "mempool.space"
        case .llamaNodes: return "LlamaNodes"
        case .ankr: return "Ankr"
        case .tronGrid: return "TronGrid"
        case .dRPC: return "dRPC"
        case .baseOrg: return "Base (官方)"
        case .optimismIO: return "Optimism (官方)"
        case .bnbChain: return "BNB Chain (官方)"
        case .litecoinSpace: return "litecoinspace"
        case .avaxNetwork: return "Avalanche (官方)"
        case .zksync: return "zkSync (官方)"
        case .linea: return "Linea (官方)"
        case .scroll: return "Scroll (官方)"
        case .solanaLabs: return "Solana Labs"
        case .unknown: return ""
        }
    }

    /// `true` when the provider runs without an API key and is likely to log
    /// visitor IPs. Drives the "公共" tag and the privacy-warning tooltip.
    var isPublic: Bool {
        switch self {
        case .alchemy, .helius, .infura, .quickNode, .blockPI, .nodeReal: return false
        default: return true
        }
    }

    /// Short category tag shown next to the provider label. Empty for
    /// unknown providers.
    var tag: String {
        switch self {
        case .alchemy, .helius, .infura, .quickNode, .blockPI, .nodeReal: return "付费"
        case .unknown: return ""
        default: return "公共"
        }
    }

    static func identify(_ urlString: String) -> RPCProvider {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return .unknown }
        if host.contains("publicnode.com") { return .publicNode }
        if host.contains("alchemy.com") { return .alchemy }
        if host.contains("helius-rpc.com") || host.contains("helius.xyz") { return .helius }
        if host.contains("infura.io") { return .infura }
        if host.contains("quiknode.pro") || host.contains("quicknode.com") { return .quickNode }
        if host.contains("blockpi.network") { return .blockPI }
        if host.contains("nodereal.io") { return .nodeReal }
        if host.contains("blockstream.info") { return .blockstream }
        if host.contains("mempool.space") { return .mempoolSpace }
        if host.contains("llamarpc.com") || host.contains("llamanodes.com") { return .llamaNodes }
        if host.contains("ankr.com") { return .ankr }
        if host.contains("trongrid.io") || host.contains("tronstack.io") { return .tronGrid }
        if host.contains("drpc.org") { return .dRPC }
        if host.contains("base.org") { return .baseOrg }
        if host.contains("optimism.io") { return .optimismIO }
        if host.contains("bnbchain.org") || host.contains("defibit.io") { return .bnbChain }
        if host.contains("litecoinspace.org") { return .litecoinSpace }
        if host.contains("avax.network") { return .avaxNetwork }
        if host.contains("zksync.io") { return .zksync }
        if host.contains("linea.build") { return .linea }
        if host.contains("scroll.io") { return .scroll }
        if host.contains("solana.com") { return .solanaLabs }
        return .unknown
    }
}

// MARK: - Fallback RPC endpoints

/// Public fallback endpoints tried in order when the primary fails with a
/// transport-level error. Keeps read-path available even when llamarpc or
/// mainnet-beta goes down.
enum RPCFallbacks {
    static func endpoints(for chain: Chain, config: NetworkConfig) -> [String] {
        // New EVM chains each map to a fixed EVMNetwork; re-use the same
        // mainnet fallback table as Ethereum once the network is resolved.
        if chain.isEVM, chain != .ethereum, let net = chain.defaultEVMNetwork {
            return endpoints(forEVMNetwork: net)
        }
        switch chain {
        case .ethereum:
            guard let net = EVMNetwork(rawValue: config.evmChainId) else { return [] }
            return endpoints(forEVMNetwork: net)
        case .bitcoin:
            return config.btcTestnet
                ? ["https://blockstream.info/testnet/api", "https://mempool.space/testnet/api"]
                : ["https://blockstream.info/api", "https://mempool.space/api"]
        case .litecoin:
            return [
                "https://litecoinspace.org/api"
            ]
        case .solana:
            return config.solDevnet
                ? ["https://api.devnet.solana.com"]
                : [
                    "https://api.mainnet-beta.solana.com",
                    "https://solana.publicnode.com"
                ]
        case .tron:
            return [
                "https://api.trongrid.io",
                "https://api.tronstack.io",
                "https://api.shasta.trongrid.io",
                "https://nile.trongrid.io"
            ]
        default:
            return []
        }
    }

    /// Mainnet RPC fallback table keyed by EVMNetwork. Shared by Ethereum
    /// (when evmChainId resolves to a known network) and by each of the
    /// first-class EVM Chain cases.
    private static func endpoints(forEVMNetwork net: EVMNetwork) -> [String] {
        switch net {
        case .mainnet:
            return [
                "https://eth.llamarpc.com",
                "https://ethereum.publicnode.com"
            ]
        case .sepolia:
            return [
                "https://eth-sepolia.public.blastapi.io",
                "https://ethereum-sepolia.publicnode.com"
            ]
        case .polygon:
            return [
                "https://polygon-rpc.com",
                "https://polygon.llamarpc.com",
                "https://polygon.publicnode.com"
            ]
        case .arbitrumOne:
            return [
                "https://arb1.arbitrum.io/rpc",
                "https://arbitrum.llamarpc.com",
                "https://arbitrum.publicnode.com"
            ]
        case .base:
            return [
                "https://mainnet.base.org",
                "https://base.llamarpc.com",
                "https://base.publicnode.com"
            ]
        case .optimism:
            return [
                "https://mainnet.optimism.io",
                "https://optimism.llamarpc.com",
                "https://optimism.publicnode.com"
            ]
        case .bnb:
            return [
                "https://bsc-dataseed.bnbchain.org",
                "https://bsc-dataseed1.defibit.io",
                "https://bsc.publicnode.com"
            ]
        case .avalanche:
            return [
                "https://api.avax.network/ext/bc/C/rpc",
                "https://avalanche.publicnode.com"
                // Ankr removed from free list (Apr 2026): the public
                // `rpc.ankr.com/*` endpoints now reject keyless requests
                // with HTTP 401, producing retry noise and no useful
                // fallback. Ankr remains available as a paid provider
                // template via `RPCProviderTemplate.ankr(evm:)`.
            ]
        case .zkSyncEra:
            return [
                "https://mainnet.era.zksync.io",
                "https://zksync.drpc.org"
            ]
        case .linea:
            return [
                "https://rpc.linea.build",
                "https://linea.drpc.org"
            ]
        case .scroll:
            return [
                "https://rpc.scroll.io",
                "https://scroll.drpc.org"
            ]
        }
    }

    /// Build the actual ordered attempt list starting from the user's
    /// configured URL, then any public fallbacks (deduplicated).
    static func orderedAttempts(for chain: Chain, config: NetworkConfig) -> [String] {
        let primary = config.rpcURL(for: chain)
        let fallbacks = endpoints(for: chain, config: config)
        var seen = Set<String>()
        var out: [String] = []
        for url in [primary] + fallbacks where !seen.contains(url) {
            seen.insert(url)
            out.append(url)
        }
        return out
    }

    /// Ordered attempts with per-URL cooldown filtering applied.
    ///
    /// URLs that recently answered with 401/403 (auth failure) are hidden
    /// for 30 minutes; URLs that recently failed with transient errors
    /// are hidden for 5 minutes. If *every* candidate is currently cooling,
    /// the full `orderedAttempts` list is returned unchanged — a cool
    /// endpoint is still better than no endpoint. See `RPCEndpointHealth`.
    static func resolvedAttempts(for chain: Chain, config: NetworkConfig) -> [String] {
        let all = orderedAttempts(for: chain, config: config)
        let healthy = all.filter { !RPCEndpointHealth.isCoolingDown($0) }
        return healthy.isEmpty ? all : healthy
    }
}

/// URL-level cooldown registry used by the RPC fallback router.
///
/// Keyed by full URL (not provider). Survives app lifetime but not
/// relaunches — intentional: after a relaunch the user probably wants
/// one more attempt before we lock an endpoint out again.
///
/// All state is guarded by a private serial queue so the store can be
/// touched from any actor without external synchronisation.
enum RPCEndpointHealth {
    private static let queue = DispatchQueue(label: "com.horcrux.rpc.health")
    private static var cooldowns: [String: Date] = [:]

    /// 401 / 403 / -32000 Unauthorized. Endpoint is almost certainly
    /// behind a paid tier or revoked key; no point retrying for a while.
    static let authCooldown: TimeInterval = 30 * 60
    /// 5xx / timeout / URLError. Endpoint had a bad moment; brief cool-off
    /// gives it time to recover before we poll again.
    static let transientCooldown: TimeInterval = 5 * 60

    static func markAuthFailed(_ url: String) {
        queue.sync { cooldowns[url] = Date().addingTimeInterval(authCooldown) }
    }

    static func markTransientFailed(_ url: String) {
        queue.sync { cooldowns[url] = Date().addingTimeInterval(transientCooldown) }
    }

    static func markOk(_ url: String) {
        queue.sync { cooldowns.removeValue(forKey: url); return }
    }

    static func isCoolingDown(_ url: String) -> Bool {
        queue.sync {
            guard let until = cooldowns[url] else { return false }
            if until <= Date() {
                cooldowns.removeValue(forKey: url)
                return false
            }
            return true
        }
    }

    /// Clear all cooldowns — used by reset-to-defaults flows so a stale
    /// entry from a URL the user just discarded doesn't leak into the
    /// freshly-restored config.
    static func clearAll() {
        queue.sync { cooldowns.removeAll(); return }
    }

    /// Testing / debug affordance — wipe all cooldowns.
    static func resetForTests() {
        queue.sync { cooldowns.removeAll(); return }
    }

    /// Snapshot of currently cooling URLs with their release dates.
    /// Expired entries are filtered out. Used by the Settings diagnostic
    /// panel so the user can see exactly which endpoints the router
    /// is avoiding and for how long.
    static func activeSnapshot() -> [(url: String, until: Date)] {
        queue.sync {
            let now = Date()
            // Clean up expired entries opportunistically.
            for (url, until) in cooldowns where until <= now {
                cooldowns.removeValue(forKey: url)
            }
            return cooldowns
                .map { (url: $0.key, until: $0.value) }
                .sorted { $0.until < $1.until }
        }
    }

    /// Clear a specific URL's cooldown, allowing the router to try it
    /// again on the next call. Useful as a manual "I fixed my key, stop
    /// avoiding this URL" affordance.
    static func clear(_ url: String) {
        queue.sync { cooldowns.removeValue(forKey: url); return }
    }
}

import Foundation
import Combine

/// Per-chain health snapshot captured by `NodeHealthStore`.
struct NodeHealthSnapshot: Equatable {
    enum Status: Equatable {
        case unknown
        case checking
        case ok
        case failed(String)
    }

    var status: Status = .unknown
    var latencyMs: Int? = nil
    var blockHeight: UInt64? = nil
    /// Last time the node answered a probe successfully.
    var lastOkAt: Date? = nil
    /// Last time any probe (success or failure) was attempted.
    var lastCheckedAt: Date? = nil
    /// Non-nil when the remote RPC claims a chain id / network that doesn't
    /// match the user's local selector (e.g. Sepolia URL under Mainnet).
    /// Treated as a soft warning: the probe can still be `.ok` because the
    /// RPC is reachable — but the UI should surface a red alert.
    var mismatchWarning: String? = nil
    /// Non-nil when the user's node is significantly behind the median of
    /// 2-3 independent reference endpoints (same chain, different providers).
    /// Soft warning: the node is reachable and usable for most reads, but
    /// balance/tx history may be stale.
    var lagWarning: String? = nil
    /// Recent latency samples (newest last, capped at 20). Used by the UI
    /// to render a mini sparkline so users can spot instability at a glance.
    var latencyHistory: [Int] = []

    var isOk: Bool { if case .ok = status { return true } else { return false } }
    var isFailed: Bool { if case .failed = status { return true } else { return false } }
}

/// App-wide cache of "is this chain's RPC reachable right now?"
///
/// Settings auto-refreshes on appear; other places can observe this store to
/// surface a rollup (e.g. `3/5 节点正常`) without re-probing.
///
/// `lastOkAt` is persisted to UserDefaults so a "last reachable 2 hours ago"
/// label survives relaunches.
@MainActor
final class NodeHealthStore: ObservableObject {
    static let shared = NodeHealthStore()

    @Published private(set) var snapshots: [Chain: NodeHealthSnapshot] = [:]
    @Published private(set) var refreshingAll: Bool = false

    private init() {
        for chain in Chain.allCases {
            var snap = NodeHealthSnapshot()
            if let ts = UserDefaults.standard.object(forKey: Self.lastOkKey(for: chain)) as? Double {
                snap.lastOkAt = Date(timeIntervalSince1970: ts)
            }
            snapshots[chain] = snap
        }
    }

    // MARK: Queries

    /// Number of chains whose most recent probe returned OK.
    var okCount: Int { snapshots.values.filter(\.isOk).count }
    /// Number of chains that have at least been probed once this session
    /// (either ok or failed; unknowns are excluded).
    var probedCount: Int { snapshots.values.filter { $0.status != .unknown }.count }
    /// Any chain currently in a failed state.
    var anyFailed: Bool { snapshots.values.contains(where: { $0.isFailed }) }

    /// "3/5 正常" / "正在检查…" style rollup used by the Settings entry row.
    var summaryText: String {
        if refreshingAll { return L10n.NodeStatus.checkingAll }
        if probedCount == 0 { return L10n.NodeStatus.notChecked }
        return L10n.NodeStatus.healthySummary(okCount, Chain.allCases.count)
    }

    func snapshot(for chain: Chain) -> NodeHealthSnapshot {
        snapshots[chain] ?? NodeHealthSnapshot()
    }

    // MARK: Probes

    /// Probe a single chain; updates its snapshot in-place.
    /// `force=false` respects a short per-chain cool-down so rapid taps /
    /// repeated page-open `task` blocks don't storm the endpoint.
    func refresh(chain: Chain, config: NetworkConfig = .shared, force: Bool = true) async {
        var snap = snapshots[chain] ?? NodeHealthSnapshot()
        if !force, let last = snap.lastCheckedAt,
           Date().timeIntervalSince(last) < Self.probeCooldownSeconds,
           snap.status != .checking {
            return
        }
        snap.status = .checking
        snap.mismatchWarning = nil
        snap.lagWarning = nil
        snapshots[chain] = snap

        let start = Date()
        let url = config.rpcURL(for: chain)
        let result = await Self.probe(chain: chain, url: url)
        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)

        snap.lastCheckedAt = Date()
        snap.latencyMs = elapsedMs
        // Push into rolling history (keep last 20). Failures still get
        // recorded so the sparkline shows a spike rather than a gap.
        snap.latencyHistory.append(elapsedMs)
        if snap.latencyHistory.count > 20 {
            snap.latencyHistory.removeFirst(snap.latencyHistory.count - 20)
        }
        switch result {
        case .success(let height):
            snap.status = .ok
            snap.blockHeight = height
            snap.lastOkAt = Date()
            UserDefaults.standard.set(snap.lastOkAt!.timeIntervalSince1970, forKey: Self.lastOkKey(for: chain))
            // After a successful reachability probe, verify the RPC speaks the
            // network the user thinks it does. For EVM we compare eth_chainId
            // against the selected chainId; for BTC we infer mainnet/testnet
            // from the known URL prefix; for Solana we skip (no cheap probe).
            snap.mismatchWarning = await Self.detectMismatch(chain: chain, url: url, config: config)
            // Also compare this node's block height against the median of
            // 2-3 independent reference endpoints. If we're significantly
            // behind, surface a yellow warning — the node is still usable
            // for reads but balance/tx history may be stale.
            if let h = height {
                snap.lagWarning = await Self.detectBlockLag(chain: chain, userURL: url, userHeight: h, config: config)
            }
        case .failure(let err):
            snap.status = .failed(Self.friendlyError(err))
            snap.blockHeight = nil
        }
        snapshots[chain] = snap
    }

    /// Probe every chain concurrently. Respects a per-chain cool-down so
    /// opening the Settings page repeatedly doesn't spam the endpoints.
    /// Pass `force=true` from the toolbar refresh button to bypass it.
    func refreshAll(config: NetworkConfig = .shared, force: Bool = false) async {
        guard !refreshingAll else { return }
        refreshingAll = true
        await withTaskGroup(of: Void.self) { group in
            for chain in Chain.allCases {
                group.addTask { [weak self] in
                    await self?.refresh(chain: chain, config: config, force: force)
                }
            }
        }
        refreshingAll = false
    }

    /// How long after a probe before another `refreshAll` bothers the same
    /// endpoint again. The toolbar button and row-tap still bypass this
    /// by calling `refresh(chain:force:true)`.
    private static let probeCooldownSeconds: TimeInterval = 8

    // MARK: Internals

    private static func lastOkKey(for chain: Chain) -> String {
        "com.horcrux.nodeHealth.lastOk.\(chain.rawValue)"
    }

    private static func friendlyError(_ err: Error) -> String {
        let msg = err.localizedDescription
        // Trim long URLSession messages into a compact label.
        if msg.contains("network connection was lost") { return L10n.NodeStatus.errNetwork }
        if msg.contains("could not connect") { return L10n.NodeStatus.errUnreachable }
        if msg.contains("timed out") { return L10n.NodeStatus.errTimeout }
        if msg.count > 48 { return String(msg.prefix(48)) + "…" }
        return msg
    }

    /// Chain-specific probe. Returns the current tip height on success or
    /// throws on any transport / protocol error.
    private static func probe(chain: Chain, url: String) async -> Result<UInt64?, Error> {
        do {
            let service = BlockchainService()
            if chain.isEVM {
                let dec = try await service.ethBlockNumber(rpcURL: url)
                return .success(UInt64(dec))
            }
            switch chain {
            case .bitcoin, .litecoin:
                let tipURL = "\(url)/blocks/tip/height"
                guard let u = URL(string: tipURL) else {
                    return .failure(BlockchainError.invalidURL(tipURL))
                }
                var req = URLRequest(url: u, timeoutInterval: 5)
                req.httpMethod = "GET"
                let (data, response) = try await PinnedURLSession.shared.session.data(for: req)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    return .failure(BlockchainError.httpError(statusCode: code))
                }
                let body = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return .success(UInt64(body))
            case .solana:
                _ = try await service.solHealth(rpcURL: url)
                return .success(nil)
            case .tron:
                let tipURL = "\(url)/wallet/getnowblock"
                guard let u = URL(string: tipURL) else {
                    return .failure(BlockchainError.invalidURL(tipURL))
                }
                var req = URLRequest(url: u, timeoutInterval: 5)
                req.httpMethod = "POST"
                req.httpBody = Data("{}".utf8)
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let (data, response) = try await PinnedURLSession.shared.session.data(for: req)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    return .failure(BlockchainError.httpError(statusCode: code))
                }
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let header = json["block_header"] as? [String: Any],
                   let raw = header["raw_data"] as? [String: Any],
                   let num = raw["number"] as? UInt64 {
                    return .success(num)
                }
                return .success(nil)
            default:
                return .success(nil)
            }
        } catch {
            return .failure(error)
        }
    }

    /// Verifies the RPC endpoint speaks the network the user selected.
    ///
    /// EVM: fetches `eth_chainId` and compares to `config.evmChainId`. For
    /// secondary EVM chains (BNB, Polygon, etc.) compares to the built-in
    /// `defaultEVMNetwork.rawValue`. A mismatch is serious — sending a tx
    /// to the wrong chain can cause permanent loss.
    ///
    /// BTC / LTC: infers mainnet vs testnet from the URL path (most
    /// providers include `/testnet/` in the testnet route) and compares to
    /// `config.btcTestnet`. Falls back to silent pass when the URL pattern
    /// is unrecognised.
    ///
    /// SOL / TRON: no cheap mismatch probe; returns nil.
    private static func detectMismatch(chain: Chain, url: String, config: NetworkConfig) async -> String? {
        if chain.isEVM {
            let expected: UInt64
            if chain == .ethereum {
                expected = config.evmChainId
            } else if let net = chain.defaultEVMNetwork {
                expected = net.rawValue
            } else {
                return nil
            }
            do {
                let actual = try await BlockchainService().ethChainId(rpcURL: url)
                if actual != 0, actual != expected {
                    let expectedName = EVMNetwork(rawValue: expected)?.displayName ?? "chain \(expected)"
                    let actualName = EVMNetwork(rawValue: actual)?.displayName ?? "chain \(actual)"
                    return L10n.NodeStatus.chainMismatch(expectedName, actualName)
                }
            } catch {
                // Swallow — reachability already passed, so this is likely
                // an unusual RPC that doesn't implement eth_chainId. Don't
                // scare the user about it.
                return nil
            }
            return nil
        }
        switch chain {
        case .bitcoin:
            let lower = url.lowercased()
            let looksTestnet = lower.contains("/testnet") || lower.contains("testnet.")
            if looksTestnet != config.btcTestnet {
                return config.btcTestnet
                    ? L10n.NodeStatus.networkMismatchExpectedTestnet
                    : L10n.NodeStatus.networkMismatchExpectedMainnet
            }
            return nil
        case .solana:
            let lower = url.lowercased()
            let looksDevnet = lower.contains("devnet") || lower.contains("testnet")
            if looksDevnet != config.solDevnet {
                return config.solDevnet
                    ? L10n.NodeStatus.networkMismatchExpectedTestnet
                    : L10n.NodeStatus.networkMismatchExpectedMainnet
            }
            return nil
        default:
            return nil
        }
    }

    /// Cached reference-height probes keyed by chain. Expires after 30s so
    /// probing multiple chains in quick succession doesn't hammer every
    /// reference endpoint each time.
    private static var referenceCache: [Chain: (height: UInt64, at: Date)] = [:]
    private static let referenceCacheTTL: TimeInterval = 30

    /// Detects whether `userHeight` is significantly behind the independently-
    /// sourced consensus height for the same chain.
    ///
    /// We probe 2-3 reference endpoints (from `RPCFallbacks.endpoints`),
    /// excluding the user's own URL to avoid self-comparison, and take the
    /// **median** so a single stale or malicious reference can't poison the
    /// result. If fewer than 2 references respond, we silently skip (better
    /// no warning than a false alarm).
    ///
    /// Thresholds are chain-specific — EVM/SOL produce blocks fast (seconds),
    /// BTC/LTC slow (~10 min), so "20 blocks behind" means very different
    /// things.
    private static func detectBlockLag(
        chain: Chain,
        userURL: String,
        userHeight: UInt64,
        config: NetworkConfig
    ) async -> String? {
        // Chain.solana probes don't return a height (we use `getHealth`);
        // Tron's probe returns a height but we keep lag detection to the
        // chains where fallbacks are well-defined.
        guard chain != .solana else { return nil }

        let threshold: UInt64
        switch chain {
        case .ethereum, .polygon, .arbitrum, .base, .optimism, .bnb,
             .avalanche, .zksync, .linea, .scroll:
            threshold = 30            // ~6 min ETH, faster on L2s
        case .bitcoin, .litecoin:
            threshold = 2             // ~20 min at 10 min blocks
        case .tron:
            threshold = 20            // ~60 s at 3 s blocks
        default:
            return nil
        }

        // Use cache if fresh, else probe fresh references.
        let referenceHeight: UInt64
        if let cached = referenceCache[chain],
           Date().timeIntervalSince(cached.at) < referenceCacheTTL {
            referenceHeight = cached.height
        } else {
            let candidates = RPCFallbacks.orderedAttempts(for: chain, config: config)
                .filter { $0 != userURL }
                .prefix(3)
            guard candidates.count >= 2 else { return nil }

            // Probe all candidates in parallel, collect successes.
            let heights: [UInt64] = await withTaskGroup(of: UInt64?.self) { group in
                for ref in candidates {
                    group.addTask {
                        if case .success(let h?) = await probe(chain: chain, url: ref) { return h }
                        return nil
                    }
                }
                var out: [UInt64] = []
                for await h in group {
                    if let h { out.append(h) }
                }
                return out
            }
            guard heights.count >= 2 else { return nil }
            let sorted = heights.sorted()
            let median = sorted[sorted.count / 2]
            referenceCache[chain] = (median, Date())
            referenceHeight = median
        }

        // Only warn if behind — being ahead (rare; reorg / faster node) is
        // not actionable for the user.
        guard userHeight < referenceHeight else { return nil }
        let lag = referenceHeight - userHeight
        guard lag >= threshold else { return nil }
        return L10n.NodeStatus.blockLagWarning(Int(lag))
    }
}

// MARK: - Format helpers

extension NodeHealthSnapshot {
    /// Human-readable "2 分钟前" / "刚刚" style for `lastOkAt`.
    func lastOkRelative(now: Date = Date()) -> String? {
        guard let last = lastOkAt else { return nil }
        let seconds = Int(now.timeIntervalSince(last))
        if seconds < 5 { return L10n.NodeStatus.justNow }
        if seconds < 60 { return L10n.NodeStatus.secondsAgo(seconds) }
        if seconds < 3600 { return L10n.NodeStatus.minutesAgo(seconds / 60) }
        if seconds < 86_400 { return L10n.NodeStatus.hoursAgo(seconds / 3600) }
        return L10n.NodeStatus.daysAgo(seconds / 86_400)
    }
}

// MARK: - WebSocket probe

/// Lightweight one-shot probe for `wss://` endpoints used in Settings.
///
/// We deliberately don't keep a long-lived WS connection — the wallet's
/// read path is still HTTP-based. The probe exists so users who paste a
/// paid commercial endpoint (Alchemy / Infura / Helius) can verify it's
/// actually reachable + authenticates + speaks the expected protocol,
/// before paying for it in real usage.
///
/// Flow: connect → send one `newHeads` / `slotSubscribe` RPC → wait for
/// either the ack or the first push → return success/failure → close.
enum WebSocketProbe {
    enum ProbeError: Error, LocalizedError {
        case invalidURL
        case wrongScheme
        case timeout
        case handshake(String)
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid URL"
            case .wrongScheme: return "URL must start with ws:// or wss://"
            case .timeout: return "Timed out waiting for response"
            case .handshake(let m): return m
            case .badResponse(let m): return m
            }
        }
    }

    /// Probe a WebSocket endpoint. `kind` picks the subscription command
    /// so we give the server a realistic payload rather than just TCP
    /// handshake. Returns round-trip latency in ms on success.
    enum Kind { case evm, solana }

    static func probe(urlString: String, kind: Kind, timeoutSeconds: TimeInterval = 6) async -> Result<Int, ProbeError> {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.invalidURL) }
        guard trimmed.hasPrefix("wss://") || trimmed.hasPrefix("ws://") else {
            return .failure(.wrongScheme)
        }
        guard let url = URL(string: trimmed) else { return .failure(.invalidURL) }

        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        task.resume()
        let start = Date()

        let payload: String
        switch kind {
        case .evm:
            payload = #"{"jsonrpc":"2.0","id":1,"method":"eth_subscribe","params":["newHeads"]}"#
        case .solana:
            payload = #"{"jsonrpc":"2.0","id":1,"method":"slotSubscribe"}"#
        }

        do {
            try await task.send(.string(payload))
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            return .failure(.handshake(error.localizedDescription))
        }

        // Race: first message or timeout. Whichever wins, we cancel.
        let result = await withTaskGroup(of: Result<Int, ProbeError>.self) { group -> Result<Int, ProbeError> in
            group.addTask {
                do {
                    let msg = try await task.receive()
                    let body: String
                    switch msg {
                    case .string(let s): body = s
                    case .data(let d): body = String(data: d, encoding: .utf8) ?? ""
                    @unknown default: body = ""
                    }
                    // Any of: subscription ack (has "result"), a push
                    // (has "method":"eth_subscription"/"slotNotification"),
                    // or an error envelope. We treat anything containing
                    // `"jsonrpc"` as a valid RPC response; anything else
                    // is considered a handshake-level failure.
                    guard body.contains("\"jsonrpc\"") else {
                        return .failure(.badResponse(String(body.prefix(120))))
                    }
                    if body.contains("\"error\"") {
                        return .failure(.badResponse(String(body.prefix(120))))
                    }
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    return .success(ms)
                } catch {
                    return .failure(.handshake(error.localizedDescription))
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                return .failure(.timeout)
            }
            let first = await group.next() ?? .failure(.timeout)
            group.cancelAll()
            return first
        }

        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
        return result
    }
}

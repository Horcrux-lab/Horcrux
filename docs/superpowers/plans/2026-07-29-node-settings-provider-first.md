# Provider-First Node Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make all fourteen chains configurable through a provider-first
settings screen, with per-chain overrides as the escape hatch.

**Architecture:** A new `NodeProvider` value type owns provider→chain
template mapping. A new sparse `[Chain: String]` override store sits
beside it. `NetworkConfig.rpcURL(for:)` resolves override → provider
template → public default. A one-time migration moves existing users onto
the new model without freezing them on today's defaults. The UI is rebuilt
as a provider section plus one uniform list of all fourteen chains.

**Tech Stack:** Swift 5.9 / SwiftUI / XCTest. State in `UserDefaults`,
secrets in Keychain. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-07-29-node-settings-provider-first-design.md`

---

## Background you need before starting

You are working in an iOS MPC wallet. Read these three things first:

1. **`ios/Horcrux/App/AppState.swift:646`** — `enum Chain`. Fourteen
   cases. `chain.isEVM` (line 700) and `chain.defaultEVMNetwork` (line
   723) are the two helpers you will use constantly.
2. **`ios/Horcrux/Core/NetworkConfig.swift`** — ~2050 lines, a
   `final class ... ObservableObject` singleton at `NetworkConfig.shared`.
   It is *not* `@MainActor`. Every `@Published` property has a `didSet`
   that persists and calls `invalidateBalances()`.
3. **`ios/Horcrux/Core/NetworkConfig.swift:1005`** — `RPCProviderTemplate`,
   a set of static functions returning URL strings containing a literal
   `{KEY}`. `NetworkConfig.substituteAPIKey(in:chain:)` (line 385) swaps
   `{KEY}` for the Keychain value at call time. **It early-returns
   unchanged when the URL has no `{KEY}`** — that guard is load-bearing
   and there is a test protecting it.

### Build and test commands

```bash
cd ios && xcodegen generate
xcodebuild test -project Horcrux.xcodeproj -scheme Horcrux \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO \
  -only-testing:HorcruxTests/<TestClassName>
```

Run `xcodegen generate` after creating any new file, or Xcode will not
see it. `ios/Horcrux.xcodeproj/project.pbxproj` is tracked in git and
must be committed when it changes.

A full-suite run currently has 11 pre-existing failures (Keychain
`-34018` under an unsigned local run, plus one async flake). They are
unrelated to this work. Use `-only-testing:` and do not try to fix them.

---

## File structure

**Create:**

| File | Responsibility |
|---|---|
| `ios/Horcrux/Core/NodeProvider.swift` | Pure value type: which provider serves which chain, and with which template. No state, no I/O. |
| `ios/Horcrux/Core/ChainEndpointOverrides.swift` | Sparse per-chain URL store with `UserDefaults` persistence. |
| `ios/Horcrux/Core/NodeSettingsMigration.swift` | One-time migration from the legacy five-field model. |
| `ios/Horcrux/Features/Settings/NodeSettings/NodeProviderSection.swift` | Provider picker, key field, coverage line. |
| `ios/Horcrux/Features/Settings/NodeSettings/ChainEndpointList.swift` | The fourteen-row list with source badges. |
| `ios/Horcrux/Features/Settings/NodeSettings/ChainEndpointDetailView.swift` | Per-chain detail and override editor. |
| `ios/HorcruxTests/NodeProviderTests.swift` | Coverage matrix and template lookup. |
| `ios/HorcruxTests/EndpointResolutionTests.swift` | The three-step resolver. |
| `ios/HorcruxTests/NodeSettingsMigrationTests.swift` | Table-driven migration cases. |

**Modify:**

| File | Change |
|---|---|
| `ios/Horcrux/Core/NetworkConfig.swift` | Add `activeProvider`, `chainOverrides`, `resolveRawURL`, `publicDefault(for:)`. Flip `rpcURL(for:)` to the resolver. Narrow `evmChainId`. Extract `apiKeySlot(forHost:chain:)` out of `substituteAPIKey`. |
| `ios/Horcrux/Features/Settings/SettingsView.swift` | Replace the three hand-written chain sections with the two new ones; version `RPCConfigSnapshot`. |
| `ios/HorcruxTests/RPCRoutingTests.swift` | Extend the keyless-fallback guard to overrides; cover the key-slot routing. |

`NetworkConfig.swift` and `SettingsView.swift` are both already over 2000
lines. Everything new goes in a new file for that reason; do not grow
either one further than the listed edits.

---

## Phase 1 — The provider value type

### Task 1: `NodeProvider` enum and template lookup

**Files:**
- Create: `ios/Horcrux/Core/NodeProvider.swift`
- Test: `ios/HorcruxTests/NodeProviderTests.swift`

Only account-scoped, multi-chain providers belong here. GetBlock is
excluded because its token is bound to a single chain in its dashboard,
and Helius because it serves only Solana. Both remain reachable as
per-chain overrides in Phase 6. Putting either in this enum would make
the "one key, many chains" promise false.

**On the name:** `RPCProvider` is already taken — `NetworkConfig.swift:1214`
defines it as a 23-case URL→display-label type used by `identify(_:)` to
badge an endpoint with its vendor. That is a different concept from "a
provider account the user has selected", so this type is `NodeProvider`.
Do not rename it to `RPCProvider`; that is a redeclaration error.
`RPCProviderTemplate` (`NetworkConfig.swift:1005`) is a third, unrelated
type that this task calls into and must not be touched.

- [ ] **Step 1: Write the failing test**

Create `ios/HorcruxTests/NodeProviderTests.swift`:

```swift
import XCTest
@testable import Horcrux

final class NodeProviderTests: XCTestCase {

    func test_alchemy_servesPolygon_withItsOwnTemplate() {
        let url = NodeProvider.alchemy.template(for: .polygon, evmChainId: 1)
        XCTAssertEqual(url, "https://polygon-mainnet.g.alchemy.com/v2/{KEY}")
    }

    /// Alchemy has no BNB product. Returning a wrong-chain URL here would
    /// send Ethereum traffic to a BNB address, so the gap must be nil.
    func test_alchemy_doesNotServeBNB() {
        XCTAssertNil(NodeProvider.alchemy.template(for: .bnb, evmChainId: 1))
    }

    /// Ethereum is the one EVM chain whose network is user-selectable.
    func test_ethereumTemplate_followsTheEVMChainIdToggle() {
        XCTAssertEqual(NodeProvider.alchemy.template(for: .ethereum, evmChainId: 1),
                       "https://eth-mainnet.g.alchemy.com/v2/{KEY}")
        XCTAssertEqual(NodeProvider.alchemy.template(for: .ethereum, evmChainId: 11_155_111),
                       "https://eth-sepolia.g.alchemy.com/v2/{KEY}")
    }

    /// No provider in this enum serves the non-EVM, non-Solana chains.
    func test_noProvider_claimsBitcoinLitecoinOrTron() {
        for provider in NodeProvider.allCases {
            for chain in [Chain.bitcoin, .litecoin, .tron] {
                XCTAssertNil(provider.template(for: chain, evmChainId: 1),
                             "\(provider) must not claim \(chain)")
            }
        }
    }

    /// Every template must carry the placeholder, or substituteAPIKey
    /// silently returns it unchanged and the key is never applied.
    func test_everyTemplate_containsTheKeyPlaceholder() {
        var checked = 0
        for provider in NodeProvider.allCases {
            for chain in Chain.allCases {
                guard let t = provider.template(for: chain, evmChainId: 1) else { continue }
                checked += 1
                XCTAssertTrue(t.contains("{KEY}"), "\(provider)/\(chain): \(t)")
            }
        }
        XCTAssertGreaterThan(checked, 0)
    }

    func test_coveredChains_matchesTheDocumentedMatrix() {
        let covered = NodeProvider.alchemy.coveredChains(evmChainId: 1)
        XCTAssertTrue(covered.contains(.polygon))
        XCTAssertTrue(covered.contains(.solana))
        XCTAssertFalse(covered.contains(.bnb))
        XCTAssertFalse(covered.contains(.bitcoin))
    }

    func test_uncoveredChains_isTheComplementOverAllChains() {
        let uncovered = NodeProvider.alchemy.uncoveredChains(evmChainId: 1)
        XCTAssertTrue(uncovered.contains(.bnb))
        XCTAssertTrue(uncovered.contains(.bitcoin))
        XCTAssertFalse(uncovered.contains(.polygon))
        XCTAssertEqual(uncovered.count, Chain.allCases.count
                       - NodeProvider.alchemy.coveredChains(evmChainId: 1).count)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd ios && xcodegen generate && xcodebuild test -project Horcrux.xcodeproj \
  -scheme Horcrux -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO \
  -only-testing:HorcruxTests/NodeProviderTests 2>&1 | grep -E "error:|TEST"
```

Expected: `error: cannot find 'NodeProvider' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ios/Horcrux/Core/NodeProvider.swift`:

```swift
import Foundation

/// An account-scoped RPC provider: one key from this provider works
/// across every chain it serves.
///
/// GetBlock and Helius are deliberately absent. GetBlock issues a token
/// bound to a single chain in its dashboard, and Helius serves only
/// Solana, so neither satisfies the account-scoped contract this type
/// represents. Both remain available as per-chain overrides.
enum NodeProvider: String, CaseIterable, Identifiable, Codable {
    case alchemy, infura, ankr, blockpi, drpc, nodeReal, tenderly, oneRPC

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .alchemy: return "Alchemy"
        case .infura: return "Infura"
        case .ankr: return "Ankr"
        case .blockpi: return "BlockPI"
        case .drpc: return "dRPC"
        case .nodeReal: return "NodeReal"
        case .tenderly: return "Tenderly"
        case .oneRPC: return "1RPC"
        }
    }

    /// The `{KEY}`-bearing URL template this provider serves `chain` on,
    /// or nil when it does not serve that chain at all.
    ///
    /// `evmChainId` is consulted only for `.ethereum`, whose network is
    /// user-selectable between mainnet and Sepolia. Every other EVM chain
    /// maps to exactly one `EVMNetwork`.
    func template(for chain: Chain, evmChainId: UInt64) -> String? {
        if chain.isEVM {
            guard let net = evmNetwork(for: chain, evmChainId: evmChainId) else { return nil }
            switch self {
            case .alchemy:  return RPCProviderTemplate.alchemy(evm: net)
            case .infura:   return RPCProviderTemplate.infura(evm: net)
            case .ankr:     return RPCProviderTemplate.ankr(evm: net)
            case .blockpi:  return RPCProviderTemplate.blockpi(evm: net)
            case .drpc:     return RPCProviderTemplate.drpc(evm: net)
            case .nodeReal: return RPCProviderTemplate.nodeReal(evm: net)
            case .tenderly: return RPCProviderTemplate.tenderly(evm: net)
            case .oneRPC:   return RPCProviderTemplate.oneRPC(evm: net)
            }
        }

        guard chain == .solana else { return nil }
        // Bitcoin, Litecoin and Tron are served by no provider in this
        // enum; they fall through to public defaults or a user override.
        let mainnet = !NetworkConfig.shared.solDevnet
        switch self {
        case .alchemy:  return RPCProviderTemplate.alchemySolana(mainnet: mainnet)
        case .infura:   return RPCProviderTemplate.infuraSolana(mainnet: mainnet)
        case .ankr:     return RPCProviderTemplate.ankrSolana()
        case .drpc:     return RPCProviderTemplate.drpcSolana()
        case .oneRPC:   return RPCProviderTemplate.oneRPCSolana(mainnet: mainnet)
        case .blockpi, .nodeReal, .tenderly: return nil
        }
    }

    private func evmNetwork(for chain: Chain, evmChainId: UInt64) -> EVMNetwork? {
        if chain == .ethereum {
            return EVMNetwork(rawValue: evmChainId) ?? .mainnet
        }
        return chain.defaultEVMNetwork
    }

    func coveredChains(evmChainId: UInt64) -> Set<Chain> {
        Set(Chain.allCases.filter { template(for: $0, evmChainId: evmChainId) != nil })
    }

    func uncoveredChains(evmChainId: UInt64) -> Set<Chain> {
        Set(Chain.allCases).subtracting(coveredChains(evmChainId: evmChainId))
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Same command as Step 2. Expected: `TEST SUCCEEDED`, 7 tests.

- [ ] **Step 5: Commit**

```bash
cd /Users/bill/Documents/GitHub/Horcrux
git add ios/Horcrux/Core/NodeProvider.swift ios/HorcruxTests/NodeProviderTests.swift \
        ios/Horcrux.xcodeproj/project.pbxproj
git commit -m "feat(ios): add NodeProvider value type for account-scoped providers

One key from an account-scoped provider works across every chain it
serves, which is the unit users actually own. GetBlock and Helius are
excluded: GetBlock's token is bound to one chain in its dashboard and
Helius serves only Solana, so including either would make the
one-key-many-chains contract false.

Templates return nil for chains a provider does not serve, so a gap can
never resolve to another chain's URL."
```

### Task 2: Map providers to their Keychain fields

**Files:**
- Modify: `ios/Horcrux/Core/NodeProvider.swift`
- Test: `ios/HorcruxTests/NodeProviderTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `NodeProviderTests`:

```swift
    func test_keyLookup_readsTheProvidersOwnKeychainField() {
        let config = NetworkConfig.shared
        config.alchemyAPIKey = "alchemy-test"
        config.infuraAPIKey = "infura-test"
        defer {
            config.alchemyAPIKey = ""
            config.infuraAPIKey = ""
        }

        XCTAssertEqual(config.apiKey(for: .alchemy), "alchemy-test")
        XCTAssertEqual(config.apiKey(for: .infura), "infura-test")
        XCTAssertEqual(config.apiKey(for: .ankr), "")
    }
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd ios && xcodebuild test -project Horcrux.xcodeproj -scheme Horcrux \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO \
  -only-testing:HorcruxTests/NodeProviderTests 2>&1 | grep -E "error:|TEST"
```

Expected: `error: value of type 'NetworkConfig' has no member 'apiKey'`.

- [ ] **Step 3: Write the implementation**

Append to `ios/Horcrux/Core/NodeProvider.swift`:

```swift
extension NetworkConfig {
    /// The Keychain-backed key for `provider`, or "" when unset.
    ///
    /// Kept here rather than in `substituteAPIKey`'s host-substring chain
    /// because that function matches on hostname and must keep working
    /// for URLs the user pasted by hand, which carry no provider identity.
    func apiKey(for provider: NodeProvider) -> String {
        switch provider {
        case .alchemy:  return alchemyAPIKey
        case .infura:   return infuraAPIKey
        case .ankr:     return ankrAPIKey
        case .blockpi:  return blockpiAPIKey
        case .drpc:     return drpcAPIKey
        case .nodeReal: return nodeRealAPIKey
        case .tenderly: return tenderlyAPIKey
        case .oneRPC:   return oneRPCAPIKey
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Same command. Expected: `TEST SUCCEEDED`, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add ios/Horcrux/Core/NodeProvider.swift ios/HorcruxTests/NodeProviderTests.swift
git commit -m "feat(ios): route NodeProvider to its Keychain field"
```

---

## Phase 2 — Per-chain override storage

### Task 3: `ChainEndpointOverrides`

**Files:**
- Create: `ios/Horcrux/Core/ChainEndpointOverrides.swift`
- Test: `ios/HorcruxTests/EndpointResolutionTests.swift`

Sparse by design: an absent entry means "follow the provider or the
public default", which is what lets a future default change reach
existing users. Storing all fourteen eagerly would freeze every user on
the values current at migration time.

- [ ] **Step 1: Write the failing test**

Create `ios/HorcruxTests/EndpointResolutionTests.swift`:

```swift
import XCTest
@testable import Horcrux

final class EndpointResolutionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ChainEndpointOverrides.shared.removeAll()
    }

    override func tearDown() {
        ChainEndpointOverrides.shared.removeAll()
        super.tearDown()
    }

    func test_overrides_startEmpty() {
        XCTAssertNil(ChainEndpointOverrides.shared.url(for: .polygon))
        XCTAssertTrue(ChainEndpointOverrides.shared.allChains().isEmpty)
    }

    func test_setAndReadBack_roundTrips() {
        ChainEndpointOverrides.shared.set("https://my-node.example", for: .polygon)
        XCTAssertEqual(ChainEndpointOverrides.shared.url(for: .polygon),
                       "https://my-node.example")
        XCTAssertNil(ChainEndpointOverrides.shared.url(for: .base),
                     "setting one chain must not affect another")
    }

    /// The bug this design replaces: one shared field meant a custom
    /// Polygon URL silently applied to Base.
    func test_overridesAreIndependentPerChain() {
        ChainEndpointOverrides.shared.set("https://poly.example", for: .polygon)
        ChainEndpointOverrides.shared.set("https://base.example", for: .base)
        XCTAssertEqual(ChainEndpointOverrides.shared.url(for: .polygon), "https://poly.example")
        XCTAssertEqual(ChainEndpointOverrides.shared.url(for: .base), "https://base.example")
    }

    func test_settingEmptyString_clearsTheOverride() {
        ChainEndpointOverrides.shared.set("https://my-node.example", for: .polygon)
        ChainEndpointOverrides.shared.set("", for: .polygon)
        XCTAssertNil(ChainEndpointOverrides.shared.url(for: .polygon),
                     "an emptied field must fall back to provider/public, not store \"\"")
    }

    func test_clear_removesOnlyThatChain() {
        ChainEndpointOverrides.shared.set("https://poly.example", for: .polygon)
        ChainEndpointOverrides.shared.set("https://base.example", for: .base)
        ChainEndpointOverrides.shared.clear(.polygon)
        XCTAssertNil(ChainEndpointOverrides.shared.url(for: .polygon))
        XCTAssertEqual(ChainEndpointOverrides.shared.url(for: .base), "https://base.example")
    }

    func test_overridesSurviveAReload() {
        ChainEndpointOverrides.shared.set("https://persisted.example", for: .scroll)
        ChainEndpointOverrides.shared.reloadFromDisk()
        XCTAssertEqual(ChainEndpointOverrides.shared.url(for: .scroll),
                       "https://persisted.example")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd ios && xcodegen generate && xcodebuild test -project Horcrux.xcodeproj \
  -scheme Horcrux -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO \
  -only-testing:HorcruxTests/EndpointResolutionTests 2>&1 | grep -E "error:|TEST"
```

Expected: `error: cannot find 'ChainEndpointOverrides' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ios/Horcrux/Core/ChainEndpointOverrides.swift`:

```swift
import Foundation

/// Sparse per-chain endpoint overrides.
///
/// Absence is meaningful: a chain with no entry follows the active
/// provider, or the public default when no provider covers it. That is
/// what allows a shipped default change to reach existing users. Storing
/// an entry for every chain would freeze each user on whatever the
/// defaults happened to be the day they migrated — the same failure mode
/// `NetworkConfig.migrateDeadEndpoints` exists to clean up after.
final class ChainEndpointOverrides: ObservableObject, @unchecked Sendable {
    static let shared = ChainEndpointOverrides()

    private static let storageKey = "com.horcrux.rpc.chainOverrides"

    @Published private(set) var overrides: [String: String] = [:]

    private init() {
        reloadFromDisk()
    }

    func url(for chain: Chain) -> String? {
        guard let value = overrides[chain.rawValue], !value.isEmpty else { return nil }
        return value
    }

    /// Storing an empty string clears the entry rather than persisting "",
    /// so a user who selects-all-and-deletes in the text field returns to
    /// the default instead of pinning an unusable empty endpoint.
    func set(_ url: String, for chain: Chain) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            clear(chain)
            return
        }
        overrides[chain.rawValue] = trimmed
        persist()
    }

    func clear(_ chain: Chain) {
        overrides.removeValue(forKey: chain.rawValue)
        persist()
    }

    func removeAll() {
        overrides = [:]
        persist()
    }

    /// Chains that currently carry an override, for the settings list.
    func allChains() -> Set<Chain> {
        Set(overrides.keys.compactMap(Chain.init(rawValue:)))
    }

    func reloadFromDisk() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.storageKey) as? [String: String]
        overrides = stored ?? [:]
    }

    private func persist() {
        UserDefaults.standard.set(overrides, forKey: Self.storageKey)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Same command. Expected: `TEST SUCCEEDED`, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add ios/Horcrux/Core/ChainEndpointOverrides.swift \
        ios/HorcruxTests/EndpointResolutionTests.swift \
        ios/Horcrux.xcodeproj/project.pbxproj
git commit -m "feat(ios): add sparse per-chain endpoint overrides

Absence is meaningful: an unset chain follows the provider or the public
default, so a shipped default change still reaches existing users.
Storing all fourteen eagerly would freeze each user on the values current
at migration time, which is the failure migrateDeadEndpoints exists to
clean up after.

Keyed by Chain, so the current bug -- one shared EVM field meaning a
custom Polygon URL silently applies to Base -- cannot recur."
```

---

## Phase 3 — The resolver

### Task 4: `publicDefault(for:)` for all fourteen chains

**Files:**
- Modify: `ios/Horcrux/Core/NetworkConfig.swift` (add after `rpcURL(for:)`, around line 279)
- Test: `ios/HorcruxTests/EndpointResolutionTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `EndpointResolutionTests`:

```swift
    func test_publicDefault_isNonEmptyAndPlaceholderFreeForEveryChain() {
        let config = NetworkConfig.shared
        for chain in Chain.allCases {
            let url = config.publicDefault(for: chain)
            XCTAssertFalse(url.isEmpty, "\(chain) has no public default")
            XCTAssertFalse(url.contains("{KEY}"),
                           "\(chain) public default must need no key: \(url)")
        }
    }

    func test_publicDefault_forPreviouslyUnconfigurableChains() {
        let config = NetworkConfig.shared
        XCTAssertEqual(config.publicDefault(for: .base), "https://mainnet.base.org")
        XCTAssertEqual(config.publicDefault(for: .scroll), "https://rpc.scroll.io")
        XCTAssertEqual(config.publicDefault(for: .bnb), "https://bsc-dataseed.bnbchain.org")
    }

    func test_publicDefault_forEthereum_followsTheNetworkToggle() {
        let config = NetworkConfig.shared
        let original = config.evmChainId
        defer { config.evmChainId = original }

        config.evmChainId = 1
        XCTAssertEqual(config.publicDefault(for: .ethereum),
                       "https://ethereum-rpc.publicnode.com")
        config.evmChainId = 11_155_111
        XCTAssertEqual(config.publicDefault(for: .ethereum),
                       "https://ethereum-sepolia-rpc.publicnode.com")
    }
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd ios && xcodebuild test -project Horcrux.xcodeproj -scheme Horcrux \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO \
  -only-testing:HorcruxTests/EndpointResolutionTests 2>&1 | grep -E "error:|TEST"
```

Expected: `error: value of type 'NetworkConfig' has no member 'publicDefault'`.

- [ ] **Step 3: Write the implementation**

In `ios/Horcrux/Core/NetworkConfig.swift`, immediately after the closing
brace of `rpcURL(for:)` (currently line 279), insert:

```swift
    /// The keyless public endpoint for `chain`, honouring the Ethereum,
    /// Bitcoin and Solana network toggles. Never returns a `{KEY}`
    /// template and never returns an empty string.
    func publicDefault(for chain: Chain) -> String {
        switch chain {
        case .ethereum:
            return (EVMNetwork(rawValue: evmChainId) ?? .mainnet).publicDefaultRPC
        case .bitcoin:
            return (btcTestnet ? BitcoinNetwork.testnet : BitcoinNetwork.mainnet).defaultAPI
        case .litecoin:
            return Defaults.litecoinAPI
        case .solana:
            return (solDevnet ? SolanaNetwork.devnet : SolanaNetwork.mainnet).publicDefaultRPC
        case .tron:
            return Defaults.tronAPI
        case .bnb, .polygon, .arbitrum, .base, .avalanche,
             .optimism, .zksync, .linea, .scroll:
            // Each maps to exactly one EVMNetwork, so the force-unwrap
            // path is unreachable; the ?? keeps it total anyway.
            return chain.defaultEVMNetwork?.publicDefaultRPC ?? ""
        }
    }
```

`Defaults` lives in a `private extension NetworkConfig` at the bottom of
the file, so it is visible from inside the type. Leave it there.

- [ ] **Step 4: Run the test to verify it passes**

Same command. Expected: `TEST SUCCEEDED`, 9 tests.

- [ ] **Step 5: Commit**

```bash
git add ios/Horcrux/Core/NetworkConfig.swift ios/HorcruxTests/EndpointResolutionTests.swift
git commit -m "feat(ios): give every chain a public default endpoint

Nine EVM chains previously had no addressable default outside
rpcURL's own switch. Naming it makes them resolvable by the new
override/provider/public path."
```

### Task 5: `activeProvider` storage

**Files:**
- Modify: `ios/Horcrux/Core/NetworkConfig.swift` (property block near line 51; `Keys` enum near line 966)
- Test: `ios/HorcruxTests/EndpointResolutionTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `EndpointResolutionTests`:

```swift
    func test_activeProvider_defaultsToNilMeaningPublic() {
        NetworkConfig.shared.activeProvider = nil
        XCTAssertNil(NetworkConfig.shared.activeProvider)
    }

    func test_activeProvider_roundTripsThroughStorage() {
        let config = NetworkConfig.shared
        defer { config.activeProvider = nil }
        config.activeProvider = .infura
        XCTAssertEqual(config.activeProvider, .infura)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Expected: `error: value of type 'NetworkConfig' has no member 'activeProvider'`.

- [ ] **Step 3: Write the implementation**

Add to the `Keys` enum in the `private extension NetworkConfig` block
(after `static let solanaWSS`):

```swift
        static let activeProvider = "com.horcrux.rpc.activeProvider"
```

Add the property alongside the other `@Published` declarations, directly
after the `solDevnet` block (currently ends line 71):

```swift
    /// The account-scoped provider whose templates are preferred for every
    /// chain it covers. `nil` means public defaults.
    ///
    /// This is not a secret — it names a company, not a credential — so it
    /// lives in UserDefaults beside the other routing preferences. The key
    /// itself stays in the Keychain.
    @Published var activeProvider: NodeProvider? {
        didSet {
            UserDefaults.standard.set(activeProvider?.rawValue, forKey: Keys.activeProvider)
            invalidateBalances()
        }
    }
```

In `init()`, before the existing assignments that read UserDefaults (the
block starting around line 227), add:

```swift
        let storedProvider = ud.string(forKey: Keys.activeProvider)
```

and with the other `self.` assignments near line 249:

```swift
        self.activeProvider = storedProvider.flatMap(NodeProvider.init(rawValue:))
```

Swift requires every stored property to be initialised before `self` is
used; keep this assignment in the same group as `self.solDevnet`.

- [ ] **Step 4: Run the test to verify it passes**

Expected: `TEST SUCCEEDED`, 11 tests.

- [ ] **Step 5: Commit**

```bash
git add ios/Horcrux/Core/NetworkConfig.swift ios/HorcruxTests/EndpointResolutionTests.swift
git commit -m "feat(ios): persist the active RPC provider

Stored in UserDefaults, not the Keychain: it names a company rather
than a credential. The key stays in the Keychain."
```

### Task 6: `resolveRawURL` — the three-step resolver

**Files:**
- Modify: `ios/Horcrux/Core/NetworkConfig.swift`
- Test: `ios/HorcruxTests/EndpointResolutionTests.swift`

This task adds the resolver but does **not** yet wire it into
`rpcURL(for:)`. Keeping the switch separate (Task 9) means this commit
cannot change app behaviour, and the flip is one small reviewable diff.

- [ ] **Step 1: Write the failing test**

Append to `EndpointResolutionTests`:

```swift
    private func withCleanConfig(_ body: (NetworkConfig) -> Void) {
        let config = NetworkConfig.shared
        let provider = config.activeProvider
        let chainId = config.evmChainId
        let alchemy = config.alchemyAPIKey
        defer {
            config.activeProvider = provider
            config.evmChainId = chainId
            config.alchemyAPIKey = alchemy
            ChainEndpointOverrides.shared.removeAll()
        }
        config.activeProvider = nil
        config.alchemyAPIKey = ""
        ChainEndpointOverrides.shared.removeAll()
        body(config)
    }

    func test_resolve_withNothingConfigured_returnsThePublicDefault() {
        withCleanConfig { config in
            XCTAssertEqual(config.resolveRawURL(for: .base), "https://mainnet.base.org")
        }
    }

    func test_resolve_prefersTheProviderTemplateOverPublic() {
        withCleanConfig { config in
            config.activeProvider = .alchemy
            config.alchemyAPIKey = "k"
            XCTAssertEqual(config.resolveRawURL(for: .base),
                           "https://base-mainnet.g.alchemy.com/v2/{KEY}")
        }
    }

    func test_resolve_prefersAnOverrideOverTheProvider() {
        withCleanConfig { config in
            config.activeProvider = .alchemy
            config.alchemyAPIKey = "k"
            ChainEndpointOverrides.shared.set("https://mine.example", for: .base)
            XCTAssertEqual(config.resolveRawURL(for: .base), "https://mine.example")
        }
    }

    /// A provider that does not serve a chain must not shadow the public
    /// default for it, and must never return another chain's URL.
    func test_resolve_fallsBackToPublicForAnUncoveredChain() {
        withCleanConfig { config in
            config.activeProvider = .alchemy
            config.alchemyAPIKey = "k"
            XCTAssertEqual(config.resolveRawURL(for: .bnb),
                           "https://bsc-dataseed.bnbchain.org")
            XCTAssertEqual(config.resolveRawURL(for: .bitcoin),
                           config.publicDefault(for: .bitcoin))
        }
    }

    /// Selecting a provider without pasting its key must not strand the
    /// user on a template that resolves to a literal "{KEY}" request.
    func test_resolve_ignoresTheProviderWhenItsKeyIsEmpty() {
        withCleanConfig { config in
            config.activeProvider = .alchemy
            config.alchemyAPIKey = ""
            XCTAssertEqual(config.resolveRawURL(for: .base), "https://mainnet.base.org")
        }
    }

    func test_resolve_neverReturnsEmptyForAnyChain() {
        withCleanConfig { config in
            for chain in Chain.allCases {
                XCTAssertFalse(config.resolveRawURL(for: chain).isEmpty, "\(chain)")
            }
        }
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Expected: `error: value of type 'NetworkConfig' has no member 'resolveRawURL'`.

- [ ] **Step 3: Write the implementation**

Insert directly after `publicDefault(for:)` in `NetworkConfig.swift`:

```swift
    /// Resolve `chain` to a raw URL, which may still contain `{KEY}`.
    /// Callers wanting a request-ready URL should use `rpcURL(for:)`.
    ///
    /// Order: explicit override, then the active provider's template, then
    /// the public default. A provider with no key configured is skipped
    /// rather than returning a template that would be sent with a literal
    /// `{KEY}` in the path.
    func resolveRawURL(for chain: Chain) -> String {
        if let override = ChainEndpointOverrides.shared.url(for: chain) {
            return override
        }
        if let provider = activeProvider,
           !apiKey(for: provider).isEmpty,
           let template = provider.template(for: chain, evmChainId: evmChainId) {
            return template
        }
        return publicDefault(for: chain)
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Expected: `TEST SUCCEEDED`, 17 tests.

- [ ] **Step 5: Commit**

```bash
git add ios/Horcrux/Core/NetworkConfig.swift ios/HorcruxTests/EndpointResolutionTests.swift
git commit -m "feat(ios): resolve endpoints override -> provider -> public

Not yet wired into rpcURL, so this commit cannot change behaviour; the
switch is a separate reviewable change.

A provider with no key is skipped rather than returning its template,
which would otherwise be sent with a literal {KEY} in the path."
```

---

## Phase 4 — Migration

### Task 7: Migrate the legacy five-field model

**Files:**
- Create: `ios/Horcrux/Core/NodeSettingsMigration.swift`
- Test: `ios/HorcruxTests/NodeSettingsMigrationTests.swift`

The rule most likely to be got wrong: **a stored URL equal to the current
public default must migrate to nothing.** Writing it into an override
would freeze that user on today's default forever, so the dead-endpoint
purges would never reach them. `NetworkConfig.migrateDeadEndpoints`
(line 644) exists because stored URLs do get frozen, and currently lists
seven dead URLs.

- [ ] **Step 1: Write the failing test**

Create `ios/HorcruxTests/NodeSettingsMigrationTests.swift`:

```swift
import XCTest
@testable import Horcrux

final class NodeSettingsMigrationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ChainEndpointOverrides.shared.removeAll()
    }

    override func tearDown() {
        ChainEndpointOverrides.shared.removeAll()
        super.tearDown()
    }

    /// A value equal to the shipped default must produce no override, or
    /// the user is frozen on it and future default fixes never arrive.
    func test_publicDefaultValue_producesNoOverride() {
        let result = NodeSettingsMigration.plan(
            ethereumRPC: "https://ethereum-rpc.publicnode.com",
            bitcoinAPI: "https://blockstream.info/api",
            litecoinAPI: "https://litecoinspace.org/api",
            solanaRPC: "https://solana-rpc.publicnode.com",
            tronAPI: "https://api.trongrid.io",
            evmChainId: 1
        )
        XCTAssertTrue(result.overrides.isEmpty)
        XCTAssertNil(result.activeProvider)
        XCTAssertEqual(result.evmChainId, 1)
    }

    func test_providerTemplate_becomesTheActiveProvider() {
        let result = NodeSettingsMigration.plan(
            ethereumRPC: "https://eth-mainnet.g.alchemy.com/v2/{KEY}",
            bitcoinAPI: "https://blockstream.info/api",
            litecoinAPI: "https://litecoinspace.org/api",
            solanaRPC: "https://solana-rpc.publicnode.com",
            tronAPI: "https://api.trongrid.io",
            evmChainId: 1
        )
        XCTAssertEqual(result.activeProvider, .alchemy)
        XCTAssertTrue(result.overrides.isEmpty,
                      "a recognised template is a provider, not an override")
    }

    func test_customURL_becomesAnOverrideForItsChain() {
        let result = NodeSettingsMigration.plan(
            ethereumRPC: "https://my-own-node.example/eth",
            bitcoinAPI: "https://blockstream.info/api",
            litecoinAPI: "https://litecoinspace.org/api",
            solanaRPC: "https://solana-rpc.publicnode.com",
            tronAPI: "https://api.trongrid.io",
            evmChainId: 1
        )
        XCTAssertNil(result.activeProvider)
        XCTAssertEqual(result.overrides[.ethereum], "https://my-own-node.example/eth")
        XCTAssertEqual(result.overrides.count, 1)
    }

    /// The Ethereum slot was being used as Polygon. The URL belongs to
    /// the first-class Polygon chain, and the toggle returns to mainnet.
    func test_evmChainIdPointingAtPolygon_movesTheURLToPolygon() {
        let result = NodeSettingsMigration.plan(
            ethereumRPC: "https://my-own-node.example/polygon",
            bitcoinAPI: "https://blockstream.info/api",
            litecoinAPI: "https://litecoinspace.org/api",
            solanaRPC: "https://solana-rpc.publicnode.com",
            tronAPI: "https://api.trongrid.io",
            evmChainId: 137
        )
        XCTAssertEqual(result.overrides[.polygon], "https://my-own-node.example/polygon")
        XCTAssertNil(result.overrides[.ethereum])
        XCTAssertEqual(result.evmChainId, 1)
    }

    /// Same relocation, but the value was a default, so nothing is stored.
    func test_evmChainIdPointingAtPolygon_withDefaultURL_storesNothing() {
        let result = NodeSettingsMigration.plan(
            ethereumRPC: "https://polygon-bor-rpc.publicnode.com",
            bitcoinAPI: "https://blockstream.info/api",
            litecoinAPI: "https://litecoinspace.org/api",
            solanaRPC: "https://solana-rpc.publicnode.com",
            tronAPI: "https://api.trongrid.io",
            evmChainId: 137
        )
        XCTAssertTrue(result.overrides.isEmpty)
        XCTAssertEqual(result.evmChainId, 1)
    }

    func test_sepoliaToggle_isPreserved() {
        let result = NodeSettingsMigration.plan(
            ethereumRPC: "https://ethereum-sepolia-rpc.publicnode.com",
            bitcoinAPI: "https://blockstream.info/api",
            litecoinAPI: "https://litecoinspace.org/api",
            solanaRPC: "https://solana-rpc.publicnode.com",
            tronAPI: "https://api.trongrid.io",
            evmChainId: 11_155_111
        )
        XCTAssertEqual(result.evmChainId, 11_155_111,
                       "Sepolia is a valid Ethereum testnet toggle, not a second chain")
        XCTAssertTrue(result.overrides.isEmpty)
    }

    func test_customNonEVMURLs_becomeTheirOwnOverrides() {
        let result = NodeSettingsMigration.plan(
            ethereumRPC: "https://ethereum-rpc.publicnode.com",
            bitcoinAPI: "https://my-esplora.example/api",
            litecoinAPI: "https://litecoinspace.org/api",
            solanaRPC: "https://my-solana.example",
            tronAPI: "https://my-tron.example",
            evmChainId: 1
        )
        XCTAssertEqual(result.overrides[.bitcoin], "https://my-esplora.example/api")
        XCTAssertEqual(result.overrides[.solana], "https://my-solana.example")
        XCTAssertEqual(result.overrides[.tron], "https://my-tron.example")
        XCTAssertNil(result.overrides[.litecoin], "litecoin was on its default")
    }

    func test_apply_isIdempotent() {
        let config = NetworkConfig.shared
        let originalChainId = config.evmChainId
        defer {
            config.evmChainId = originalChainId
            config.activeProvider = nil
            ChainEndpointOverrides.shared.removeAll()
        }

        let plan = NodeSettingsMigration.Plan(
            activeProvider: .infura,
            overrides: [.polygon: "https://mine.example"],
            evmChainId: 1
        )
        NodeSettingsMigration.apply(plan, to: config)
        NodeSettingsMigration.apply(plan, to: config)

        XCTAssertEqual(config.activeProvider, .infura)
        XCTAssertEqual(ChainEndpointOverrides.shared.url(for: .polygon), "https://mine.example")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd ios && xcodegen generate && xcodebuild test -project Horcrux.xcodeproj \
  -scheme Horcrux -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO \
  -only-testing:HorcruxTests/NodeSettingsMigrationTests 2>&1 | grep -E "error:|TEST"
```

Expected: `error: cannot find 'NodeSettingsMigration' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ios/Horcrux/Core/NodeSettingsMigration.swift`:

```swift
import Foundation

/// One-time migration from the legacy five-URL-field model to
/// provider + per-chain overrides.
///
/// `plan` is pure so every rule is table-testable without touching
/// UserDefaults; `apply` performs the writes.
enum NodeSettingsMigration {

    struct Plan: Equatable {
        var activeProvider: NodeProvider?
        var overrides: [Chain: String]
        var evmChainId: UInt64
    }

    private static let versionKey = "com.horcrux.rpc.settingsMigrationVersion"
    private static let currentVersion = 1

    static func plan(
        ethereumRPC: String,
        bitcoinAPI: String,
        litecoinAPI: String,
        solanaRPC: String,
        tronAPI: String,
        evmChainId: UInt64
    ) -> Plan {
        var overrides: [Chain: String] = [:]
        var provider: NodeProvider?
        var resolvedChainId = evmChainId

        // The Ethereum slot could be pointed at any EVM network. When it
        // pointed somewhere other than Ethereum's own mainnet/Sepolia, the
        // value belongs to that first-class chain instead.
        let evmNetwork = EVMNetwork(rawValue: evmChainId) ?? .mainnet
        let evmTargetChain: Chain
        if evmNetwork == .mainnet || evmNetwork == .sepolia {
            evmTargetChain = .ethereum
        } else {
            evmTargetChain = Chain.allCases.first { $0.defaultEVMNetwork == evmNetwork } ?? .ethereum
            resolvedChainId = EVMNetwork.mainnet.rawValue
        }

        if let matched = detectProvider(in: ethereumRPC) {
            provider = matched
        } else if !isDefaultValue(ethereumRPC, for: evmTargetChain, evmNetwork: evmNetwork) {
            overrides[evmTargetChain] = ethereumRPC
        }

        if detectProvider(in: solanaRPC) != nil {
            provider = provider ?? detectProvider(in: solanaRPC)
        } else if !isDefaultValue(solanaRPC, for: .solana, evmNetwork: nil) {
            overrides[.solana] = solanaRPC
        }

        for (value, chain) in [(bitcoinAPI, Chain.bitcoin),
                               (litecoinAPI, Chain.litecoin),
                               (tronAPI, Chain.tron)] {
            if !isDefaultValue(value, for: chain, evmNetwork: nil) {
                overrides[chain] = value
            }
        }

        return Plan(activeProvider: provider,
                    overrides: overrides,
                    evmChainId: resolvedChainId)
    }

    /// True when `value` is one of the endpoints we ship for `chain`, in
    /// which case it must NOT become an override — the user stays on the
    /// default and keeps receiving default changes.
    private static func isDefaultValue(_ value: String,
                                       for chain: Chain,
                                       evmNetwork: EVMNetwork?) -> Bool {
        if value.isEmpty { return true }
        if let net = evmNetwork, value == net.publicDefaultRPC { return true }
        var shipped = Set(RPCFallbacks.endpoints(for: chain, config: NetworkConfig.shared))
        shipped.insert(NetworkConfig.shared.publicDefault(for: chain))
        if chain.isEVM {
            shipped.formUnion(EVMNetwork.allCases.map(\.publicDefaultRPC))
        }
        return shipped.contains(value)
    }

    private static func detectProvider(in url: String) -> NodeProvider? {
        guard url.contains("{KEY}") else { return nil }
        for provider in NodeProvider.allCases {
            for chain in Chain.allCases {
                for net in EVMNetwork.allCases {
                    if provider.template(for: chain, evmChainId: net.rawValue) == url {
                        return provider
                    }
                }
            }
        }
        return nil
    }

    static func apply(_ plan: Plan, to config: NetworkConfig) {
        config.activeProvider = plan.activeProvider
        config.evmChainId = plan.evmChainId
        for (chain, url) in plan.overrides {
            ChainEndpointOverrides.shared.set(url, for: chain)
        }
    }

    /// Entry point called once at launch.
    static func runIfNeeded(config: NetworkConfig,
                            defaults: UserDefaults = .standard) {
        guard defaults.integer(forKey: versionKey) < currentVersion else { return }
        let plan = plan(
            ethereumRPC: config.ethereumRPC,
            bitcoinAPI: config.bitcoinAPI,
            litecoinAPI: config.litecoinAPI,
            solanaRPC: config.solanaRPC,
            tronAPI: config.tronAPI,
            evmChainId: config.evmChainId
        )
        apply(plan, to: config)
        defaults.set(currentVersion, forKey: versionKey)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Expected: `TEST SUCCEEDED`, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add ios/Horcrux/Core/NodeSettingsMigration.swift \
        ios/HorcruxTests/NodeSettingsMigrationTests.swift \
        ios/Horcrux.xcodeproj/project.pbxproj
git commit -m "feat(ios): migrate legacy node settings to provider + overrides

plan() is pure so every rule is table-testable; apply() does the writes.

The load-bearing rule: a stored URL equal to a shipped default migrates
to nothing. Writing it into an override would freeze that user on
today's default and no future endpoint fix would reach them.
migrateDeadEndpoints exists because stored URLs do get frozen and
currently lists seven dead URLs.

A non-Ethereum evmChainId means the Ethereum slot was being used as
another chain; the URL moves to that first-class chain and the toggle
returns to mainnet."
```

### Task 8: Call the migration at launch

**Files:**
- Modify: `ios/Horcrux/Core/NetworkConfig.swift` (end of `init()`)

- [ ] **Step 1: Write the failing test**

Append to `NodeSettingsMigrationTests`:

```swift
    func test_runIfNeeded_isSkippedOnceTheVersionIsRecorded() {
        let suiteName = "migration-test-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("could not create a test defaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let config = NetworkConfig.shared
        let originalChainId = config.evmChainId
        defer {
            config.evmChainId = originalChainId
            config.activeProvider = nil
            ChainEndpointOverrides.shared.removeAll()
        }

        NodeSettingsMigration.runIfNeeded(config: config, defaults: defaults)
        let firstRunProvider = config.activeProvider

        config.activeProvider = nil
        NodeSettingsMigration.runIfNeeded(config: config, defaults: defaults)
        XCTAssertNil(config.activeProvider,
                     "a second run must be a no-op, not re-derive state the user has since changed")
        _ = firstRunProvider
    }
```

- [ ] **Step 2: Run the test to verify it fails or passes**

Run the same command. This test may already pass — `runIfNeeded` exists
from Task 7. If it passes, that is fine; it is a regression guard for the
version gate. Confirm it passes before continuing.

- [ ] **Step 3: Wire the call**

At the very end of `NetworkConfig.init()`, after the last assignment and
after the existing `migrateDeadEndpoints` call, add:

```swift
        NodeSettingsMigration.runIfNeeded(config: self)
```

If Swift rejects using `self` there because initialisation is incomplete,
move the call to the end of `init()` after every stored property is
assigned. All stored properties must already be set at that point.

- [ ] **Step 4: Run the full affected test set**

```bash
cd ios && xcodebuild test -project Horcrux.xcodeproj -scheme Horcrux \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO \
  -only-testing:HorcruxTests/NodeSettingsMigrationTests \
  -only-testing:HorcruxTests/EndpointResolutionTests \
  -only-testing:HorcruxTests/NetworkConfigTests \
  -only-testing:HorcruxTests/RPCRoutingTests 2>&1 | grep -E "error:|Executed|TEST"
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add ios/Horcrux/Core/NetworkConfig.swift ios/HorcruxTests/NodeSettingsMigrationTests.swift
git commit -m "feat(ios): run the node settings migration once at launch"
```

---

## Phase 5 — Flip the resolver on

### Task 9: Route `rpcURL(for:)` through `resolveRawURL`

**Files:**
- Modify: `ios/Horcrux/Core/NetworkConfig.swift:264-279`
- Test: `ios/HorcruxTests/EndpointResolutionTests.swift`

This is the behavioural change. It is deliberately one small diff.

- [ ] **Step 1: Write the failing test**

Append to `EndpointResolutionTests`:

```swift
    /// The headline fix: nine chains that could not be configured at all.
    func test_rpcURL_honoursAnOverrideForAPreviouslyUnconfigurableChain() {
        withCleanConfig { config in
            ChainEndpointOverrides.shared.set("https://my-base.example", for: .base)
            XCTAssertEqual(config.rpcURL(for: .base), "https://my-base.example")
        }
    }

    func test_rpcURL_neverLeaksAPlaceholder() {
        withCleanConfig { config in
            config.activeProvider = .alchemy
            config.alchemyAPIKey = "abc123"
            for chain in Chain.allCases {
                let url = config.rpcURL(for: chain)
                XCTAssertFalse(url.contains("{KEY}"), "\(chain): \(url)")
                XCTAssertFalse(url.isEmpty, "\(chain)")
            }
        }
    }

    func test_rpcURL_appliesTheProviderKey() {
        withCleanConfig { config in
            config.activeProvider = .alchemy
            config.alchemyAPIKey = "abc123"
            XCTAssertEqual(config.rpcURL(for: .base),
                           "https://base-mainnet.g.alchemy.com/v2/abc123")
        }
    }

    /// An override the user typed has no {KEY}, so no key may be spliced
    /// into it even when the host matches a provider the user has a key for.
    func test_rpcURL_doesNotInjectAKeyIntoAKeylessOverride() {
        withCleanConfig { config in
            config.tenderlyAPIKey = "secret-key"
            defer { config.tenderlyAPIKey = "" }
            ChainEndpointOverrides.shared.set("https://mainnet.gateway.tenderly.co", for: .base)
            let url = config.rpcURL(for: .base)
            XCTAssertEqual(url, "https://mainnet.gateway.tenderly.co")
            XCTAssertFalse(url.contains("secret-key"))
        }
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Expected: `test_rpcURL_honoursAnOverrideForAPreviouslyUnconfigurableChain`
fails — `rpcURL(for: .base)` still returns the hardcoded default.

- [ ] **Step 3: Replace the body of `rpcURL(for:)`**

Replace lines 264–279 of `ios/Horcrux/Core/NetworkConfig.swift`
(the whole existing `func rpcURL(for chain: Chain) -> String { ... }`)
with:

```swift
    func rpcURL(for chain: Chain) -> String {
        return substituteAPIKey(in: resolveRawURL(for: chain), chain: chain)
    }
```

The legacy `ethereumRPC` / `bitcoinAPI` / `litecoinAPI` / `solanaRPC` /
`tronAPI` properties stay for now — the settings UI still binds to them
and Task 12 removes those bindings. Do not delete them in this task.

- [ ] **Step 4: Run the affected tests**

```bash
cd ios && xcodebuild test -project Horcrux.xcodeproj -scheme Horcrux \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO \
  -only-testing:HorcruxTests/EndpointResolutionTests \
  -only-testing:HorcruxTests/NetworkConfigTests \
  -only-testing:HorcruxTests/RPCRoutingTests \
  -only-testing:HorcruxTests/BlockchainServiceTests 2>&1 | grep -E "error:|Executed|TEST"
```

Expected: all pass. `NetworkConfigTests` has assertions such as
`test_rpcURL_forBitcoin_returnsBitcoinAPI` that compare `rpcURL(for:)`
against `config.bitcoinAPI`. With no override set and no provider, the
resolver returns the public default, which equals `bitcoinAPI` for a
default install — so they should still pass. **If one fails**, the legacy
field and the public default have diverged for that chain; update the
test to compare against `config.publicDefault(for:)` and note why in the
commit message rather than weakening the resolver.

- [ ] **Step 5: Commit**

```bash
git add ios/Horcrux/Core/NetworkConfig.swift ios/HorcruxTests/EndpointResolutionTests.swift
git commit -m "feat(ios): resolve every chain through override/provider/public

Nine EVM chains -- BNB, Polygon, Arbitrum, Base, Avalanche, Optimism,
zkSync, Linea, Scroll -- become configurable for the first time. They
were previously pinned to hardcoded defaults with no setter, while the
settings screen still reported their health.

Legacy URL fields stay until the UI stops binding to them."
```

---

## Phase 6 — UI

### Task 10: Provider section

**Files:**
- Create: `ios/Horcrux/Features/Settings/NodeSettings/NodeProviderSection.swift`
- Modify: `ios/Horcrux/Features/Settings/SettingsView.swift`

- [ ] **Step 1: Write the view**

Create `ios/Horcrux/Features/Settings/NodeSettings/NodeProviderSection.swift`:

```swift
import SwiftUI

/// Primary node configuration: pick a provider, paste one key, and see
/// exactly which chains that covers.
struct NodeProviderSection: View {
    @ObservedObject private var config = NetworkConfig.shared
    @State private var draftKey: String = ""

    var body: some View {
        Section("Node provider") {
            Picker("Provider", selection: providerSelection) {
                Text("Public defaults").tag(nil as NodeProvider?)
                ForEach(NodeProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider as NodeProvider?)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("nodeSettings_providerPicker")

            if let provider = config.activeProvider {
                SecureField("\(provider.displayName) API key", text: $draftKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("nodeSettings_providerKeyField")
                    .onAppear { draftKey = config.apiKey(for: provider) }
                    .onChange(of: provider) { _, new in draftKey = config.apiKey(for: new) }
                    .onSubmit { config.setAPIKey(draftKey, for: provider) }

                Text(coverageText(for: provider))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("nodeSettings_coverageLine")
            } else {
                Text("Every chain uses its public endpoint. Add a provider key for a dedicated rate limit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var providerSelection: Binding<NodeProvider?> {
        Binding(get: { config.activeProvider },
                set: { config.activeProvider = $0 })
    }

    /// Names the gaps explicitly. A user who binds a key and assumes it
    /// covers everything, when it does not, has no reason to look again —
    /// so the silent gap is worse than having no key at all.
    private func coverageText(for provider: NodeProvider) -> String {
        if config.apiKey(for: provider).isEmpty {
            return "No key set — using public endpoints."
        }
        let uncovered = provider.uncoveredChains(evmChainId: config.evmChainId)
        let covered = Chain.allCases.count - uncovered.count
        if uncovered.isEmpty {
            return "\(provider.displayName) covers all \(Chain.allCases.count) chains."
        }
        let names = uncovered
            .sorted { $0.displayName < $1.displayName }
            .map(\.displayName)
            .joined(separator: ", ")
        return "\(provider.displayName) covers \(covered) of \(Chain.allCases.count) chains. "
            + "\(names) stay on public endpoints."
    }
}
```

- [ ] **Step 2: Add the key setter**

Append to `ios/Horcrux/Core/NodeProvider.swift`:

```swift
extension NetworkConfig {
    func setAPIKey(_ value: String, for provider: NodeProvider) {
        switch provider {
        case .alchemy:  alchemyAPIKey = value
        case .infura:   infuraAPIKey = value
        case .ankr:     ankrAPIKey = value
        case .blockpi:  blockpiAPIKey = value
        case .drpc:     drpcAPIKey = value
        case .nodeReal: nodeRealAPIKey = value
        case .tenderly: tenderlyAPIKey = value
        case .oneRPC:   oneRPCAPIKey = value
        }
    }
}
```

- [ ] **Step 3: Build to verify it compiles**

```bash
cd ios && xcodegen generate && xcodebuild build -project Horcrux.xcodeproj \
  -scheme Horcrux -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD"
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add ios/Horcrux/Features/Settings/NodeSettings/NodeProviderSection.swift \
        ios/Horcrux/Core/NodeProvider.swift ios/Horcrux.xcodeproj/project.pbxproj
git commit -m "feat(ios): add the provider section with an honest coverage line

The coverage line names the chains the selected provider does not serve.
A user who binds a key and wrongly assumes it covers everything has no
reason to look again, so a silent gap is worse than no key at all."
```

### Task 11: Chain list and detail

**Files:**
- Create: `ios/Horcrux/Features/Settings/NodeSettings/ChainEndpointList.swift`
- Create: `ios/Horcrux/Features/Settings/NodeSettings/ChainEndpointDetailView.swift`

- [ ] **Step 1: Write the source-badge model and list**

Create `ios/Horcrux/Features/Settings/NodeSettings/ChainEndpointList.swift`:

```swift
import SwiftUI

/// Where a chain's endpoint currently comes from. This is the question
/// the old screen could not answer for nine of the fourteen chains.
enum EndpointSource {
    case override
    case provider(NodeProvider)
    case publicDefault

    var label: String {
        switch self {
        case .override: return "Custom"
        case .provider(let p): return p.displayName
        case .publicDefault: return "Public"
        }
    }
}

extension NetworkConfig {
    func endpointSource(for chain: Chain) -> EndpointSource {
        if ChainEndpointOverrides.shared.url(for: chain) != nil { return .override }
        if let provider = activeProvider,
           !apiKey(for: provider).isEmpty,
           provider.template(for: chain, evmChainId: evmChainId) != nil {
            return .provider(provider)
        }
        return .publicDefault
    }
}

struct ChainEndpointList: View {
    @ObservedObject private var config = NetworkConfig.shared
    @ObservedObject private var overrides = ChainEndpointOverrides.shared

    var body: some View {
        Section("Chains") {
            ForEach(Chain.allCases) { chain in
                NavigationLink {
                    ChainEndpointDetailView(chain: chain)
                } label: {
                    HStack {
                        Text(chain.displayName)
                        Spacer()
                        Text(config.endpointSource(for: chain).label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("nodeSettings_chainRow_\(chain.rawValue)")
            }
        }
    }
}
```

- [ ] **Step 2: Write the detail view**

Create `ios/Horcrux/Features/Settings/NodeSettings/ChainEndpointDetailView.swift`:

```swift
import SwiftUI

struct ChainEndpointDetailView: View {
    let chain: Chain

    @ObservedObject private var config = NetworkConfig.shared
    @ObservedObject private var overrides = ChainEndpointOverrides.shared
    @State private var draft: String = ""

    var body: some View {
        Form {
            Section("Effective endpoint") {
                Text(config.resolveRawURL(for: chain))
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                Text("Source: \(config.endpointSource(for: chain).label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Custom URL") {
                TextField(config.publicDefault(for: chain), text: $draft)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("nodeSettings_overrideField")
                    .onSubmit { overrides.set(draft, for: chain) }

                Button("Use the default") {
                    draft = ""
                    overrides.clear(chain)
                }
                .disabled(overrides.url(for: chain) == nil)
            }

            Section {
                NodeStatusRow(chain: chain)
            }
        }
        .navigationTitle(chain.displayName)
        .onAppear { draft = overrides.url(for: chain) ?? "" }
    }
}
```

`NodeStatusRow` already exists in `SettingsView.swift` and takes a
`chain:` argument — reuse it rather than writing a second status view.
It already renders `snapshot.mismatchWarning`, which is the chain-ID
mismatch surface the spec asks for. Do not add a second one.

`NodeHealthStore.detectMismatch` (`NetworkConfig.swift:1853`) already
derives the expected chain ID the way this design wants: `config.evmChainId`
for `.ethereum` only, `chain.defaultEVMNetwork.rawValue` for every other
EVM chain. It therefore survives Task 12's narrowing untouched. Do not
"fix" it to read `evmChainId` for all chains — that would report a false
mismatch on all nine newly-configurable chains.

This view has no key field yet, so a pasted `{KEY}` template cannot be
completed. Task 15 adds that. Leave it out here.

- [ ] **Step 3: Build to verify it compiles**

```bash
cd ios && xcodegen generate && xcodebuild build -project Horcrux.xcodeproj \
  -scheme Horcrux -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD"
```

Expected: `BUILD SUCCEEDED`. If `NodeStatusRow` is `private` in
`SettingsView.swift`, remove the `private` modifier — do not duplicate it.

- [ ] **Step 4: Commit**

```bash
git add ios/Horcrux/Features/Settings/NodeSettings/ChainEndpointList.swift \
        ios/Horcrux/Features/Settings/NodeSettings/ChainEndpointDetailView.swift \
        ios/Horcrux/Features/Settings/SettingsView.swift \
        ios/Horcrux.xcodeproj/project.pbxproj
git commit -m "feat(ios): list all fourteen chains with a source badge

The badge answers 'where does this chain actually go', which the old
screen could not answer for nine chains and answered ambiguously for
Ethereum. A uniform list also means a new chain appears automatically
instead of waiting for someone to hand-write a section."
```

### Task 12: Swap the sections into `BlockchainNodeSettingsView`

**Files:**
- Modify: `ios/Horcrux/Features/Settings/SettingsView.swift:1183-1400`

- [ ] **Step 1: Replace the three hand-written sections**

In `BlockchainNodeSettingsView.body`, delete the
`Section(L10n.NodeSettings.ethereumEVM)`, `Section(L10n.NodeSettings.bitcoin)`
and `Section(L10n.NodeSettings.solana)` blocks and put in their place:

```swift
            NodeProviderSection()
            ChainEndpointList()
```

Keep `Section(L10n.NodeSettings.quickPresets)` and
`EndpointCooldownSection()` exactly where they are.

Ethereum's mainnet/Sepolia toggle moves into
`ChainEndpointDetailView` for `.ethereum` only. Add to that view, inside
the `Form`, before the "Custom URL" section:

```swift
            if chain == .ethereum {
                Section("Network") {
                    Picker("Network", selection: $config.evmChainId) {
                        Text("Mainnet").tag(EVMNetwork.mainnet.rawValue)
                        Text("Sepolia").tag(EVMNetwork.sepolia.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("nodeSettings_ethereumNetworkPicker")
                }
            }
```

Only mainnet and Sepolia appear. Polygon, Base and the rest are reached
as their own chains now, so offering them here would recreate the two
different Polygons the design removes.

- [ ] **Step 2: Build and run the affected tests**

```bash
cd ios && xcodegen generate && xcodebuild test -project Horcrux.xcodeproj \
  -scheme Horcrux -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO \
  -only-testing:HorcruxTests/EndpointResolutionTests \
  -only-testing:HorcruxTests/NetworkConfigTests \
  -only-testing:HorcruxTests/RPCRoutingTests \
  -only-testing:HorcruxTests/NodeProviderTests \
  -only-testing:HorcruxTests/NodeSettingsMigrationTests 2>&1 | grep -E "error:|Executed|TEST"
```

Expected: `BUILD SUCCEEDED` and all tests pass. Fix any reference to a
deleted symbol (`selectedEVMProvider`, `detectActiveEVMProvider`,
`PaidEVMProvider`) by deleting it — `NodeProvider` replaces all three.

- [ ] **Step 3: Commit**

```bash
git add ios/Horcrux/Features/Settings/SettingsView.swift ios/Horcrux.xcodeproj/project.pbxproj
git commit -m "refactor(ios): replace the per-chain node sections with provider + chain list

The EVM network picker narrows to mainnet and Sepolia. Polygon, Base and
the rest are first-class chains now, so offering them in Ethereum's
network picker would recreate the two-different-Polygons ambiguity the
design removes."
```

---

## Phase 7 — Snapshot versioning

### Task 13: Version `RPCConfigSnapshot`

**Files:**
- Modify: `ios/Horcrux/Features/Settings/SettingsView.swift:2118-2160`
- Test: `ios/HorcruxTests/NodeSettingsMigrationTests.swift`

Without a version field, an older build importing a newer export drops
`chainOverrides` silently through Codable's unknown-key behaviour and
reports success, leaving the user with a wrong configuration and nothing
telling them so.

- [ ] **Step 1: Write the failing test**

Append to `NodeSettingsMigrationTests`:

```swift
    func test_snapshot_roundTripsOverridesAndProvider() {
        let config = NetworkConfig.shared
        defer {
            config.activeProvider = nil
            ChainEndpointOverrides.shared.removeAll()
        }
        config.activeProvider = .drpc
        ChainEndpointOverrides.shared.set("https://mine.example", for: .scroll)

        let snapshot = RPCConfigSnapshot(from: config)
        guard let json = snapshot.jsonString(),
              let decoded = RPCConfigSnapshot.decode(json) else {
            return XCTFail("snapshot did not round-trip")
        }
        XCTAssertEqual(decoded.activeProvider, .drpc)
        XCTAssertEqual(decoded.chainOverrides?["Scroll"], "https://mine.example")
    }

    /// An older export has no version field and must still import.
    func test_snapshot_decodesALegacyExportWithNoVersion() {
        let legacy = """
        {"bitcoinAPI":"https://blockstream.info/api",\
        "btcTestnet":false,\
        "ethereumRPC":"https://ethereum-rpc.publicnode.com",\
        "evmChainId":1,\
        "litecoinAPI":"https://litecoinspace.org/api",\
        "solDevnet":false,\
        "solanaRPC":"https://solana-rpc.publicnode.com",\
        "tronAPI":"https://api.trongrid.io"}
        """
        let decoded = RPCConfigSnapshot.decode(legacy)
        XCTAssertNotNil(decoded)
        XCTAssertNil(decoded?.activeProvider)
    }

    /// A newer export must be refused rather than silently losing fields.
    func test_snapshot_refusesAFutureVersion() {
        let future = """
        {"version":99,\
        "bitcoinAPI":"https://blockstream.info/api",\
        "btcTestnet":false,\
        "ethereumRPC":"https://ethereum-rpc.publicnode.com",\
        "evmChainId":1,\
        "litecoinAPI":"https://litecoinspace.org/api",\
        "solDevnet":false,\
        "solanaRPC":"https://solana-rpc.publicnode.com",\
        "tronAPI":"https://api.trongrid.io"}
        """
        XCTAssertNil(RPCConfigSnapshot.decode(future),
                     "importing a newer format must fail loudly, not drop fields")
    }
```

- [ ] **Step 2: Run to verify it fails**

Expected: `error: value of type 'RPCConfigSnapshot' has no member 'activeProvider'`.

- [ ] **Step 3: Write the implementation**

In `RPCConfigSnapshot` (SettingsView.swift:2118) add the properties:

```swift
    var version: Int?
    var activeProvider: NodeProvider?
    var chainOverrides: [String: String]?
```

and inside `init(from config: NetworkConfig)` add:

```swift
        self.version = RPCConfigSnapshot.currentVersion
        self.activeProvider = config.activeProvider
        self.chainOverrides = ChainEndpointOverrides.shared.overrides
```

Add the constant and the guard:

```swift
    static let currentVersion = 2
```

This is `RPCConfigSnapshot.currentVersion`, the export wire format. It
is unrelated to `NodeSettingsMigration.currentVersion` in Task 7, which
is a local one-shot migration marker. They are different numbers on
purpose. Do not harmonise them.

```swift
    static func decode(_ text: String) -> RPCConfigSnapshot? {
        guard let data = text.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(RPCConfigSnapshot.self, from: data)
        else { return nil }
        // A missing version is a pre-versioning export and is fine. A
        // higher one means fields this build cannot represent, and
        // Codable would drop them without a word.
        if let v = snapshot.version, v > currentVersion { return nil }
        return snapshot
    }
```

In `apply(to:)`, add:

```swift
        config.activeProvider = activeProvider
        if let overrides = chainOverrides {
            ChainEndpointOverrides.shared.removeAll()
            for (rawChain, url) in overrides {
                guard let chain = Chain(rawValue: rawChain) else { continue }
                ChainEndpointOverrides.shared.set(url, for: chain)
            }
        }
```

All three new properties are optional, so pre-versioning exports still
decode.

- [ ] **Step 4: Run to verify it passes**

Expected: `TEST SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add ios/Horcrux/Features/Settings/SettingsView.swift \
        ios/HorcruxTests/NodeSettingsMigrationTests.swift
git commit -m "feat(ios): version the RPC config snapshot

New fields are optional so pre-versioning exports still import. A
higher version is refused outright: Codable would otherwise drop
chainOverrides silently and report success, handing the user a
configuration that is wrong in a way nothing told them about."
```

---

## Phase 8 — Close out

### Task 14: Extend the keyless-override guard and update docs

**Files:**
- Modify: `ios/HorcruxTests/RPCRoutingTests.swift`
- Modify: `CHANGELOG.md`
- Modify: `docs/superpowers/specs/2026-07-29-node-settings-provider-first-design.md` (status line)

- [ ] **Step 1: Extend the guard**

Append to `RPCRoutingTests`:

```swift
    /// Overrides are user-typed and carry no {KEY}, so no stored key may
    /// be spliced into one even when its host matches a provider the user
    /// holds a key for. Otherwise a hand-entered endpoint would start
    /// spending that key's quota and bind the traffic to a billing identity.
    func test_overrideURLs_areNeverRewrittenWithAConfiguredKey() {
        let config = NetworkConfig.shared
        config.tenderlyAPIKey = "test-tenderly-key"
        defer {
            config.tenderlyAPIKey = ""
            ChainEndpointOverrides.shared.removeAll()
        }

        for chain in Chain.allCases {
            ChainEndpointOverrides.shared.set("https://mainnet.gateway.tenderly.co", for: chain)
            let url = config.rpcURL(for: chain)
            XCTAssertEqual(url, "https://mainnet.gateway.tenderly.co", "\(chain)")
            XCTAssertFalse(url.contains("test-tenderly-key"), "\(chain)")
        }
    }
```

- [ ] **Step 2: Run the whole affected set**

```bash
cd ios && xcodebuild test -project Horcrux.xcodeproj -scheme Horcrux \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO \
  -only-testing:HorcruxTests/RPCRoutingTests \
  -only-testing:HorcruxTests/NodeProviderTests \
  -only-testing:HorcruxTests/EndpointResolutionTests \
  -only-testing:HorcruxTests/NodeSettingsMigrationTests \
  -only-testing:HorcruxTests/NetworkConfigTests \
  -only-testing:HorcruxTests/CertificatePinnerTests \
  -only-testing:HorcruxTests/BlockchainServiceTests 2>&1 | grep -E "error:|Executed|TEST"
```

Expected: all pass.

- [ ] **Step 3: Update `CHANGELOG.md`**

Under `## [Unreleased]`, add a `### iOS — node settings` block covering:
nine chains becoming configurable for the first time; provider-first
configuration with one key across every covered chain; the coverage line
naming uncovered chains; per-chain overrides replacing the single shared
EVM field that let a Polygon URL apply to Base; `evmChainId` narrowed to
Ethereum's testnet toggle; snapshot versioning.

- [ ] **Step 4: Update the spec status line**

Change the `**Status:**` line of
`docs/superpowers/specs/2026-07-29-node-settings-provider-first-design.md`
to `Implemented in <first commit sha>..<last commit sha>.`

- [ ] **Step 5: Commit and push**

```bash
git add ios/HorcruxTests/RPCRoutingTests.swift CHANGELOG.md \
        docs/superpowers/specs/2026-07-29-node-settings-provider-first-design.md
git commit -m "test(ios): guard overrides against key injection; record the change"
git push
```

- [ ] **Step 6: Verify CI is green**

```bash
gh run list --limit 5 --json workflowName,conclusion,headSha \
  --jq '.[] | "\(.conclusion // "running")\t\(.workflowName)\t\(.headSha[0:7])"'
```

Expected: `CI` succeeds. If `rpc-endpoints` runs, it should also pass —
this change touches `NetworkConfig.swift`, which is one of its triggers.

---

### Task 15: Restore key entry for single-chain providers

**Why this exists:** the provider picker is the only UI that ever wrote
`getblockAPIKey` (`SettingsView.swift:1048`, inside `keyBinding(for:)`).
GetBlock is not in `NodeProvider` — its token is bound to one chain in
its dashboard, so it can't be an account-wide provider — which means
Task 10 removes the last way to set that key. A user pasting GetBlock's
`https://go.getblock.io/{KEY}/` as a per-chain override would then be
stuck with an unsubstitutable `{KEY}` forever.

`heliusAPIKey` is *not* affected: it has its own field in the Solana
section (`SettingsView.swift:1166`), which this plan never touches.

**Files:**
- Modify: `ios/Horcrux/Core/NetworkConfig.swift:385-429`
- Modify: `ios/Horcrux/Features/Settings/NodeSettings/ChainEndpointDetailView.swift`
- Test: `ios/HorcruxTests/RPCRoutingTests.swift`

This is the one place the plan grows `NetworkConfig.swift`, and it grows
it by roughly zero: the host routing moves out of `substituteAPIKey`
into a named accessor that both the resolver and the UI call. Two copies
of that host switch would drift, and a drift here means the UI writes a
key the resolver never reads.

- [ ] **Step 1: Write the failing test**

Add to `ios/HorcruxTests/RPCRoutingTests.swift`:

```swift
func testKeySlotRoutesGetBlockOverrideToItsOwnField() {
    let config = NetworkConfig.shared
    let slot = config.apiKeySlot(forHost: "go.getblock.io", chain: .polygon)
    XCTAssertEqual(slot?.keyPath, \NetworkConfig.getblockAPIKey,
                   "A GetBlock override must write the GetBlock key slot, "
                   + "not the Alchemy catch-all.")
    XCTAssertEqual(slot?.displayName, "GetBlock")
}

func testKeySlotFallsBackToAlchemyForUnknownEVMHost() {
    let config = NetworkConfig.shared
    let slot = config.apiKeySlot(forHost: "rpc.example.invalid", chain: .base)
    XCTAssertEqual(slot?.keyPath, \NetworkConfig.alchemyAPIKey,
                   "Unknown EVM hosts must resolve to the same slot "
                   + "substituteAPIKey uses, or the field would write a "
                   + "key the resolver never reads.")
}

func testKeySlotIsNilForChainsWithNoKeyedProvider() {
    let config = NetworkConfig.shared
    XCTAssertNil(config.apiKeySlot(forHost: "example.invalid", chain: .bitcoin),
                 "Bitcoin has no {KEY} provider; the detail view must not "
                 + "offer a key field that goes nowhere.")
}

func testSubstituteAPIKeyStillUsesTheSlotRouting() {
    let config = NetworkConfig.shared
    let previous = config.getblockAPIKey
    defer { config.getblockAPIKey = previous }
    config.getblockAPIKey = "gb-test"
    let out = config.substituteAPIKey(in: "https://go.getblock.io/{KEY}/",
                                      chain: .polygon)
    XCTAssertEqual(out, "https://go.getblock.io/gb-test/")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd ios && xcodegen generate && xcodebuild test -project Horcrux.xcodeproj \
  -scheme Horcrux -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO \
  -only-testing:HorcruxTests/RPCRoutingTests 2>&1 | grep -E "error:|failed|passed"
```

Expected: compile error — `apiKeySlot(forHost:chain:)` does not exist.

- [ ] **Step 3: Extract the slot accessor**

In `ios/Horcrux/Core/NetworkConfig.swift`, add above `substituteAPIKey`:

```swift
/// Which stored key a `{KEY}` template draws from, and what to call it
/// in the UI. `substituteAPIKey` and the per-chain override editor both
/// route through this so a field can never write a slot the resolver
/// does not read.
struct APIKeySlot {
    let keyPath: ReferenceWritableKeyPath<NetworkConfig, String>
    let displayName: String
}

func apiKeySlot(forHost host: String, chain: Chain) -> APIKeySlot? {
    let h = host.lowercased()
    if chain.isEVM {
        if h.contains("infura.io") {
            return APIKeySlot(keyPath: \.infuraAPIKey, displayName: "Infura")
        } else if h.contains("ankr.com") {
            return APIKeySlot(keyPath: \.ankrAPIKey, displayName: "Ankr")
        } else if h.contains("blockpi.network") {
            return APIKeySlot(keyPath: \.blockpiAPIKey, displayName: "BlockPI")
        } else if h.contains("drpc.org") {
            return APIKeySlot(keyPath: \.drpcAPIKey, displayName: "dRPC")
        } else if h.contains("nodereal.io") {
            return APIKeySlot(keyPath: \.nodeRealAPIKey, displayName: "NodeReal")
        } else if h.contains("getblock.io") {
            return APIKeySlot(keyPath: \.getblockAPIKey, displayName: "GetBlock")
        } else if h.contains("tenderly.co") {
            return APIKeySlot(keyPath: \.tenderlyAPIKey, displayName: "Tenderly")
        } else if h.contains("1rpc.io") {
            return APIKeySlot(keyPath: \.oneRPCAPIKey, displayName: "1RPC")
        }
        // Alchemy is the default EVM slot; it also catches bare template
        // URLs the user has not pointed at a specific provider yet.
        return APIKeySlot(keyPath: \.alchemyAPIKey, displayName: "Alchemy")
    }
    guard chain == .solana else { return nil }
    if h.contains("infura.io") {
        return APIKeySlot(keyPath: \.infuraAPIKey, displayName: "Infura")
    } else if h.contains("alchemy.com") {
        return APIKeySlot(keyPath: \.alchemyAPIKey, displayName: "Alchemy")
    } else if h.contains("ankr.com") {
        return APIKeySlot(keyPath: \.ankrAPIKey, displayName: "Ankr")
    } else if h.contains("drpc.org") {
        return APIKeySlot(keyPath: \.drpcAPIKey, displayName: "dRPC")
    } else if h.contains("getblock.io") {
        return APIKeySlot(keyPath: \.getblockAPIKey, displayName: "GetBlock")
    } else if h.contains("1rpc.io") {
        return APIKeySlot(keyPath: \.oneRPCAPIKey, displayName: "1RPC")
    }
    return APIKeySlot(keyPath: \.heliusAPIKey, displayName: "Helius")
}
```

- [ ] **Step 4: Rewrite `substituteAPIKey` to use it**

Replace the whole `if chain.isEVM { … } else { … }` host-routing block
(the body between `let key: String` and the closing brace before
`if key.isEmpty`) with:

```swift
let key = apiKeySlot(forHost: host, chain: chain).map { self[keyPath: $0.keyPath] } ?? ""
```

The `guard url.contains("{KEY}") else { return url }` line at the top
stays exactly as it is. That guard is what stops a user's paid key from
being appended to keyless public fallbacks, and Task 14 tests it.

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd ios && xcodebuild test -project Horcrux.xcodeproj -scheme Horcrux \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO \
  -only-testing:HorcruxTests/RPCRoutingTests 2>&1 | grep -E "error:|failed|passed"
```

Expected: all pass. The pre-existing `substituteAPIKey` tests must pass
unchanged — this step is a refactor, not a behaviour change.

- [ ] **Step 6: Add the key field to the override editor**

In `ChainEndpointDetailView.swift`, inside the `Custom URL` section,
after the `Button("Use the default")`:

```swift
if draft.contains("{KEY}"),
   let slot = config.apiKeySlot(forHost: URL(string: draft)?.host ?? "",
                                chain: chain) {
    SecureField("\(slot.displayName) API key",
                text: Binding(get: { config[keyPath: slot.keyPath] },
                              set: { config[keyPath: slot.keyPath] = $0 }))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .accessibilityIdentifier("nodeSettings_overrideKeyField")

    Text("`{KEY}` in the URL is replaced with this key. It stays on this device.")
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

- [ ] **Step 7: Build and run the full node-settings tests**

```bash
cd ios && xcodegen generate && xcodebuild test -project Horcrux.xcodeproj \
  -scheme Horcrux -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO \
  -only-testing:HorcruxTests/RPCRoutingTests \
  -only-testing:HorcruxTests/NodeSettingsMigrationTests 2>&1 \
  | grep -E "error:|failed|passed"
```

Expected: `BUILD SUCCEEDED` and all pass.

- [ ] **Step 8: Commit and push**

```bash
git add ios/Horcrux/Core/NetworkConfig.swift \
        ios/Horcrux/Features/Settings/NodeSettings/ChainEndpointDetailView.swift \
        ios/HorcruxTests/RPCRoutingTests.swift
git commit -m "fix(ios): keep key entry reachable for single-chain providers

GetBlock issues a token bound to one chain, so it cannot be an
account-wide provider and is not in the picker. Without this, removing
the old picker would have left its key unsettable and a pasted
go.getblock.io/{KEY}/ override permanently unsubstitutable.

The host routing now lives in one accessor that both substituteAPIKey
and the override editor call, so the field cannot write a slot the
resolver does not read."
git push
```

---

## Out of scope

Carried in the spec's open questions, not in this plan:

- Verifying a pasted key with a live `eth_chainId` call on entry.
- Whether `chainOverrides` should be excluded from export, given a
  self-hosted node address is closer to personal data than the rest of
  the snapshot.
- Onboarding changes (issue #27).
- Certificate pinning coverage for the new provider hosts.

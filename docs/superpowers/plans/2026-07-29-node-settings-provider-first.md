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
| `ios/Horcrux/Features/Settings/NodeSettings/ProviderCoverageSummary.swift` | Pure partition: overridden / provider-covered / public-default. Override-aware so the coverage line can't misreport a user endpoint as public. |
| `ios/Horcrux/Features/Settings/NodeSettings/ChainEndpointList.swift` | The fourteen-row list with source badges. |
| `ios/Horcrux/Features/Settings/NodeSettings/ChainEndpointDetailView.swift` | Per-chain detail and override editor. |
| `ios/HorcruxTests/NodeProviderTests.swift` | Coverage matrix and template lookup. |
| `ios/HorcruxTests/EndpointResolutionTests.swift` | The three-step resolver. |
| `ios/HorcruxTests/NodeSettingsMigrationTests.swift` | Table-driven migration cases. |
| `ios/HorcruxTests/ProviderCoverageSummaryTests.swift` | Table-driven partition tests and partition invariant. |

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
        let url = NodeProvider.alchemy.template(for: .polygon, evmChainId: 1, solanaMainnet: true)
        XCTAssertEqual(url, "https://polygon-mainnet.g.alchemy.com/v2/{KEY}")
    }

    /// Alchemy has no BNB product. Returning a wrong-chain URL here would
    /// send Ethereum traffic to a BNB address, so the gap must be nil.
    func test_alchemy_doesNotServeBNB() {
        XCTAssertNil(NodeProvider.alchemy.template(for: .bnb, evmChainId: 1, solanaMainnet: true))
    }

    /// Ethereum occupies the app's one user-selectable EVM slot, so it is
    /// the only chain whose template follows evmChainId.
    func test_ethereumTemplate_followsTheEVMChainIdToggle() {
        XCTAssertEqual(NodeProvider.alchemy.template(for: .ethereum, evmChainId: 1, solanaMainnet: true),
                       "https://eth-mainnet.g.alchemy.com/v2/{KEY}")
        XCTAssertEqual(NodeProvider.alchemy.template(for: .ethereum, evmChainId: 11_155_111, solanaMainnet: true),
                       "https://eth-sepolia.g.alchemy.com/v2/{KEY}")
    }

    /// The Ethereum slot accepts any of the eleven EVMNetwork values, not
    /// just mainnet and Sepolia. Pinned so nobody "simplifies" the
    /// `?? .mainnet` fallback into a wrong-chain bug.
    func test_ethereumSlot_followsAnyEVMNetworkSelection() {
        XCTAssertEqual(NodeProvider.alchemy.template(for: .ethereum, evmChainId: 137, solanaMainnet: true),
                       "https://polygon-mainnet.g.alchemy.com/v2/{KEY}")
    }

    /// An unrecognised stored chain ID must land somewhere real rather
    /// than returning nil and stranding the Ethereum slot.
    func test_unknownEVMChainId_fallsBackToMainnet() {
        XCTAssertEqual(NodeProvider.alchemy.template(for: .ethereum, evmChainId: 999_999, solanaMainnet: true),
                       "https://eth-mainnet.g.alchemy.com/v2/{KEY}")
    }

    /// No provider in this enum serves the non-EVM, non-Solana chains.
    func test_noProvider_claimsBitcoinLitecoinOrTron() {
        for provider in NodeProvider.allCases {
            for chain in [Chain.bitcoin, .litecoin, .tron] {
                for solanaMainnet in [true, false] {
                    XCTAssertNil(provider.template(for: chain, evmChainId: 1,
                                                   solanaMainnet: solanaMainnet),
                                 "\(provider) must not claim \(chain)")
                }
            }
        }
    }

    /// Every template must carry the placeholder, or substituteAPIKey
    /// silently returns it unchanged and the key is never applied.
    func test_everyTemplate_containsTheKeyPlaceholder() {
        var checked = 0
        for provider in NodeProvider.allCases {
            for chain in Chain.allCases {
                guard let t = provider.template(for: chain, evmChainId: 1,
                                                solanaMainnet: true) else { continue }
                checked += 1
                XCTAssertTrue(t.contains("{KEY}"), "\(provider)/\(chain): \(t)")
            }
        }
        // Exact, not `> 0`: a regression that nils out most providers would
        // otherwise still report green on the placeholder invariant.
        XCTAssertEqual(checked, expectedMainnetTemplateCount)
    }

    /// Alchemy's exact coverage on mainnet. An exact set fails loudly if
    /// the matrix drifts; a `contains` spot-check would not.
    func test_coveredChains_matchesTheDocumentedMatrix() {
        let uncovered = NodeProvider.alchemy.uncoveredChains(evmChainId: 1, solanaMainnet: true)
        XCTAssertEqual(uncovered, [.bnb, .bitcoin, .litecoin, .tron])
    }

    // MARK: - Solana cluster safety

    /// Solana addresses are byte-identical across clusters, so a provider
    /// that only has a mainnet host must return nil on devnet rather than
    /// hand back the mainnet URL. Ankr and dRPC are exactly that case.
    func test_ankrAndDRPC_returnNilOnSolanaDevnet() {
        XCTAssertEqual(NodeProvider.ankr.template(for: .solana, evmChainId: 1, solanaMainnet: true),
                       "https://rpc.ankr.com/solana/{KEY}")
        XCTAssertNil(NodeProvider.ankr.template(for: .solana, evmChainId: 1, solanaMainnet: false))

        XCTAssertEqual(NodeProvider.drpc.template(for: .solana, evmChainId: 1, solanaMainnet: true),
                       "https://lb.drpc.org/ogrpc?network=solana&dkey={KEY}")
        XCTAssertNil(NodeProvider.drpc.template(for: .solana, evmChainId: 1, solanaMainnet: false))
    }

    /// No Solana template may point at a mainnet host while the caller
    /// asked for devnet. This is the invariant that matters most here.
    func test_noSolanaDevnetTemplate_pointsAtAMainnetHost() {
        for provider in NodeProvider.allCases {
            guard let t = provider.template(for: .solana, evmChainId: 1,
                                            solanaMainnet: false) else { continue }
            XCTAssertFalse(t.contains("mainnet"), "\(provider) devnet template: \(t)")
            XCTAssertFalse(t.contains("rpc.ankr.com/solana"), "\(provider) devnet template: \(t)")
            XCTAssertFalse(t.contains("network=solana"), "\(provider) devnet template: \(t)")
        }
    }

    func test_solanaMainnetTemplates_areExact() {
        XCTAssertEqual(NodeProvider.alchemy.template(for: .solana, evmChainId: 1, solanaMainnet: true),
                       "https://solana-mainnet.g.alchemy.com/v2/{KEY}")
        XCTAssertNil(NodeProvider.blockpi.template(for: .solana, evmChainId: 1, solanaMainnet: true))
        XCTAssertNil(NodeProvider.nodeReal.template(for: .solana, evmChainId: 1, solanaMainnet: true))
        XCTAssertNil(NodeProvider.tenderly.template(for: .solana, evmChainId: 1, solanaMainnet: true))
    }

    /// Coverage must depend only on its arguments. If this ever fails,
    /// something started reading NetworkConfig.shared again.
    func test_coverage_isPureAcrossTheDevnetToggle() {
        let previous = NetworkConfig.shared.solDevnet
        defer { NetworkConfig.shared.solDevnet = previous }

        NetworkConfig.shared.solDevnet = false
        let a = NodeProvider.ankr.coveredChains(evmChainId: 1, solanaMainnet: true)
        NetworkConfig.shared.solDevnet = true
        let b = NodeProvider.ankr.coveredChains(evmChainId: 1, solanaMainnet: true)
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.contains(.solana))

        XCTAssertFalse(NodeProvider.ankr
            .coveredChains(evmChainId: 1, solanaMainnet: false).contains(.solana))
    }

    /// Derived from the matrix rather than hand-counted, so the assertion
    /// above stays honest when a provider or chain is added.
    private var expectedMainnetTemplateCount: Int {
        NodeProvider.allCases.reduce(0) {
            $0 + $1.coveredChains(evmChainId: 1, solanaMainnet: true).count
        }
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
    /// Both network selectors are explicit parameters. Reading either from
    /// `NetworkConfig.shared` would make this type return different answers
    /// for identical arguments, which a cached coverage set in the UI has no
    /// way to notice.
    ///
    /// `evmChainId` is consulted only for `.ethereum`, which occupies the
    /// app's one user-selectable EVM slot. Every other EVM chain maps
    /// through its fixed `defaultEVMNetwork`.
    func template(for chain: Chain, evmChainId: UInt64, solanaMainnet: Bool) -> String? {
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
        switch self {
        case .alchemy:  return RPCProviderTemplate.alchemySolana(mainnet: solanaMainnet)
        case .infura:   return RPCProviderTemplate.infuraSolana(mainnet: solanaMainnet)
        case .oneRPC:   return RPCProviderTemplate.oneRPCSolana(mainnet: solanaMainnet)
        // ankrSolana() and drpcSolana() hardcode mainnet hosts and have no
        // devnet variant. Solana addresses are byte-identical across
        // clusters, so handing back a mainnet URL while the user believes
        // they are on devnet would broadcast a "test" transfer against real
        // funds. A missing endpoint is recoverable; a wrong cluster is not.
        case .ankr:     return solanaMainnet ? RPCProviderTemplate.ankrSolana() : nil
        case .drpc:     return solanaMainnet ? RPCProviderTemplate.drpcSolana() : nil
        case .blockpi, .nodeReal, .tenderly: return nil
        }
    }

    private func evmNetwork(for chain: Chain, evmChainId: UInt64) -> EVMNetwork? {
        if chain == .ethereum {
            return EVMNetwork(rawValue: evmChainId) ?? .mainnet
        }
        return chain.defaultEVMNetwork
    }

    func coveredChains(evmChainId: UInt64, solanaMainnet: Bool) -> Set<Chain> {
        Set(Chain.allCases.filter {
            template(for: $0, evmChainId: evmChainId, solanaMainnet: solanaMainnet) != nil
        })
    }

    func uncoveredChains(evmChainId: UInt64, solanaMainnet: Bool) -> Set<Chain> {
        Set(Chain.allCases)
            .subtracting(coveredChains(evmChainId: evmChainId, solanaMainnet: solanaMainnet))
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Same command as Step 2. Expected: `TEST SUCCEEDED`, 12 tests.

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
never resolve to another chain's URL. Both network selectors are
parameters rather than reads of NetworkConfig.shared, so coverage is a
function of its arguments and cannot go stale behind a cached UI value.

Ankr and dRPC return nil for Solana devnet because their only hosts are
mainnet ones. Solana addresses are byte-identical across clusters, so
handing back a mainnet URL under a Devnet badge would broadcast a test
transfer against real funds."
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
        let previous = NodeProvider.allCases.map { ($0, config.apiKey(for: $0)) }
        defer { for (p, v) in previous { config.setAPIKeyForTesting(v, for: p) } }

        config.alchemyAPIKey = "alchemy-test"
        config.infuraAPIKey = "infura-test"
        config.ankrAPIKey = ""

        XCTAssertEqual(config.apiKey(for: .alchemy), "alchemy-test")
        XCTAssertEqual(config.apiKey(for: .infura), "infura-test")
        XCTAssertEqual(config.apiKey(for: .ankr), "")
    }
```

Restoring the previous values rather than blanking them keeps this test
from leaking state into whatever runs next — the same hazard that made
the Solana assertions in Task 1 cluster-dependent.

`setAPIKeyForTesting` does not exist yet; Task 10 introduces the real
`setAPIKey(_:for:)`. Until then, write the restore loop against the
stored properties directly:

```swift
    private func restoreKeys(_ saved: [(NodeProvider, String)], on config: NetworkConfig) {
        for (provider, value) in saved {
            switch provider {
            case .alchemy:  config.alchemyAPIKey = value
            case .infura:   config.infuraAPIKey = value
            case .ankr:     config.ankrAPIKey = value
            case .blockpi:  config.blockpiAPIKey = value
            case .drpc:     config.drpcAPIKey = value
            case .nodeReal: config.nodeRealAPIKey = value
            case .tenderly: config.tenderlyAPIKey = value
            case .oneRPC:   config.oneRPCAPIKey = value
            }
        }
    }
```

and call `defer { restoreKeys(previous, on: config) }`.

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

Same command. Expected: `TEST SUCCEEDED`, 13 tests.

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
        // url(for:) alone cannot tell "cleared" from "stored empty string".
        // Without these, an implementation that persisted "" would pass.
        XCTAssertFalse(ChainEndpointOverrides.shared.allChains().contains(.polygon))
        XCTAssertNil(ChainEndpointOverrides.shared.snapshot()[Chain.polygon.rawValue])
    }

    /// Whitespace-only input is the same user intent as an empty field.
    func test_settingWhitespaceOnly_clearsTheOverride() {
        ChainEndpointOverrides.shared.set("https://my-node.example", for: .polygon)
        ChainEndpointOverrides.shared.set("   \n ", for: .polygon)
        XCTAssertNil(ChainEndpointOverrides.shared.url(for: .polygon))
        XCTAssertFalse(ChainEndpointOverrides.shared.allChains().contains(.polygon))
        XCTAssertNil(ChainEndpointOverrides.shared.snapshot()[Chain.polygon.rawValue])
    }

    func test_setTrimsSurroundingWhitespace() {
        ChainEndpointOverrides.shared.set("  https://padded.example  ", for: .linea)
        XCTAssertEqual(ChainEndpointOverrides.shared.url(for: .linea), "https://padded.example")
    }

    func test_clear_removesOnlyThatChain() {
        ChainEndpointOverrides.shared.set("https://poly.example", for: .polygon)
        ChainEndpointOverrides.shared.set("https://base.example", for: .base)
        ChainEndpointOverrides.shared.clear(.polygon)
        XCTAssertNil(ChainEndpointOverrides.shared.url(for: .polygon))
        XCTAssertEqual(ChainEndpointOverrides.shared.url(for: .base), "https://base.example")
    }

    func test_allChains_reportsExactlyTheOverriddenChains() {
        ChainEndpointOverrides.shared.set("https://poly.example", for: .polygon)
        ChainEndpointOverrides.shared.set("https://sol.example", for: .solana)
        XCTAssertEqual(ChainEndpointOverrides.shared.allChains(), [.polygon, .solana])
    }

    /// Chains whose raw value contains spaces must survive the round trip
    /// through UserDefaults keys.
    func test_chainsWithSpacesInRawValue_roundTrip() {
        ChainEndpointOverrides.shared.set("https://bnb.example", for: .bnb)
        ChainEndpointOverrides.shared.reloadFromDisk()
        XCTAssertEqual(ChainEndpointOverrides.shared.url(for: .bnb), "https://bnb.example")
        XCTAssertEqual(ChainEndpointOverrides.shared.allChains(), [.bnb])
    }

    func test_overridesSurviveAReload() {
        ChainEndpointOverrides.shared.set("https://persisted.example", for: .scroll)
        ChainEndpointOverrides.shared.reloadFromDisk()
        XCTAssertEqual(ChainEndpointOverrides.shared.url(for: .scroll),
                       "https://persisted.example")
    }

    /// A key that no longer maps to a Chain (a renamed or removed case)
    /// must be ignored rather than crashing the settings list.
    func test_unknownStoredKeys_areIgnored() {
        UserDefaults.standard.set(["NotAChain": "https://ghost.example"],
                                  forKey: ChainEndpointOverrides.storageKey)
        ChainEndpointOverrides.shared.reloadFromDisk()
        XCTAssertTrue(ChainEndpointOverrides.shared.allChains().isEmpty)
    }

    /// clear() must reach disk. If it only mutated memory, a user's
    /// cleared override would come back on next launch — and setUp's
    /// removeAll() would stop isolating tests from each other.
    func test_clearIsPersisted() {
        ChainEndpointOverrides.shared.set("https://gone.example", for: .optimism)
        ChainEndpointOverrides.shared.clear(.optimism)
        ChainEndpointOverrides.shared.reloadFromDisk()
        XCTAssertNil(ChainEndpointOverrides.shared.url(for: .optimism))
    }

    func test_removeAllIsPersisted() {
        ChainEndpointOverrides.shared.set("https://a.example", for: .polygon)
        ChainEndpointOverrides.shared.set("https://b.example", for: .base)
        ChainEndpointOverrides.shared.removeAll()
        ChainEndpointOverrides.shared.reloadFromDisk()
        XCTAssertTrue(ChainEndpointOverrides.shared.allChains().isEmpty)
    }

    /// One unreadable value must not take the rest of the user's
    /// hand-entered node addresses with it. A wholesale
    /// `as? [String: String]` cast would return nil here and wipe all three.
    func test_oneCorruptValue_doesNotDiscardTheGoodOnes() {
        UserDefaults.standard.set([Chain.polygon.rawValue: "https://poly.example",
                                   Chain.base.rawValue: "https://base.example",
                                   Chain.solana.rawValue: 42],
                                  forKey: ChainEndpointOverrides.storageKey)
        ChainEndpointOverrides.shared.reloadFromDisk()
        XCTAssertEqual(ChainEndpointOverrides.shared.url(for: .polygon), "https://poly.example")
        XCTAssertEqual(ChainEndpointOverrides.shared.url(for: .base), "https://base.example")
        XCTAssertNil(ChainEndpointOverrides.shared.url(for: .solana))
    }

    /// An empty value on disk must be adopted as "no override", so the
    /// settings list and the resolver cannot disagree about whether a
    /// chain is overridden.
    func test_emptyValueOnDisk_isTreatedAsNoOverride() {
        UserDefaults.standard.set([Chain.linea.rawValue: "  "],
                                  forKey: ChainEndpointOverrides.storageKey)
        ChainEndpointOverrides.shared.reloadFromDisk()
        XCTAssertNil(ChainEndpointOverrides.shared.url(for: .linea))
        XCTAssertTrue(ChainEndpointOverrides.shared.allChains().isEmpty)
    }

    /// Concurrent reads during writes must not crash. Dictionary
    /// reallocates as it grows, which is the race the lock exists for.
    func test_concurrentReadsAndWrites_doNotCrash() {
        let done = expectation(description: "concurrent access")
        done.expectedFulfillmentCount = 2

        DispatchQueue.global().async {
            for i in 0..<500 {
                ChainEndpointOverrides.shared.set("https://w\(i).example", for: .polygon)
                ChainEndpointOverrides.shared.set("https://x\(i).example", for: .base)
            }
            done.fulfill()
        }
        DispatchQueue.global().async {
            for _ in 0..<500 {
                _ = ChainEndpointOverrides.shared.url(for: .polygon)
                _ = ChainEndpointOverrides.shared.allChains()
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
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
///
/// Reads happen off the main thread. `BlockchainService` is an `actor` and
/// calls `NetworkConfig.rpcURL(for:)` from its own executor, so once the
/// resolver consults this store an RPC thread will be reading the
/// dictionary while a settings screen mutates it on main. A `Dictionary`
/// reallocates its buffer as it grows, so that race can hand a reader
/// freed storage. Hence the lock. Marking the type `@MainActor` instead —
/// as `NodeHealthStore` is — is not available: it would make the
/// synchronous read from the actor-isolated RPC path impossible.
final class ChainEndpointOverrides: ObservableObject, @unchecked Sendable {
    static let shared = ChainEndpointOverrides()

    /// Not private: tests assert against the real stored payload, and a
    /// duplicated string literal there would silently start testing
    /// nothing the day this key is renamed.
    static let storageKey = "com.horcrux.rpc.chainOverrides"

    private let lock = NSLock()

    /// The authoritative store, guarded by `lock`. Keyed by
    /// `Chain.rawValue` rather than `Chain` so the dictionary can go
    /// straight into `UserDefaults`, which only accepts property-list types.
    private var storage: [String: String] = [:]

    /// Main-thread mirror, for SwiftUI only. Do not read this from the RPC
    /// path — it is updated asynchronously and may lag `storage`. Use
    /// `url(for:)` or `snapshot()`, which take the lock.
    @Published private(set) var overrides: [String: String] = [:]

    private init() {
        reloadFromDisk()
    }

    func url(for chain: Chain) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[chain.rawValue]
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
        mutate { $0[chain.rawValue] = trimmed }
    }

    func clear(_ chain: Chain) {
        mutate { $0.removeValue(forKey: chain.rawValue) }
    }

    func removeAll() {
        mutate { $0.removeAll() }
    }

    /// Chains that currently carry an override, for the settings list.
    /// Unknown keys are dropped: a stored value for a chain this build no
    /// longer has must not crash the list or resurrect a dead case.
    func allChains() -> Set<Chain> {
        Set(snapshot().keys.compactMap(Chain.init(rawValue:)))
    }

    /// A consistent copy for callers that need the whole map, such as
    /// config export.
    func snapshot() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func reloadFromDisk() {
        // Filtered per entry rather than cast wholesale. `as? [String: String]`
        // on the container is all-or-nothing: one non-String value — from a
        // newer build's payload after a downgrade, managed app config, or
        // plain plist corruption — would nil the whole dictionary and drop
        // every hand-entered self-hosted address the user has. The next
        // write would then make that loss permanent.
        let raw = UserDefaults.standard.dictionary(forKey: Self.storageKey) ?? [:]
        let cleaned = raw.compactMapValues { value -> String? in
            guard let text = value as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        lock.lock()
        storage = cleaned
        lock.unlock()
        publishMirror(cleaned)
    }

    /// Empty values are dropped at the disk boundary above, so `storage`
    /// never holds one. That keeps `url(for:)`, `allChains()` and
    /// `snapshot()` agreeing on what "has an override" means — a store
    /// whose whole semantics rest on "absent means follow the default"
    /// cannot afford two answers to that question.
    private func mutate(_ body: (inout [String: String]) -> Void) {
        lock.lock()
        body(&storage)
        let updated = storage
        lock.unlock()
        UserDefaults.standard.set(updated, forKey: Self.storageKey)
        publishMirror(updated)
    }

    private func publishMirror(_ value: [String: String]) {
        if Thread.isMainThread {
            overrides = value
        } else {
            DispatchQueue.main.async { [weak self] in self?.overrides = value }
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Same command. Expected: `TEST SUCCEEDED`, 16 tests.

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
- Modify: `ios/Horcrux/Core/NetworkConfig.swift` (add after `rpcURL(for:)`, which ends at line 278)
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

Same command. Expected: `TEST SUCCEEDED`, 19 tests.

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

`activeProvider` is only useful if it survives a relaunch, so each test
asserts the UserDefaults side effect rather than just reading the
property back — a `didSet` that forgets to write would pass a
property-only round-trip. `Keys` is `private`, so the on-disk string is
spelled out; that literal *is* the compatibility contract, and a test
that fails when someone renames the key is the point.

Save and restore the previous value rather than blanking it: `TEST_HOST`
is `Horcrux.app`, so `UserDefaults.standard` here is the real app domain.

```swift
    func test_activeProvider_persistsTheChoice() {
        let config = NetworkConfig.shared
        let original = config.activeProvider
        defer { config.activeProvider = original }

        config.activeProvider = .infura
        XCTAssertEqual(config.activeProvider, .infura)
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: "com.horcrux.rpc.activeProvider"),
            "infura",
            "not persisted, so the choice is lost on next launch")
    }

    func test_activeProvider_nilClearsTheStoredValue() {
        let config = NetworkConfig.shared
        let original = config.activeProvider
        defer { config.activeProvider = original }

        config.activeProvider = .alchemy
        config.activeProvider = nil

        XCTAssertNil(config.activeProvider)
        XCTAssertNil(
            UserDefaults.standard.string(forKey: "com.horcrux.rpc.activeProvider"),
            "going back to public must remove the key, not leave the old provider on disk")
    }

    func test_activeProvider_unknownStoredValue_readsAsPublic() {
        // A provider dropped in a later version must degrade to public
        // defaults, not crash and not resurrect as some other vendor.
        XCTAssertNil(NodeProvider(rawValue: "quicknode"))
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
            if let raw = activeProvider?.rawValue {
                UserDefaults.standard.set(raw, forKey: Keys.activeProvider)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.activeProvider)
            }
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

Expected: `TEST SUCCEEDED`, 22 tests.

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

    /// Ethereum is the one chain whose EVM network the user can change, so
    /// the resolver has to thread `evmChainId` through to the provider. If
    /// it ever hardcodes mainnet, a Sepolia user silently talks to mainnet.
    func test_resolve_forEthereum_followsTheNetworkToggleThroughTheProvider() {
        withCleanConfig { config in
            config.activeProvider = .alchemy
            config.alchemyAPIKey = "k"

            config.evmChainId = 1
            XCTAssertEqual(config.resolveRawURL(for: .ethereum),
                           "https://eth-mainnet.g.alchemy.com/v2/{KEY}")
            config.evmChainId = 11_155_111
            XCTAssertEqual(config.resolveRawURL(for: .ethereum),
                           "https://eth-sepolia.g.alchemy.com/v2/{KEY}")
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
           let template = provider.template(for: chain, evmChainId: evmChainId,
                                            solanaMainnet: !solDevnet) {
            return template
        }
        return publicDefault(for: chain)
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Expected: `TEST SUCCEEDED`, 29 tests.

**Post-review addendum (already applied in commit `de74061`).** Two
things the task above got wrong:

1. `solanaMainnet: !solDevnet` was unobservable to the whole suite — the
   parameter is dead for non-Solana chains, and the only test reaching
   `.solana` ran with no provider, so it short-circuited first. Two tests
   were added pinning the Alchemy mainnet/devnet templates and the
   Ankr-has-no-devnet-host fallthrough. Both were verified to fail when
   the argument is hardcoded to `true`.
2. `withCleanConfig` did not restore everything it perturbed.
   `alchemyAPIKey.didSet` runs `autoSwapPaidPublicDefaultsOnKeyChange`,
   which rewrites `ethereumRPC`/`solanaRPC` and is **edge-triggered** on
   empty↔non-empty — clear-then-set crosses two edges, restoring a
   non-empty key crosses none, so the swap never unwinds. The helper now
   also saves `solDevnet`, `ankrAPIKey`, `ethereumRPC` and `solanaRPC`,
   restoring the URLs *after* the key. `setUp` snapshots and restores the
   override store instead of blanking it.

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

### Task 7a: A cluster-agnostic table of everything we ship

**Files:**
- Modify: `ios/Horcrux/Core/NetworkConfig.swift` (`enum RPCFallbacks`, line 1363)
- Test: `ios/HorcruxTests/NodeSettingsMigrationTests.swift`

The migration has to answer one question per field: *did the user
customise this, or are they sitting on something we shipped?* That
question must **not** depend on which network the user has selected
right now.

If it does, a user on Solana devnet whose `solanaRPC` still holds the
mainnet default gets that mainnet URL frozen into a permanent override.
`detectMismatch` returns nil for Solana, so no probe catches it, and
Solana addresses are byte-identical across clusters — the next "test"
transfer spends real funds. The same hazard exists for Bitcoin testnet
and for Sepolia.

So the lookup unions **both** network selections. Being over-broad here
is safe: the worst case is that a user who deliberately typed a URL that
happens to equal a shipped endpoint for the *other* cluster keeps
receiving default updates instead of being pinned. Being under-broad is
not safe.

`RPCFallbacks.endpoints(for:config:)` currently branches on `config`
inline, so the union is unreachable from outside. Extract the three
config-dependent lists into per-cluster helpers first — the URLs must
stay in exactly one place, or the two tables will drift.

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

    // MARK: - Shipped-endpoint table

    /// The whole point: the answer must not move when the user flips a
    /// network toggle. If it does, a devnet user sitting on the mainnet
    /// default gets that mainnet URL frozen into an override, and nothing
    /// downstream can detect it.
    func test_shippedEndpoints_includeBothClusters() {
        let sol = RPCFallbacks.allShippedEndpoints(for: .solana)
        XCTAssertTrue(sol.contains(SolanaNetwork.mainnet.publicDefaultRPC))
        XCTAssertTrue(sol.contains(SolanaNetwork.devnet.publicDefaultRPC))

        let btc = RPCFallbacks.allShippedEndpoints(for: .bitcoin)
        XCTAssertTrue(btc.contains(BitcoinNetwork.mainnet.defaultAPI))
        XCTAssertTrue(btc.contains(BitcoinNetwork.testnet.defaultAPI))

        let eth = RPCFallbacks.allShippedEndpoints(for: .ethereum)
        XCTAssertTrue(eth.contains(EVMNetwork.mainnet.publicDefaultRPC))
        XCTAssertTrue(eth.contains(EVMNetwork.sepolia.publicDefaultRPC))
    }

    /// It must not depend on the live singleton at all.
    func test_shippedEndpoints_areIndependentOfTheLiveToggles() {
        let config = NetworkConfig.shared
        let devnet = config.solDevnet
        let testnet = config.btcTestnet
        defer { config.solDevnet = devnet; config.btcTestnet = testnet }

        config.solDevnet = false
        config.btcTestnet = false
        let solOff = RPCFallbacks.allShippedEndpoints(for: .solana)
        let btcOff = RPCFallbacks.allShippedEndpoints(for: .bitcoin)

        config.solDevnet = true
        config.btcTestnet = true
        XCTAssertEqual(RPCFallbacks.allShippedEndpoints(for: .solana), solOff)
        XCTAssertEqual(RPCFallbacks.allShippedEndpoints(for: .bitcoin), btcOff)
    }

    /// Every fallback we would actually dial must be in the table, or the
    /// migration would treat a shipped fallback as a hand-typed URL.
    func test_shippedEndpoints_supersetOfTheLiveFallbackList() {
        let config = NetworkConfig.shared
        for chain in Chain.allCases {
            let live = Set(RPCFallbacks.endpoints(for: chain, config: config))
            let all = RPCFallbacks.allShippedEndpoints(for: chain)
            XCTAssertTrue(live.isSubset(of: all),
                          "\(chain): \(live.subtracting(all)) missing from the shipped table")
        }
    }

    func test_shippedEndpoints_doNotLeakAcrossChains() {
        XCTAssertFalse(RPCFallbacks.allShippedEndpoints(for: .bitcoin)
            .contains(EVMNetwork.mainnet.publicDefaultRPC))
        XCTAssertFalse(RPCFallbacks.allShippedEndpoints(for: .tron)
            .contains(SolanaNetwork.mainnet.publicDefaultRPC))
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

Expected: `error: type 'RPCFallbacks' has no member 'allShippedEndpoints'`.

- [ ] **Step 3: Write the implementation**

In `ios/Horcrux/Core/NetworkConfig.swift`, replace the body of
`RPCFallbacks.endpoints(for:config:)` so the three config-dependent
lists move into named helpers, then add the union accessor. The literal
URLs are unchanged — they are only relocated, so nothing about the
runtime fallback order moves.

```swift
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
            return bitcoinEndpoints(testnet: config.btcTestnet)
        case .litecoin:
            return litecoinEndpoints
        case .solana:
            return solanaEndpoints(devnet: config.solDevnet)
        case .tron:
            return tronEndpoints
        default:
            return []
        }
    }

    private static func bitcoinEndpoints(testnet: Bool) -> [String] {
        testnet
            ? ["https://blockstream.info/testnet/api", "https://mempool.space/testnet/api"]
            : ["https://blockstream.info/api", "https://mempool.space/api"]
    }

    private static let litecoinEndpoints = [
        "https://litecoinspace.org/api"
    ]

    private static func solanaEndpoints(devnet: Bool) -> [String] {
        devnet
            ? ["https://api.devnet.solana.com"]
            : [
                "https://api.mainnet-beta.solana.com",
                // Canonical PublicNode hostname — matches
                // `SolanaNetwork.mainnet.publicDefaultRPC` so it dedupes
                // away for default installs instead of listing the same
                // operator twice under an alias and looking like
                // redundancy it isn't.
                "https://solana-rpc.publicnode.com"
            ]
    }

    private static let tronEndpoints = [
        "https://api.trongrid.io",
        "https://api.tronstack.io",
        "https://api.shasta.trongrid.io",
        "https://nile.trongrid.io"
    ]

    /// Every endpoint this app has ever handed out for `chain` as a
    /// default or a fallback, across **both** network selections.
    ///
    /// Deliberately cluster-agnostic, and deliberately not a function of
    /// `NetworkConfig`. The migration uses this to tell a hand-typed URL
    /// from one of ours, and that judgement must not change when the user
    /// flips a network toggle: a devnet user still holding the mainnet
    /// Solana default would otherwise have it frozen into a permanent
    /// mainnet override. `detectMismatch` returns nil for Solana, so
    /// nothing downstream would ever catch it, and Solana addresses are
    /// byte-identical across clusters.
    static func allShippedEndpoints(for chain: Chain) -> Set<String> {
        switch chain {
        case .ethereum:
            var set = Set(endpoints(forEVMNetwork: .mainnet))
            set.formUnion(endpoints(forEVMNetwork: .sepolia))
            set.formUnion([EVMNetwork.mainnet, .sepolia]
                .flatMap { [$0.publicDefaultRPC, $0.defaultRPC] })
            return set
        case .bitcoin:
            var set = Set(bitcoinEndpoints(testnet: false))
            set.formUnion(bitcoinEndpoints(testnet: true))
            set.formUnion([BitcoinNetwork.mainnet.defaultAPI,
                           BitcoinNetwork.testnet.defaultAPI])
            return set
        case .litecoin:
            return Set(litecoinEndpoints)
        case .solana:
            var set = Set(solanaEndpoints(devnet: false))
            set.formUnion(solanaEndpoints(devnet: true))
            set.formUnion([SolanaNetwork.mainnet, .devnet]
                .flatMap { [$0.publicDefaultRPC, $0.defaultRPC] })
            return set
        case .tron:
            return Set(tronEndpoints)
        default:
            guard let net = chain.defaultEVMNetwork else { return [] }
            var set = Set(endpoints(forEVMNetwork: net))
            set.formUnion([net.publicDefaultRPC, net.defaultRPC])
            return set
        }
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Same command. Expected: `TEST SUCCEEDED`, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add ios/Horcrux/Core/NetworkConfig.swift ios/HorcruxTests/NodeSettingsMigrationTests.swift \
        ios/Horcrux.xcodeproj/project.pbxproj
git commit -m "refactor(ios): expose a cluster-agnostic shipped-endpoint table

The migration needs to tell a hand-typed URL from one we shipped, and
that judgement must not depend on the user's current network toggle.
A devnet user still holding the mainnet Solana default would otherwise
have it frozen into a permanent mainnet override — detectMismatch
returns nil for Solana, so nothing downstream would catch it, and
Solana addresses are byte-identical across clusters.

Fallback URLs are relocated into per-cluster helpers, not changed, so
the runtime fallback order is untouched."
```

---

### Task 7b: Migrate the legacy five-field model

**Files:**
- Create: `ios/Horcrux/Core/NodeSettingsMigration.swift`
- Test: `ios/HorcruxTests/NodeSettingsMigrationTests.swift`

The rule most likely to be got wrong: **a stored URL equal to something
we ship must migrate to nothing.** Writing it into an override would
freeze that user on today's default forever, so the dead-endpoint purges
would never reach them. `NetworkConfig.migrateDeadEndpoints` (line 705)
exists precisely because stored URLs do get frozen, and it currently
lists seven dead URLs.

`plan` is a **pure function of its arguments**. It must not read
`NetworkConfig.shared`, not even indirectly — that is what makes every
rule table-testable, and it is the same defect review caught in Task 1.

- [ ] **Step 1: Write the failing test**

Append to `NodeSettingsMigrationTests`:

```swift
    // MARK: - plan()

    private func plan(ethereum: String = EVMNetwork.mainnet.publicDefaultRPC,
                      bitcoin: String = "https://mempool.space/api",
                      litecoin: String = "https://litecoinspace.org/api",
                      solana: String = "https://solana-rpc.publicnode.com",
                      tron: String = "https://api.trongrid.io",
                      evmChainId: UInt64 = 1) -> NodeSettingsMigration.Plan {
        NodeSettingsMigration.plan(
            ethereumRPC: ethereum, bitcoinAPI: bitcoin, litecoinAPI: litecoin,
            solanaRPC: solana, tronAPI: tron, evmChainId: evmChainId
        )
    }

    /// A value equal to something we ship must produce no override, or the
    /// user is frozen on it and future default fixes never arrive.
    func test_shippedValues_produceNoOverride() {
        let result = plan()
        XCTAssertTrue(result.overrides.isEmpty, "got \(result.overrides)")
        XCTAssertNil(result.activeProvider)
        XCTAssertEqual(result.evmChainId, 1)
    }

    /// The defect this replaces: plan() used to read solDevnet from the
    /// singleton, so a devnet user holding the mainnet Solana default
    /// would have had it written into a permanent mainnet override.
    func test_planIsIndependentOfTheLiveToggles() {
        let config = NetworkConfig.shared
        let devnet = config.solDevnet
        let testnet = config.btcTestnet
        defer { config.solDevnet = devnet; config.btcTestnet = testnet }

        config.solDevnet = false
        config.btcTestnet = false
        let mainnetSide = plan()

        config.solDevnet = true
        config.btcTestnet = true
        XCTAssertEqual(plan(), mainnetSide,
                       "plan() must be a pure function of its arguments")
    }

    func test_devnetDefault_alsoProducesNoOverride() {
        let result = plan(solana: SolanaNetwork.devnet.publicDefaultRPC)
        XCTAssertNil(result.overrides[.solana],
                     "the devnet default is ours too; freezing it would pin the cluster")
    }

    func test_providerTemplate_becomesTheActiveProvider() {
        let result = plan(ethereum: "https://eth-mainnet.g.alchemy.com/v2/{KEY}")
        XCTAssertEqual(result.activeProvider, .alchemy)
        XCTAssertTrue(result.overrides.isEmpty,
                      "a recognised template is a provider, not an override")
    }

    func test_customURL_becomesAnOverrideForItsChain() {
        let result = plan(ethereum: "https://my-own-node.example/eth")
        XCTAssertNil(result.activeProvider)
        XCTAssertEqual(result.overrides[.ethereum], "https://my-own-node.example/eth")
        XCTAssertEqual(result.overrides.count, 1)
    }

    /// The Ethereum slot was being used as Polygon. The URL belongs to
    /// the first-class Polygon chain, and the toggle returns to mainnet.
    func test_evmChainIdPointingAtPolygon_movesTheURLToPolygon() {
        let result = plan(ethereum: "https://my-own-node.example/polygon",
                          evmChainId: 137)
        XCTAssertEqual(result.overrides[.polygon], "https://my-own-node.example/polygon")
        XCTAssertNil(result.overrides[.ethereum])
        XCTAssertEqual(result.evmChainId, 1)
    }

    /// Same relocation, but the value was a default, so nothing is stored.
    func test_evmChainIdPointingAtPolygon_withDefaultURL_storesNothing() {
        let result = plan(ethereum: EVMNetwork.polygon.publicDefaultRPC, evmChainId: 137)
        XCTAssertTrue(result.overrides.isEmpty, "got \(result.overrides)")
        XCTAssertEqual(result.evmChainId, 1)
    }

    func test_sepoliaToggle_isPreserved() {
        let result = plan(ethereum: EVMNetwork.sepolia.publicDefaultRPC,
                          evmChainId: 11_155_111)
        XCTAssertEqual(result.evmChainId, 11_155_111,
                       "Sepolia is a valid Ethereum testnet toggle, not a second chain")
        XCTAssertTrue(result.overrides.isEmpty, "got \(result.overrides)")
    }

    func test_customNonEVMURLs_becomeTheirOwnOverrides() {
        let result = plan(bitcoin: "https://my-esplora.example/api",
                          solana: "https://my-solana.example",
                          tron: "https://my-tron.example")
        XCTAssertEqual(result.overrides[.bitcoin], "https://my-esplora.example/api")
        XCTAssertEqual(result.overrides[.solana], "https://my-solana.example")
        XCTAssertEqual(result.overrides[.tron], "https://my-tron.example")
        XCTAssertNil(result.overrides[.litecoin], "litecoin was on its default")
    }

    /// Two different vendors across the two slots. Only one can become the
    /// account provider, so the other must survive as an override rather
    /// than be silently dropped back to a public endpoint. The template
    /// keeps its `{KEY}`; substituteAPIKey resolves it by hostname.
    func test_aSecondVendorOnSolana_survivesAsAnOverride() {
        let result = plan(ethereum: "https://mainnet.infura.io/v3/{KEY}",
                          solana: "https://solana-mainnet.g.alchemy.com/v2/{KEY}")
        XCTAssertEqual(result.activeProvider, .infura)
        XCTAssertEqual(result.overrides[.solana],
                       "https://solana-mainnet.g.alchemy.com/v2/{KEY}")
    }

    /// One vendor across both slots is the common case and must not
    /// produce a redundant override.
    func test_sameVendorOnBothSlots_producesNoOverride() {
        let result = plan(ethereum: "https://eth-mainnet.g.alchemy.com/v2/{KEY}",
                          solana: "https://solana-mainnet.g.alchemy.com/v2/{KEY}")
        XCTAssertEqual(result.activeProvider, .alchemy)
        XCTAssertTrue(result.overrides.isEmpty, "got \(result.overrides)")
    }

    func test_emptyFields_produceNoOverrides() {
        let result = plan(ethereum: "", bitcoin: "", litecoin: "", solana: "", tron: "")
        XCTAssertTrue(result.overrides.isEmpty, "got \(result.overrides)")
        XCTAssertNil(result.activeProvider)
    }

    // MARK: - runIfNeeded()

    /// The version gate is the whole reason runIfNeeded exists. Without
    /// it, every launch would re-derive the plan from the legacy fields —
    /// which are never cleared — and resurrect an override the user has
    /// since deleted.
    func test_runIfNeeded_doesNotResurrectAnOverrideTheUserDeleted() {
        let suite = "com.horcrux.tests.migration"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let config = NetworkConfig.shared
        let originalETH = config.ethereumRPC
        let originalChainId = config.evmChainId
        let originalProvider = config.activeProvider
        defer {
            config.ethereumRPC = originalETH
            config.evmChainId = originalChainId
            config.activeProvider = originalProvider
            ChainEndpointOverrides.shared.removeAll()
        }

        config.evmChainId = 1
        config.ethereumRPC = "https://my-own-node.example/eth"

        NodeSettingsMigration.runIfNeeded(config: config, defaults: defaults)
        XCTAssertEqual(ChainEndpointOverrides.shared.url(for: .ethereum),
                       "https://my-own-node.example/eth")

        // The user changes their mind and deletes it.
        ChainEndpointOverrides.shared.clear(.ethereum)

        NodeSettingsMigration.runIfNeeded(config: config, defaults: defaults)
        XCTAssertNil(ChainEndpointOverrides.shared.url(for: .ethereum),
                     "the version gate did not hold; migration ran a second time")
    }

    func test_runIfNeeded_recordsTheVersionEvenWhenThereIsNothingToMigrate() {
        let suite = "com.horcrux.tests.migration.noop"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let config = NetworkConfig.shared
        let originalProvider = config.activeProvider
        let originalChainId = config.evmChainId
        defer {
            config.activeProvider = originalProvider
            config.evmChainId = originalChainId
        }

        NodeSettingsMigration.runIfNeeded(config: config, defaults: defaults)
        XCTAssertGreaterThan(
            defaults.integer(forKey: "com.horcrux.rpc.settingsMigrationVersion"), 0,
            "a no-op migration must still record its version or it reruns forever")
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Same command as Task 7a.
Expected: `error: cannot find 'NodeSettingsMigration' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ios/Horcrux/Core/NodeSettingsMigration.swift`:

```swift
import Foundation

/// One-time migration from the legacy five-URL-field model to
/// provider + per-chain overrides.
///
/// `plan` is a pure function of its arguments — it reads no singleton and
/// no UserDefaults — so every rule below is table-testable. `apply` and
/// `runIfNeeded` do the writes.
enum NodeSettingsMigration {

    struct Plan: Equatable {
        var activeProvider: NodeProvider?
        var overrides: [Chain: String]
        var evmChainId: UInt64
    }

    static let versionKey = "com.horcrux.rpc.settingsMigrationVersion"
    static let currentVersion = 1

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
        } else if !isShipped(ethereumRPC, for: evmTargetChain) {
            overrides[evmTargetChain] = ethereumRPC
        }

        if let solProvider = detectProvider(in: solanaRPC) {
            if provider == nil {
                provider = solProvider
            } else if solProvider != provider {
                // Only one vendor can be the account provider. Dropping the
                // other would silently downgrade that chain to a public
                // endpoint, so it survives as an override. The `{KEY}` stays
                // in it; substituteAPIKey resolves it by hostname.
                overrides[.solana] = solanaRPC
            }
        } else if !isShipped(solanaRPC, for: .solana) {
            overrides[.solana] = solanaRPC
        }

        for (value, chain) in [(bitcoinAPI, Chain.bitcoin),
                               (litecoinAPI, Chain.litecoin),
                               (tronAPI, Chain.tron)] {
            if !isShipped(value, for: chain) {
                overrides[chain] = value
            }
        }

        return Plan(activeProvider: provider,
                    overrides: overrides,
                    evmChainId: resolvedChainId)
    }

    /// True when `value` is an endpoint we ship for `chain`, in which case
    /// it must NOT become an override — the user stays on the default and
    /// keeps receiving default changes.
    ///
    /// The lookup spans both network selections on purpose; see
    /// `RPCFallbacks.allShippedEndpoints(for:)`.
    private static func isShipped(_ value: String, for chain: Chain) -> Bool {
        if value.isEmpty { return true }
        return RPCFallbacks.allShippedEndpoints(for: chain).contains(value)
    }

    private static func detectProvider(in url: String) -> NodeProvider? {
        guard url.contains("{KEY}") else { return nil }
        return NodeProvider.allCases.first { templates(of: $0).contains(url) }
    }

    /// Every `{KEY}` template `provider` can produce, across every chain
    /// and both Solana clusters. Pure: no singleton reads.
    private static func templates(of provider: NodeProvider) -> Set<String> {
        var out: Set<String> = []
        let mainnetId = EVMNetwork.mainnet.rawValue

        for net in EVMNetwork.allCases {
            if let t = provider.template(for: .ethereum, evmChainId: net.rawValue,
                                         solanaMainnet: true) {
                out.insert(t)
            }
        }
        for chain in Chain.allCases where chain.isEVM && chain != .ethereum {
            if let t = provider.template(for: chain, evmChainId: mainnetId,
                                         solanaMainnet: true) {
                out.insert(t)
            }
        }
        for solanaMainnet in [true, false] {
            if let t = provider.template(for: .solana, evmChainId: mainnetId,
                                         solanaMainnet: solanaMainnet) {
                out.insert(t)
            }
        }
        return out
    }

    static func apply(_ plan: Plan, to config: NetworkConfig) {
        config.activeProvider = plan.activeProvider
        config.evmChainId = plan.evmChainId
        for (chain, url) in plan.overrides {
            ChainEndpointOverrides.shared.set(url, for: chain)
        }
    }

    /// Entry point called once at launch. The version gate matters: the
    /// legacy fields are never cleared, so without it every launch would
    /// re-derive the same plan and resurrect overrides the user deleted.
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

Note `versionKey` / `currentVersion` are internal, not private, so Task 8
and the tests can reference them. Do **not** try to harmonise
`currentVersion` here with `RPCConfigSnapshot.currentVersion` in
`SettingsView.swift` — they version unrelated things and are unrelated
types.

- [ ] **Step 4: Run the test to verify it passes**

Same command. Expected: `TEST SUCCEEDED`, 18 tests.

- [ ] **Step 5: Commit**

```bash
git add ios/Horcrux/Core/NodeSettingsMigration.swift \
        ios/HorcruxTests/NodeSettingsMigrationTests.swift \
        ios/Horcrux.xcodeproj/project.pbxproj
git commit -m "feat(ios): migrate legacy node settings to provider + overrides

plan() is a pure function of its arguments — no singleton reads — so
every rule is table-testable and the result cannot shift under the
user's current network toggle.

The load-bearing rule: a stored URL equal to something we ship migrates
to nothing. Writing it into an override would freeze that user on
today's default and no future endpoint fix would reach them.
migrateDeadEndpoints exists because stored URLs do get frozen and
currently lists seven dead URLs.

A non-Ethereum evmChainId means the Ethereum slot was being used as
another chain; the URL moves to that first-class chain and the toggle
returns to mainnet.

When the two slots name different vendors, only one can be the account
provider; the other survives as an override rather than being silently
downgraded to a public endpoint."
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
- Create: `ios/Horcrux/Features/Settings/NodeSettings/ProviderCoverageSummary.swift`

- [ ] **Step 1: Write the view**

Create `ios/Horcrux/Features/Settings/NodeSettings/NodeProviderSection.swift`.
Coverage logic lives in `ProviderCoverageSummary` (see Step 1b). The view
observes `ChainEndpointOverrides.shared` so the coverage line updates live when
overrides change; all user-facing strings route through `L10n.NodeSettings.*`.

```swift
import SwiftUI

struct NodeProviderSection: View {
    @ObservedObject private var config = NetworkConfig.shared
    @ObservedObject private var chainOverrides = ChainEndpointOverrides.shared

    var body: some View {
        Section(L10n.NodeSettings.providerSection) {
            Picker(L10n.NodeSettings.providerPicker, selection: providerSelection) {
                Text(L10n.NodeSettings.providerPublicDefaults).tag(nil as NodeProvider?)
                ForEach(NodeProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider as NodeProvider?)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("nodeSettings_providerPicker")

            if let provider = config.activeProvider {
                SecureField(L10n.NodeSettings.providerKeyLabel(provider.displayName),
                            text: keyBinding(for: provider))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("nodeSettings_providerKeyField")

                Text(coverageSummary(for: provider).formattedCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("nodeSettings_coverageLine")
            } else {
                Text(L10n.NodeSettings.providerPublicCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("nodeSettings_coverageLine")
            }
        }
    }

    private var providerSelection: Binding<NodeProvider?> { ... }
    private func keyBinding(for provider: NodeProvider) -> Binding<String> { ... }
    private func coverageSummary(for provider: NodeProvider) -> ProviderCoverageSummary { ... }
}
```

Create `ios/Horcrux/Features/Settings/NodeSettings/ProviderCoverageSummary.swift`.
The coverage summary is extracted to a pure, testable struct rather than a
private `View` method. It partitions chains into three disjoint groups:
`overridden` (user endpoint), `providerCovered` (provider serves + key set +
no override), and `publicDefault` (the gap). Overrides are taken as a
parameter so the struct stays pure; the view passes
`ChainEndpointOverrides.shared.overrides`. This prevents two bugs from the
original `coverageText`: (1) a migrated Bitcoin override would be falsely
reported as "stays on public endpoints", and (2) a private-chain override
shadowing a provider would be reported as provider-covered.

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
           provider.template(for: chain, evmChainId: evmChainId,
                            solanaMainnet: !solDevnet) != nil {
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
        self.chainOverrides = ChainEndpointOverrides.shared.snapshot()
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

# Node Settings: Provider-First Configuration

**Date:** 2026-07-29
**Status:** Implemented in a15aebe..cbc07db (branch
`feat/provider-first-node-settings`). Tasks 1–15 of
`../plans/2026-07-29-node-settings-provider-first.md` are complete.
**Related:** `2026-07-29-node-configuration-design.md` (endpoint reliability;
Part 1 shipped). That document fixed *which* endpoints we ship. This one
fixes *how a user configures them*.

## Problem

The question raised was narrow: is per-chain node configuration right, or
would a single entry point be better?

Neither describes what the app currently does. The existing design is a
hybrid of both, applied inconsistently, and the inconsistency hides a
larger gap.

### 14 chains are user-facing; 5 are configurable

`Chain.allCases` (AppState.swift:646) has fourteen entries and drives
wallet creation, the address book, custom tokens, and the node-health
summary. Only five of them have a configurable endpoint:

| | Chains |
|---|---|
| Configurable | Ethereum, Bitcoin, Litecoin, Solana, Tron |
| **Not configurable at all** | BNB Chain, Polygon, Arbitrum, Base, Avalanche, Optimism, zkSync Era, Linea, Scroll |

`NetworkConfig.setFieldValue` and `fieldValue` both `default: break` for
those nine (NetworkConfig.swift:313–340). `rpcURL(for:)` returns a
hardcoded default, with a comment saying as much: "New EVM chains use
hardcoded defaults for now; no per-chain override field yet."

These are not dormant chains. `BlockchainService.balance` serves every
`isEVM` chain, so a user can hold assets on Base and watch its endpoint
fail with no control available. The settings screen compounds this by
reporting "*n* of 14 chains healthy" (NetworkConfig.swift:1684) — it
shows the user nine problems it gives them no way to act on.

### One EVM URL field serves eleven networks

The EVM section offers a picker over all eleven `EVMNetwork` cases but
binds a single stored string, `ethereumRPC` (SettingsView.swift:1183+).
`autoSwapEthereumRPCIfDefault` (NetworkConfig.swift:543) rewrites that
string on network change *only when it recognises the current value* as a
known public default or an Alchemy template. A custom URL is deliberately
left alone — correct as far as it goes, but the consequence is that a
user who enters their own Polygon node and then switches the picker to
Base is now pointing a Polygon URL at Base. The app can hold exactly one
custom EVM URL, and its meaning silently depends on a picker elsewhere.

`evmChainId` also carries two unrelated meanings: "which testnet is
Ethereum on" and "which chain does the Ethereum slot represent". The
second collides with the first-class `Chain.polygon`, `.base` and so on.
There are two different Polygons in the app.

### The unit of configuration is wrong

URLs are modelled per chain — five fields. Keys are modelled per provider
— ten RPC provider entries in the Keychain (plus an Etherscan key, which
is a block explorer rather than an RPC endpoint), each valid across many
chains. The user's actual asset is a provider account. Asking them to
think per chain means asking them to apply one key ten times, which the
UI does not even let them do for nine of the ten.

## Provider coverage

The design rests on "one key covers many chains", so that claim is worth
stating precisely rather than assuming. Measured against
`RPCProviderTemplate` (NetworkConfig.swift:1005–1207); eleven
`EVMNetwork` cases, of which ten map to first-class chains and one
(Sepolia) is Ethereum's testnet:

| Provider | EVM | Not covered | Solana | Key scope |
|---|---|---|---|---|
| Ankr | 11/11 | — | yes | account |
| dRPC | 11/11 | — | yes | account |
| 1RPC | 11/11 | — | mainnet only | account |
| Alchemy | 10/11 | BNB | yes | account |
| Infura | 10/11 | Scroll | yes | account |
| BlockPI | 10/11 | Sepolia | no | account |
| Tenderly | 9/11 | zkSync Era, Scroll | no | account |
| NodeReal | 7/11 | Sepolia, zkSync Era, Linea, Scroll | no | account |
| GetBlock | URL is chain-agnostic | — | yes | **per chain** |
| Helius | — | — | Solana only | account |

Two constraints fall out of this table, and both shape the design:

1. **No provider covers all fourteen chains.** Bitcoin, Litecoin and Tron
   sit outside every EVM template. A provider-first screen that implies
   otherwise would be lying.
2. **GetBlock is not account-scoped.** Its URL shape
   (`https://go.getblock.io/{KEY}/`) is identical for every chain because
   the token itself is bound to one chain in their dashboard. One
   GetBlock token does not cover many chains.

## Design

### Data model

```
activeProvider:  Provider?            // nil = public defaults
providerKeys:    [Provider: String]   // Keychain — already exists
chainOverrides:  [Chain: String]      // new, sparse
```

`rpcURL(for:)` resolves in three steps:

1. `chainOverrides[chain]`, if present.
2. Otherwise `activeProvider`'s template for that chain, with the key
   substituted.
3. Otherwise the chain's public default.

Everything else follows from this. The nine unconfigurable chains become
configurable because templates and public defaults already exist for all
of them. The cross-network leak disappears because an override is keyed
by `Chain` rather than held in one shared field. The unit of
configuration matches the unit the user actually owns.

`evmChainId` narrows to its remaining honest meaning: Ethereum's
mainnet/Sepolia toggle. Polygon, Base and the rest are reached as
first-class chains, so the second Polygon goes away.

### UI

Three sections replace the current five.

**1. Provider.** A picker (Public defaults, then the account-scoped
multi-chain providers), one key field bound to the selected provider's
Keychain entry, and a coverage line stating exactly what the selection
does and does not cover: "Alchemy covers 10 of 11 EVM networks and
Solana. BNB Chain, Bitcoin, Litecoin and Tron stay on public endpoints."

The coverage line is not decoration. Without it the failure mode is a
user who binds Alchemy, believes every chain is on their own key, and
never learns that BNB is not — the silent gap is worse than no key at
all, because it removes the incentive to look.

**2. Chains.** One list of all fourteen, each row showing the chain, a
source badge (`Provider` / `Custom` / `Public`) and a health indicator.
Tapping a row opens the effective URL, a custom-URL field, the endpoint
switcher, WSS where applicable, and a per-chain reset.

The source badge is the central affordance. "Where does this chain
actually go?" is unanswerable today for nine chains and ambiguous for
Ethereum. A uniform list also means new chains appear automatically
instead of waiting for someone to hand-write a section.

**3. Advanced.** Presets, import/export and cooldown state, unchanged.

**GetBlock and Helius are excluded from the provider picker** and appear
only as per-chain overrides. GetBlock's token is chain-scoped and Helius
serves one chain; either in the top-level picker would falsify the
promise the picker makes. Restricting it to account-scoped multi-chain
providers keeps that promise true by construction.

**The provider does not replace the fallback tables.** Fallbacks remain
per chain, public, and operator-independent. A single provider is a
single point of failure, which is the objection raised against mandatory
paid providers in the companion document; it applies equally here. The
provider is the preferred endpoint, not the only one.

The cost of this design is one extra tap to reach a specific chain's
settings. What it buys is uniform behaviour across all fourteen chains
and nine chains moving from unconfigurable to configurable.

### Migration

Run once, versioned.

| Existing state | Action |
|---|---|
| URL matches a provider template | Set `activeProvider` |
| URL is a custom value | `chainOverrides[chain] = url` |
| URL equals the current public default | **Store nothing** |
| `evmChainId` is a non-Ethereum network | Move the URL to `chainOverrides[<that chain>]`, reset `evmChainId` to 1 |
| `evmChainId` is Sepolia | Keep — it is a valid testnet toggle |

`detectActiveEVMProvider()` already implements template matching in the
settings view (SettingsView.swift:972); move it into the model rather
than writing a second copy.

The third row is the one that is easy to get wrong. Migrating every
current URL into an override would freeze existing users on today's
defaults, so the dead-endpoint purge that just shipped would never reach
them. This is not hypothetical: `migrateDeadEndpoints`
(NetworkConfig.swift:644) exists precisely because stored URLs do get
frozen, and it currently lists seven dead URLs that users would
otherwise still be pointed at. A value equal to the default should stay
following the default.

**Import/export.** `RPCConfigSnapshot` (SettingsView.swift:2118) has no
version field. Add one, and have `decode` reject a higher version
explicitly. Without that, an older build importing a newer export drops
`chainOverrides` silently through Codable's unknown-key behaviour and
reports success, leaving the user with a configuration that is wrong in a
way nothing told them about.

### Error handling

- **Provider selected, key empty.** Resolution falls through to the
  public default, which `substituteAPIKey` already does. The coverage
  line must say so: "No key set — using public endpoints."
- **Provider does not cover a chain.** Public default; the row badge
  reads `Public` and the coverage line names the chain.
- **Override unreachable.** Handled by the existing health and cooldown
  system. The override is not auto-removed: an explicit user choice is
  honoured, the same principle that pins the user's primary first in
  `resolvedAttempts`.
- **Chain-ID mismatch.** `NodeHealthStore` already detects this, but
  there is no per-chain surface for it. Report it in the chain detail
  specifically — "this endpoint reports chain 137, expected 8453" —
  because the generic "unhealthy" gives the user nothing to act on, and
  this particular error is almost always a paste error they can fix.

### Testing

- **Resolution order.** Override beats provider beats public, across all
  fourteen chains against representative providers.
- **Coverage.** For each provider, the covered set matches the template
  table, and every uncovered chain resolves to that chain's public
  default — not an empty string, and not another chain's URL.
- **Migration.** Table-driven over `(field value, evmChainId)` →
  `(activeProvider, chainOverrides, evmChainId)`. Must include the case
  asserting that a value equal to the public default produces **no**
  override.
- **The `evmChainId`-was-Polygon case** gets its own test: it is the only
  rule that moves data between chains.
- **Key substitution.** Extend the existing keyless-fallback guard so an
  override without `{KEY}` is never rewritten with a stored key.

Tests stay offline. Endpoint liveness belongs to the scheduled probe, as
established in the companion document.

## Open questions

- Should selecting a provider offer to verify the key immediately with a
  single `eth_chainId` call? It turns a silent misconfiguration into an
  instant error, but it is the only live network call in the settings
  flow and needs a considered timeout and failure message.
- Should `chainOverrides` be exported by default? It may contain a
  private or self-hosted node address, which is closer to personal data
  than the rest of the snapshot.

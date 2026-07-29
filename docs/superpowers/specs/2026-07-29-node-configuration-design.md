# Node Configuration: Free-Tier Reliability and the Provider-Key Question

**Date:** 2026-07-29
**Status:** Proposed — Part 1 implemented, Part 2 awaiting product decision

## Problem

Two things were raised, and they need separating because only the first
is a fact:

1. Node settings "aren't good enough".
2. "Free node availability is very low — should we ship no free defaults
   at all, require users to configure a paid commercial provider, and
   tell them during onboarding that the app won't work until they do?"

The second is a proposal built on a premise. Before acting on it the
premise was measured, because the cure it prescribes — a wallet that
shows nothing until you register with a third party — is one of the
most expensive changes a consumer wallet can make to itself.

## Measured evidence

Every free endpoint reachable from `RPCFallbacks` and
`NetworkConfig.Defaults` was probed on 2026-07-29 from a residential
connection: `eth_blockNumber` for EVM, `getSlot` for Solana, tip-height
GET for Esplora, `getnowblock` for Tron. 8s timeout, response body
validated (not just HTTP 200).

**35 endpoints probed. 29 healthy, 6 dead.**

Dead:

| Endpoint | Chains affected | Failure |
|---|---|---|
| `eth.llamarpc.com` | Ethereum | HTTP 521 (Cloudflare: origin unreachable) |
| `polygon.llamarpc.com` | Polygon | connection failed |
| `arbitrum.llamarpc.com` | Arbitrum | connection failed |
| `base.llamarpc.com` | Base | HTTP 521 |
| `optimism.llamarpc.com` | Optimism | connection failed |
| `polygon-rpc.com` | Polygon | HTTP 401 `API key disabled, reason: tenant disabled` |

**Five of the six dead endpoints are one provider: LlamaRPC.** It is not
degraded, it is gone.

Healthy, with round-trip latency:

| Provider family | Result |
|---|---|
| `*.publicnode.com` (ETH, Polygon, Arbitrum, Base, Optimism, BNB, Avalanche, Solana) | all OK, 160–674 ms |
| Official chain RPCs (`arb1.arbitrum.io`, `mainnet.base.org`, `mainnet.optimism.io`, `api.avax.network`, `mainnet.era.zksync.io`, `rpc.linea.build`, `rpc.scroll.io`, `bsc-dataseed.bnbchain.org`) | all OK, 133–365 ms |
| `*.drpc.org` (zkSync, Linea, Scroll) | all OK, 107–136 ms |
| Esplora (`blockstream.info`, `mempool.space`, `litecoinspace.org`) | all OK, 99–329 ms |
| Solana (`api.mainnet-beta.solana.com`, `solana.publicnode.com`) | all OK, 160–278 ms |
| Tron (`api.trongrid.io`, `api.tronstack.io`) | all OK, 470–542 ms |

Every **default** endpoint a new install actually starts on is healthy.
`EVMNetwork.publicDefaultRPC` (NetworkConfig.swift:66–80) points at
publicnode and official chain RPCs — never at LlamaRPC.

Not probed: testnet-only entries (Sepolia fallbacks, Solana devnet,
Tron Shasta/Nile) and the Bitcoin testnet Esplora hosts. They matter
less and should be swept by the automation in Part 1.4.

## Diagnosis

The reported symptom is real. The stated cause is not. Three separate
defects compound into "free nodes are unreliable":

### 1. A dead provider still occupies five fallback slots

`RPCFallbacks.endpoints(forEVMNetwork:)` (NetworkConfig.swift:1332–1400)
lists LlamaRPC as the **first fallback** for Ethereum, and among the
first for Polygon, Arbitrum, Base and Optimism. So the moment the
primary blips, the very next thing tried is a corpse — either a fast
521 or a full connect timeout. Recovery, the thing fallbacks exist for,
is what feels broken.

The table has rotted silently. The code already carries a comment
recording that Ankr's keyless endpoints started returning 401 and were
removed; the same thing then happened to LlamaRPC and nobody noticed,
because nothing watches.

### 2. The hottest read path ignores the health system entirely

`BlockchainService.balance(for:config:)` (BlockchainService.swift:890)
calls `RPCFallbacks.orderedAttempts` — the **unfiltered** list — and
contains no `markOk` / `markAuthFailed` / `markTransientFailed` and no
`classifyForFallback`. Three consequences:

- Cooldowns don't apply, so every balance refresh re-tries endpoints the
  router already knows are dead. The 30-minute auth cooldown and
  5-minute transient cooldown, which exist precisely to stop this, are
  bypassed on the most frequently executed path in the app.
- Failures are never recorded, so the cooldown registry never learns
  from the path that generates the most traffic.
- Business errors don't abort. An invalid address or an empty result is
  retried against every endpoint in the list before surfacing.

`TransactionConfirmationPoller` (lines 91 and 112) has the same defect,
and it runs on a timer.

The two paths that do it correctly — `ethSendRawTransaction` (line 230)
and `withFallbackURL` (line 308) — use `resolvedAttempts` and report
health properly. The fix is to route the other two through the same
helper rather than to duplicate the logic a third time.

### 3. Measured health never influences routing

`NodeHealthStore` collects latency (a rolling 20-sample history per
chain), block height, chain-ID mismatch and block-lag-versus-reference.
`RPCFallbacks.orderedAttempts` ignores all of it: order is "user's URL,
then a hardcoded list, in source order". A reachable-but-slow primary
stays first forever. Two systems that should be one.

### Why this reads as "free nodes are unreliable"

Defect 1 puts a dead host first in the recovery path. Defect 2 makes the
app re-pay that cost on every single refresh instead of once. Defect 3
means it never adapts. The free endpoints themselves are, by
measurement, 29/35 healthy at 100–300 ms.

## Evaluating the proposal on its merits

The proposal — drop free defaults, require a paid commercial provider,
gate onboarding on configuring one — has real arguments behind it, and
they deserve to be stated before being weighed.

**For:** predictable, contractual performance. No shared-infrastructure
rate limits. No silent list rot, because the user owns the endpoint. A
clear answer to "who is serving my requests".

**Against, and this is decisive:**

- **It inverts the product's own positioning.** Horcrux's pitch is that
  threshold signing is *easier* than a hardware wallet and needs no seed
  phrase. "Register with Alchemy and paste an API key before you can see
  your balance" is meaningfully harder than plugging in a Ledger. P1.2
  on the roadmap is literally "value-proposition onboarding"; this would
  put an account-creation wall in front of it.
- **A wallet that displays nothing on first launch reads as broken,**
  not as secure. The user cannot distinguish "not configured" from
  "doesn't work" before they have any trust in the app.
- **It does not remove the need for a fallback list.** One provider is
  one point of failure. Alchemy has outages. The router still needs
  somewhere to go, which means a curated list still has to exist and
  still has to be maintained — so the maintenance burden the proposal
  is meant to eliminate stays.
- **It makes privacy worse, not better.** This is the least obvious
  point and the most important. Today a user's address queries are
  spread across rotating public endpoints with no account attached.
  Under the proposal, one company — holding the user's email and
  possibly card — sees every address the user owns, every balance
  check, and every broadcast, all bound to a billing identity. For a
  self-custody wallet that is a downgrade.
- **The premise doesn't hold.** 29/35 healthy. Six dead entries, five of
  them one provider, none of them a default.

**The salvageable core of the proposal:** the instinct that we should
not *depend* on strangers' free infrastructure is right. The correction
is that the lever is **keyed access, not paid access**. Alchemy, Infura,
dRPC and Helius all have free tiers that issue a key; a key buys a
dedicated rate limit, which is the actual failure mode of shared public
endpoints. So the upgrade we should push users toward is "bind your own
key (the free tier is enough)", not "buy a commercial plan" — a far
smaller ask that captures nearly all of the reliability benefit.

## Approaches

**A — Repair and adapt; keys are a prominent optional upgrade.**
Purge the dead entries, route every path through the health-aware
helper, order candidates by measured health, and automate rot
detection. Onboarding gains a visible but skippable "connect your own
node provider" step, and the app becomes loud and specific when it is
actually degraded.

**B — The proposal as stated.** No free defaults; onboarding blocks
until a provider is configured.

**C — Ship free defaults but label the free tier best-effort,** with a
prominent optional provider step and no behavioural changes to routing.

A is recommended. It fixes the measured causes, keeps first-run
working, and still moves users toward owning their endpoint — it just
declines to hold the wallet hostage to get there. C leaves all three
defects in place and only changes copy. B trades a large, certain
onboarding loss for a benefit that the measurements do not support, and
costs privacy on the way.

## Design

### Part 1 — correct under any product direction, implemented now

These are defect repairs. They are required whether or not we later
adopt B, so they carry no product risk.

**1.1 Purge dead endpoints.** Remove all five LlamaRPC entries and
`polygon-rpc.com` from `RPCFallbacks`. Ethereum mainnet's fallback
becomes `ethereum-rpc.publicnode.com` (matching the verified default
hostname rather than the different, unverified `ethereum.publicnode.com`
the table currently used) plus `eth.drpc.org`. Polygon keeps
`polygon-bor-rpc.publicnode.com` and gains `polygon.drpc.org`. Arbitrum,
Base and Optimism keep their official and publicnode entries and gain
their dRPC equivalents, so every chain retains at least three
independent providers. Drop the LlamaRPC pin from `CertificatePinner`
and its placeholder from the Settings text field.

**1.2 Route the read path through the health-aware helper.** Change
`balance(for:config:)` and both `TransactionConfirmationPoller` helpers
to use `withFallbackURL`, giving them cooldown filtering, health
reporting and business-error abort for free, with no duplicated policy.

**1.3 Health-aware ordering.** `RPCFallbacks.resolvedAttempts` keeps the
user's configured URL pinned first — an explicit choice must be honoured
— and orders the remaining candidates by observed health: endpoints with
a recent success first, then untried, then those whose cooldown has
expired. Ordering is a stable sort so the curated order breaks ties.

**1.4 Detect rot automatically.** A scheduled workflow probes every
endpoint in the table weekly and opens an issue when one fails twice
consecutively. This is the systemic fix: the list rotted for months
because nothing watched it, and purging it today without this guarantees
we are back here in six months.

### Part 2 — requires a product decision, specced only

**2.1 Onboarding step.** A "node provider" screen after PIN setup:
explains in one line that Horcrux talks to public nodes by default and
that binding a free-tier key of your own is faster and more private,
with "Add a key" and "Skip for now" as equal-weight buttons. Skip is
not a dark pattern here — the app genuinely works without it.

**2.2 Contextual nudge.** When `NodeHealthStore` records repeated
failure or sustained high latency for a chain the user actually holds
assets on, surface a specific, dismissible prompt naming the problem
("Ethereum reads have failed 4 times in 10 minutes") and offering the
key flow. Triggered by measurement, not shown on a timer.

**2.3 Honest degradation.** The wallet list distinguishes "balance
unavailable — node unreachable" from a zero balance. Today a failed
read is visually indistinguishable from an empty wallet, which is its
own trust problem and is arguably a larger contributor to the "nodes
are unreliable" perception than the endpoints are.

**2.4 Privacy disclosure.** A line in node settings stating plainly that
whichever endpoint is configured can see the addresses queried, and that
this is true of both the public defaults and any provider key. Neither
option is private; the user should get to choose knowingly.

## Testing

Part 1.1 is covered by asserting no fallback list contains a
known-dead host and that every chain retains ≥2 distinct provider
families. Part 1.2 is covered by asserting that a cooling endpoint is
excluded from the balance path's attempt list and that a business error
aborts instead of walking the list. Part 1.3 is covered by unit tests
over the ordering function with a seeded health registry: recent-success
first, user URL always first, stable within a tier. Part 1.4 is
validated by running the probe workflow manually against a
deliberately-broken entry.

The endpoint measurements in this document are a snapshot, not a test
fixture; tests must not depend on live network calls.

## Open questions

- Should Horcrux operate its own RPC proxy? It would fix reliability and
  hide user IPs from providers, but it would put Horcrux itself in the
  position of seeing every address — the exact concentration this
  document argues against for commercial providers. Not proposed here.
- Whether to pin certificates for the new default hosts, or accept TOFU.
  The current known-pin set is stale relative to the endpoints actually
  in use: `eth.llamarpc.com` is pinned while `ethereum-rpc.publicnode.com`,
  the real default, is not.

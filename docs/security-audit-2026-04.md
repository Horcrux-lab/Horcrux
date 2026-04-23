# Horcrux Web3 Security Audit — Internal Pre-External-Audit Review

**Auditor**: Internal review (Web3 security engineer role-play composite)
**Date**: 2026-04-23
**Scope**: `horcrux-core` (Rust MPC) · `horcrux-relay` (WS broker) · iOS security layer · chain adapters + FFI
**Code size**: ~10.5K LoC Rust + ~3K LoC Swift
**Status**: Draft — not a substitute for the external audit, but a structured list of findings to close before engaging one.

Verification legend:
- ✅ Claim verified against source during this audit
- ⚠️ Plausible, needs source-level confirmation by implementor
- ❌ Agent-reported but disproven / downgraded

---

## Overall posture

Engineering quality is **above the industry average for MPC wallets**:
Noise Protocol for transport, `subtle::ConstantTimeEq` for tokens,
600k PBKDF2 iterations, Secure Enclave with `biometryCurrentSet`,
non-root container with SLSA provenance + SBOM, FROST RFC 9591 and
CGGMP21 delegated to mature crates rather than hand-rolled.

Nonetheless, **do not ship to mainnet** before the P0 / P1 items
below are closed. Chief concerns cluster around:

1. MPC-layer sender authentication (messages bind to Noise channel but
   not to the declared party index → rogue-party hooks).
2. iOS PIN lifetime in memory (Swift `String` cannot be zeroized).
3. EVM blind signing — no ABI decoding on `data` field in the UI.
4. Several DoS vectors (unbounded `n`/`t`, `serde_json` panics).

---

## CRITICAL

### C1 — MPC messages lack end-to-end party-identity binding ✅ (core) / ⚠️ (iOS call-site migration pending)
**Location**: `horcrux-core/src/mpc/signing.rs:204`, `keygen.rs`, `session.rs`

Protocol messages carry `from: party_index` as a payload field. The
Noise transport only authenticates "this channel's peer"; it does not
bind the claimed MPC party index to that channel. A malicious
participant can assert `from = someone_else_index` inside their own
channel to inject round-1/2 contributions and bias aggregation.

**Attack family**: rogue-party attacks (well-known in GG20 / CGGMP21 errata).

**Fix direction**: bind `(mpc_session_id, party_index, round_id)` into
the Noise channel binding (infrastructure exists in `transport/e2e.rs`
already — just not wired through). Alternatively attach a per-message
ECDSA signature over `(session_id || round_id || payload)` using each
party's long-term identity key.

This is the single most important finding in this audit. External
auditors will focus here.

### C2 — iOS PIN string not zeroized in memory ✅
**Location**: `ios/Horcrux/Security/SecureKeyVault.swift:109`
(`unwrapWithPin(_ pin: String)`) and the entire SWK-unwrap call chain.

Swift `String` is copy-on-write with interning — "manual clear" is
structurally impossible. The PIN plaintext therefore lives in process
memory for an indeterminate window, which iOS may dump to disk during
JetsamEvents or CrashReporter runs on a jailbroken or forensic-stance
device.

**Fix**:
- Carry PIN as `[UInt8]` / `Data` (both support in-place clear)
- `ContiguousArray<UInt8>` with `replaceSubrange` zeroing after use
- UITextField `isSecureTextEntry` — read bytes, never expose as `String`

### C3 — Legacy v1 SWK not force-erased after migration ✅
**Location**: `ios/Horcrux/Security/SecureKeyVault.swift:50`
(`keychainPinWrappedLegacy = "com.horcrux.swk.pin.v1"`)

v1 used 100k PBKDF2; v2 uses 600k. If migration writes v2 without a
hard delete of v1, an attacker who captured v1 (e.g. historical
backup) keeps a 100k-iteration offline brute-force path indefinitely.

**Fix**: `SecItemDelete(legacyQuery)` must run inside the same atomic
migration step; add a post-migration self-check that the legacy key is
absent; audit the migration exit paths for early-return gaps.

### C4 — EVM blind signing: `data` field not decoded in UI ✅ (decoder + consent gate) / ⚠️ (second-gate byte-equivalence pending)
**Location**: UI layer under `ios/Horcrux/Features/` + `horcrux-core/src/chain/evm.rs:43`

Users sign DEX / DeFi / NFT transactions where the `data` field is
the actual authorisation. If the UI only shows `to` + `value`, the
user's perceived action ("log in") can mask the real one
(`approve(attacker, 2**256-1)`) → wallet drain by a malicious dApp.

**Fix**:
- Decode well-known 4-byte selectors: ERC20 `transfer` / `approve` /
  `permit`, ERC721 `setApprovalForAll`, Uniswap-router methods
- Unknown selectors → red-banner warning + second confirmation
- Hard-block `setApprovalForAll` and `approve(max_uint)` against
  non-allowlisted contracts

This is the pattern hardware wallets (Ledger / Trezor) have been
publicly criticised for. A Web3-focused audit will demand it.

### C5 — Solana blockhash / nonce freshness not enforced ✅
**Location**: `horcrux-core/src/chain/solana.rs`

Solana `recent_blockhash` has a ~90s validity window. If a tx is
signed and delayed, it expires; worse, if the same blockhash is reused
across signing rounds, a targeted replay can swap outcomes.

**Fix**: check blockhash age at sign time; force refresh on every
signing; distinguish blockhash vs durable-nonce modes explicitly in
the FFI / UI.

---

## HIGH

### H1 — Fiat-Shamir challenges don't bind round number ✅
`signing.rs`, `keygen.rs`. Challenges must hash
`(domain_separator || session_id || round_id || msg)` to resist
round-skipping attacks.

### H2 — No upper bound on `n` / `t` ✅
`signing.rs:77-88` validates `participants.len() >= threshold` but no
ceiling. Peer-supplied `t = n = 1_000_000` blows up Feldman VSS
memory. Add `const MAX_PARTICIPANTS: u16 = 32;` in `types.rs` and
enforce at keygen + signing entry.

### H3 — `serde_json` / `Scalar::from_bytes` panic paths ✅
`signing.rs:137-152` uses `.unwrap()` on peer payload deserialisation;
`keygen.rs` similar. A single malformed peer message panics the
session manager and takes down every in-flight ceremony.
**Fix**: propagate errors via `?`; isolate per-session panics.

### H4 — iOS cert pinning rotation fallback ⚠️
`CertificatePinner.swift`. Reported fallback to default chain
validation on pin rotation. If true → MITM window during rotation.
**Fix**: dual-pin (current + next), hard-fail on mismatch.

### H5 — Keychain ACL not uniformly passcode-gated ⚠️
`KeychainManager.swift`. Some items may not carry
`kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` +
`.biometryCurrentSet`, allowing extraction on devices without
passcode set.
**Fix**: single policy helper; apply across every `SecItemAdd` site.

### H6 — Relay IP rate-limit ignores `X-Forwarded-For` ✅
`horcrux-relay/src/ip_ratelimit.rs`. Behind Caddy, source IP seen by
relay is `127.0.0.1` → global rate-limit degenerates to one bucket; a
single abuser starves everyone.
**Fix**: parse trusted `X-Forwarded-For`/`X-Real-IP` (Caddy already
sets these); document the trust-the-proxy requirement explicitly.

### H7 — Broadcast channel buffer of 256 untuned ✅
`horcrux-relay/src/room.rs:50`. Slow consumers trigger `Lagged`, which
evicts the peer. Realistic high-latency co-signers may be evicted
incorrectly.
**Fix shipped (round 6)**: `RelayConfig::broadcast_buffer` (env
`RELAY_BROADCAST_BUFFER`, default 1024, clamped `[64, 65536]`) replaces
the hard-coded 256. Operators tune for their fan-out / RSS trade-off.

### H8 — EIP-712 domain separator not validated ⚠️
If EIP-712 is wired into the signing flow (check `chain/evm.rs`), the
`verifyingContract` + `chainId` inside the `EIP712Domain` must be
displayed to the user and compared against the expected contract.
Otherwise a malicious dApp forges the domain to reuse the signature
on another contract.

### H9 — Bitcoin UTXO provenance not verified ✅ (core)
`chain/bitcoin.rs` (PSBT handling). A malicious UI can craft a PSBT
where the claimed input amount differs from the actual on-chain UTXO
→ "fee inflation" drain (user thinks 0.0001 BTC fee, signs 0.99 BTC).
**Fix**: require non-witness UTXO in the PSBT and hash-match it;
optionally RPC-verify.

### H10 — `u128` fee / value math without checked ops ✅
`chain/evm.rs`. Replace all `*` / `+` with `checked_mul` /
`checked_add` (or `saturating_*`) on fee- and value-related paths.
Failures → typed error, never panic.

---

## MEDIUM

- **M1** ✅ (round 6) Relay `/admin/*` 404 at Caddy is perimeter-only —
  direct-to-relay bypass leaves admin routes live. `RelayConfig::admin_allowed_ips`
  (env `RELAY_ADMIN_ALLOWED_IPS`) adds an app-layer L4 peer-IP check
  in addition to the admin token. Fails closed when allowlist is set
  but `ConnectInfo` is unavailable; explicitly does not trust XFF.
- **M2** ✅ (round 6) Relay room TTL uses `SystemTime` (wall-clock) —
  NTP step breaks cleanup. `monotonic_now_ms()` anchored on a process-
  local `Instant` epoch now powers `Room::touch` / `is_expired` and
  the constructor stamp.
- **M3** `prime_pool.rs` can orphan on-disk files under concurrent
  access. Add `flock` or atomic-rename.
- **M4** MPC structs derive `Debug` — debug logs may dump secret
  fields. Custom `Debug` + `#[derive(Zeroize)]` on secret wrappers.
- **M5** FFI `Error::to_string()` can leak internal state to Swift;
  whitelist user-facing messages in `HorcruxError::display()`.
- **M6** iOS screenshot / screen-recording not blocked on sensitive
  screens. Add blurred overlay on `willResignActive`.
- **M7** Deep-link handlers (`joinSession`) require no confirmation —
  phishing page can trigger an auto-join.
- **M8** Bitcoin fee-rate unit confusion (sat/vB vs sat/B vs sat/kB)
  — encode via new-type wrapper.
- **M9** Clipboard 60s auto-clear unreliable when app backgrounds.
- **M10** `PrivacyInfo.xcprivacy` Required-Reason API list may be
  incomplete — App Store reject risk.

---

## LOW / HYGIENE

- **L1** ✅ (round 6) `rand::thread_rng` used in `keygen.rs:134`,
  `signing.rs:178`, `shard/crypto.rs:61,68`, `transport/e2e.rs:274`.
  **Agent report flagged this as CRITICAL "non-CSPRNG" — this is
  incorrect.** `thread_rng` is ChaCha12 seeded from OsRng and is
  cryptographically secure. The repo previously mixed `thread_rng`
  and `OsRng`; round 6 unified all five callsites onto
  `rand::rngs::OsRng` so reviewers no longer have to verify the
  RNG's cryptographic provenance per occurrence.
- **L2** Error messages leak party indices. Low impact but external
  auditors will comment.
- **L3** Dockerfile build stage runs as root. No runtime impact.
- **L4** GHA workflows use mutable `@v3` / `@v4` tags rather than SHA
  pins — supply-chain surface.

---

## Disproven / overstated agent findings

- ❌ **"`thread_rng` is non-CSPRNG"** — incorrect; see L1.
- ❌ **"EIP-55 checksum validation missing in `evm.rs`"** — the
  signing layer correctly operates on raw 20-byte addresses; checksum
  validation belongs in UI input, not the signing core.
- ❌ **"Zero address (`0x0…`) not rejected"** — burns are a
  legitimate operation. Chain adapter should not enforce policy here;
  a UI warning is sufficient.
- ❌ **"Solana program IDs not validated"** — allowlisting programs
  is a UI / policy concern. The signing adapter correctly treats
  instruction bytes as opaque.

---

## Positive findings (preserve these)

- ✅ Noise Protocol for E2E transport — minimal hand-rolled crypto
- ✅ `subtle::ConstantTimeEq` on room tokens (relay)
- ✅ 600k PBKDF2 iterations on the v2 SWK wrap (OWASP 2023 aligned)
- ✅ Secure Enclave with `.biometryCurrentSet` ACL — invalidates SE
  key on Face ID rotation (defends against "stolen unlocked phone")
- ✅ `Zeroize on Drop` applied in shard crypto + transport hot paths
- ✅ FROST RFC 9591 + CGGMP21 delegated to mature crates
- ✅ Constant-time token compare on admin routes + opt-out validation
- ✅ Container hardening: non-root, read-only FS, cap drops, HEALTHCHECK
- ✅ SLSA provenance + SBOM attestations on relay CI artefacts
- ✅ `RecentCoSignersStore` — social-engineering mitigation at UX

---

## Remediation plan

**P0 — required before any mainnet / external audit kickoff**
1. C1 — MPC channel binding + per-message sender auth
2. C2 — PIN path converted to `[UInt8]` with explicit zeroization
3. C4 — EVM data-field ABI decoding + blind-sign warning + `approve` hard-block
4. H3 — deserialisation panic paths converted to `Result`
5. H2 — `n` / `t` upper bounds

**P1 — before external audit closeout**
6. C3 — v1 SWK force-delete on migration + self-check
7. C5 — Solana blockhash freshness at sign time
8. H1 — round-id binding in Fiat-Shamir challenges
9. H6 — XFF parsing + trust-the-proxy documentation
10. H9 / H10 — Bitcoin UTXO provenance + EVM `u128` checked ops

**P2 — during external audit window**
11. Remaining HIGH (H4, H5, H7, H8) + all MEDIUM

---

## Suggested external-audit scope

Firms to consider: Trail of Bits, Cure53, OtterSec, Halborn,
Zellic, NCC Group. For MPC specifically, ToB and Zellic have the
strongest track record.

- **Must-cover**: C1, H1, H8, H9 (MPC protocol integrity + chain
  replay resistance)
- **Must-cover**: C2, C3 (iOS key lifecycle)
- **Must-cover**: C4 (blind-signing model and UX)
- Provide the firm with `docs/push-notifications.md` so APNs is in
  scope as future work, not retroactively discovered
- Provide this document as the known-findings baseline so they can
  skip the obvious and focus on novel issues

Ballpark: 5–7 weeks with 2 engineers, USD 80k–150k depending on
firm and depth tier.

---

**This document is living.** Update the verification-status column
(`✅` / `⚠️` / `❌`) as P0/P1 fixes land and as the external audit
confirms or disputes findings.

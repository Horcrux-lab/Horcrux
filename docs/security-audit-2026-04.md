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

### C1 — MPC messages lack end-to-end party-identity binding ✅
**Location**: `horcrux-core/src/mpc/signing.rs:204`, `keygen.rs`, `session.rs`

Protocol messages carry `from: party_index` as a payload field. The
Noise transport only authenticates "this channel's peer"; it does not
bind the claimed MPC party index to that channel. A malicious
participant can assert `from = someone_else_index` inside their own
channel to inject round-1/2 contributions and bias aggregation.

**Attack family**: rogue-party attacks (well-known in GG20 / CGGMP21 errata).

**Resolution**:
- **Core (round 1)**: `SessionManager::handle_authenticated_message(msg, authenticated_from)` rejects any message whose `msg.from` does not equal the channel-authenticated party index. Legacy `handle_message` retained but `#[deprecated]`. Unit-tested via `session.rs` impersonation test.
- **iOS call-sites (round 14)**:
  - **Online signing** (`SigningViewModel`): resolves `authenticatedFrom` from the per-session `peerPartyIndex[peer.id]` map populated by `SignPresenceDTO` harvesting; rejects both unknown-peer and party-mismatch before dispatch.
  - **DKG** (`CreateShardViewModel`): builds a deterministic `dkgPeerPartyIndex` during `autoAssignPartyIndex()` (sorted-identity → 1-based index) and enforces the same two-stage check in the round-loop `handleMessage` callsite.
  - **Refresh** (`RefreshShardCoordinator`): TOFU-per-session — first inbound `fromParty` from each peer is frozen; subsequent divergence or self-impersonation is rejected. (Refresh has no explicit roster registry, so TOFU is the strongest layer-level enforcement available without a full peer-registry redesign.)
  - **Cold signing v1** (`ColdSigningCoordinator`): 2-of-2 only — counterparty index is unambiguous (`3 - wallet.partyIndex` for initiator, `i.initiatorParty` for cosigner); every `handleAuthenticatedMessage` call binds to this pre-established expectation. Visual QR hand-off is the channel authentication; no Noise tunnel exists.
  - **Cold signing v2** (`ColdSigningCoordinatorV2`): t-of-n star-topology — enforces `msg.fromParty != myIndex` (self-impersonation), then binds `authenticatedFrom = msg.fromParty`. The QR-scan visual verification remains the channel authentication. Tracked follow-up: scan-session fingerprint tracking for stronger cross-QR binding.
- **Deprecation**: bridge method `handleMessage` retained (deprecated) only for source-code archaeology; all production paths now use `handleAuthenticatedMessage`.

**Residual risk**: refresh TOFU binds only within a single session — a long-lived compromise of the first-contact channel can still assert any party index. A full peer-registry (Noise static-pk → party_index derived at DKG time and persisted in wallet metadata) is tracked as a separate hardening pass.

This was the single most important finding in this audit.

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

### C4 — EVM blind signing: `data` field not decoded in UI ✅
**Location**: UI layer under `ios/Horcrux/Features/` + `horcrux-core/src/chain/evm.rs:43`

Users sign DEX / DeFi / NFT transactions where the `data` field is
the actual authorisation. If the UI only shows `to` + `value`, the
user's perceived action ("log in") can mask the real one
(`approve(attacker, 2**256-1)`) → wallet drain by a malicious dApp.

**Fix shipped (rounds 4 + 11)**:
- Round 4: 4-byte selector decoder for ERC-20 `transfer`/`approve`/
  `transferFrom`, ERC-721 `setApprovalForAll`; unknown selectors
  surface a red-banner warning; `approve(max_uint)` and
  `setApprovalForAll(true)` hard-block unless the contract is
  allowlisted (first gate — decoder + consent UI).
- Round 11: **second gate (byte-equivalence)**. In
  `SigningViewModel.startSigning`, immediately after
  `buildSignHash()` produces `messageHash`, we recompute
  `keccak256(pendingEvmRawData)` and assert equality before calling
  `bridge.startSigning`. This closes the gap where the UI could
  decode and display calldata `A`, then feed `keccak256(B)` into the
  MPC ceremony (memory corruption, tampered view-model state, or
  any code path mutating `pendingEvm*` fields between approval and
  signing). On mismatch we throw `SigningError.sighashMismatch`
  which surfaces to the user as "Transaction payload changed
  between approval and signing — signing aborted for your safety".
  By collision resistance, the equality check cryptographically
  binds the bytes the MPC signs to the bytes the UI decoded.

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

### H4 — iOS cert pinning rotation fallback ✅
`CertificatePinner.swift`. Reported fallback to default chain
validation on pin rotation. If true → MITM window during rotation.
**Fix shipped (round 11)**: split pinning policy into known vs TOFU
hosts. `registerKnownPins()` now freezes a `knownHosts: Set<String>`
at init. In `validate()`, when the presented chain's SPKI hashes are
disjoint from the stored pins, known hosts HARD-FAIL (returns
`false`, connection rejected, error logged) and only TOFU hosts
(user-configured endpoints) auto-rotate with a warning. Dual-pin
structure (current + backup CA root) was already in place per host;
the H4 gap was the silent re-pin fallback on mismatch that defeated
the entire guarantee. Doc block on `registerKnownPins` now specifies
the operational rotation process (obtain next-gen SPKI, add as
backup, ship release, promote after rotation day).

### H5 — Keychain ACL not uniformly passcode-gated ✅
`KeychainManager.swift`. Some items may not carry
`kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` +
`.biometryCurrentSet`, allowing extraction on devices without
passcode set.
**Fix shipped (round 10)**: `AppState.setPin`, `AppState.changePin`
(new-PIN write), and `AppState.persistFailedAttempts` now route
through `KeychainManager.storeSecure` — passcode-gated ACL via
`SecAccessControlCreateWithFlags(kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, [])`
with the existing no-passcode fallback. Existing installs migrate
opportunistically on the next successful `verifyPin` (we re-store the
hash through `storeSecure`). The only Keychain entries still using
plain `.store` are user configuration (relay URL, RPC endpoints) —
intentional, not security-critical. Shard-wrap key and device key
were already passcode-gated via `storeSecure`.

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

### H8 — EIP-712 domain separator not validated ✅
If EIP-712 is wired into the signing flow (check `chain/evm.rs`), the
`verifyingContract` + `chainId` inside the `EIP712Domain` must be
displayed to the user and compared against the expected contract.
Otherwise a malicious dApp forges the domain to reuse the signature
on another contract.

**Fix shipped (round 13)**: No EIP-712 code path existed at audit
time, but to prevent a future integrator from skipping domain
binding, added a sanctioned, validation-first entry point in
`horcrux-core/src/chain/evm.rs::eip712_digest(&Eip712Domain,
struct_hash) -> Result<[u8;32], ChainError>`. The function
hard-fails on:
- `chain_id == 0` (allows cross-chain replay),
- `verifying_contract == 0x0` (allows cross-contract replay),
- empty `name` (lets a signed typed-data blob be replayed across
  dApps that also forgot to set a name).

Hard-coded `EIP712Domain` type hash (string `"EIP712Domain(string
name,string version,uint256 chainId,address verifyingContract)"`)
so a typo in the canonical string cannot downgrade to a malleable
variant. Exposed via FFI as `horcrux_eip712_digest` with
`FfiEip712Domain` record. Six unit tests cover the three rejection
paths + chain-id / contract / struct binding properties +
determinism. Tests pass (`cargo test -p horcrux-core --lib` 173
pass). **Operational note for future iOS integration**: the UI
must display decoded `name / version / chainId / verifyingContract`
and obtain explicit user consent before invoking this digest; the
Rust layer only enforces the cryptographic binding, not what the
user actually saw on screen.

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
- **M3** ✅ (round 7) `prime_pool.rs` could orphan on-disk files
  under concurrent access if two background producers hit the same
  nanosecond. Filename nonce now includes a 64-bit `OsRng` salt
  alongside the wall-clock so collisions are cryptographically
  unlikely; atomic `tmp → final` rename remains.
- **M4** ✅ (round 9) MPC structs derive `Debug` — debug logs may dump
  secret fields. `MpcMessage`, `KeygenResult`, `Round2Share`,
  `FrostShardData`, `EcdsaShardData` got `Zeroize` + `ZeroizeOnDrop`
  + custom `Debug` that prints `<redacted: N bytes>` in place of
  secret payloads. FFI `From` impls switched to `std::mem::take` to
  extract owned buffers past `Drop`.
- **M5** ✅ (round 8) FFI `Error::to_string()` could leak internal
  state to Swift. New `sanitize_ffi_msg()` helper at the
  `MpcError → HorcruxError` and `chain::ChainError → ChainError`
  boundaries (and at the `shard_crypto` `to_string` sites): emits
  the full message via `tracing::error!`, then strips control
  bytes / newlines, truncates to 256 chars, and redacts contiguous
  hex runs ≥ 64 chars (likely accidental key/digest material)
  before returning to the caller.
- **M6** ✅ (already closed) iOS screenshot / screen-recording not
  blocked on sensitive screens. Verified in round 10:
  `HorcruxApp.swift:67-82` attaches `.blur(radius: 30)` on
  `UIApplication.willResignActiveNotification` and clears it on
  `didBecomeActive`, with an accessibility label swap. This is the
  textbook `willResignActive` overlay approach and covers both the
  app-switcher snapshot and the screen-record indicator state.
- **M7** ✅ (round 10) Deep-link handlers (`joinSession`) require no
  confirmation — phishing page can trigger an auto-join.
  `DeepLinkRouter` now parks `joinSession` URLs in a new
  `pendingConfirmation` slot instead of activating them.
  `HorcruxApp` shows a two-button alert ("Cancel" / "Continue") whose
  message explicitly warns the user that an external link is trying
  to open a signing / DKG ceremony. Only `confirmPending()` promotes
  the link to `pendingLink`. Read-only deep links (`transactionDetail`,
  `receive`) still auto-activate since they don't expose the user to
  cryptographic operations.
- **M8** ✅ (round 9) Bitcoin fee-rate unit confusion (sat/vB vs
  sat/B vs sat/kB). New `SatPerVbyte` newtype in `chain::bitcoin`
  with explicit `from_sat_per_kvbyte` (rounds up via `div_ceil`),
  `from_sat_per_byte`, and `as_sat_per_vbyte` / `as_sat_per_kvbyte`
  accessors plus `Display` (`"42 sat/vB"`). Currently no API surface
  consumes it — adopted proactively so any future fee-rate parameter
  lands as a unit-encoded type rather than a bare `u64`.
- **M9** ✅ (round 10) Clipboard 60s auto-clear unreliable when app
  backgrounds. `CopyFeedback.copy` (the app-wide copy-to-clipboard
  entry point) now routes through `SecureClipboard.copy` so every
  call gets the OS-level `UIPasteboard.OptionsKey.expirationDate`
  auto-clear. Three direct `UIPasteboard.general.string = …` call
  sites (audit-export JSON, RPC URL copy, and the
  `Signing.recipient-address` button via `CopyFeedback.copy`) were
  rerouted to `SecureClipboard.copy`. Expiration is 60 s default and
  survives app backgrounding because it's enforced by the pasteboard
  daemon, not our process.
- **M10** ✅ (round 10 — verified complete, no changes needed)
  `PrivacyInfo.xcprivacy` Required-Reason API list may be incomplete
  — App Store reject risk. Manifest currently declares
  `NSPrivacyAccessedAPICategoryUserDefaults` / `CA92.1` (for
  `UserDefaults` usage in `RelayConfig`, `AddressBook`, etc.). Full
  Swift tree scan confirms no uses of the other Required-Reason API
  categories: file timestamps (no `modificationDate` /
  `attributesOfItem` / `contentModificationDateKey`), system boot
  time (no `systemUptime` / `CACurrentMediaTime` / `mach_absolute_time`),
  disk space (no `volumeAvailableCapacity` / `NSFileSystemFreeSize`),
  or active keyboards (no `activeInputModes`). No third-party SPM /
  CocoaPods dependencies (only the in-house `HorcruxCore.xcframework`
  and `libhorcrux_core.a`).

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
- **L2** ✅ (round 8) Error messages leak party indices. Three call
  sites in `mpc::keygen` + `mpc::ecdsa` reformatted to log party
  index via `tracing::warn!` while returning a generic message —
  party identifiers no longer cross the FFI boundary inside
  `MpcError::ProtocolError` strings.
- **L3** ✅ (round 7) Dockerfile build stage runs as root. Builder
  stage now runs as uid 1000 (`builder` user); runtime stage was
  already non-root. Eliminates the malicious-build-script-as-root
  surface inside the build container.
- **L4** ✅ (round 7) GHA workflows use mutable `@v3` / `@v4` tags
  rather than SHA pins — supply-chain surface. All `uses:` lines in
  `.github/workflows/{ci,relay-image}.yml` pinned to commit SHAs
  with the human-readable tag in a trailing `# vN` comment.

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

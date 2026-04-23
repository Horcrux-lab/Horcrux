# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security

- **Refresh C1 round-16 tests** — extract the per-message peer-
  binding decision from `RefreshShardCoordinator`'s async loop into
  a pure, nonisolated static function (`decidePeerBinding`) returning
  a new `PeerBindingDecision` enum (`acceptAlreadyBound`,
  `acceptTOFU`, `rejectIndexMismatch`, `rejectUnknownPeer`). Adds
  `HorcruxTests/RefreshPeerBindingTests.swift` with 7 tests covering
  every branch: legacy-wallet TOFU admit / same-session index flip,
  and strict-mode accept-known / reject-known-wrong-index / reject-
  intruder / empty-registry-is-TOFU. Behavior is unchanged; the
  in-loop logic now delegates to the pure function.

- **Relay deploy smoke script** — `scripts/verify-relay-deploy.sh`.
  Operator-facing PASS/FAIL gate for every public HTTP surface the
  relay exposes: `/health` (200, `status=ok`, version matches
  `horcrux-relay` crate), `/metrics` and `/admin/rooms` (admin-token
  enforcement), `/ws/:room_id` (101 Switching Protocols with an
  RFC-6455-correct `Sec-WebSocket-Accept`), and TLS certificate
  validity for `https://` URLs (distinguishes "cert untrusted" from
  "server down" via an `--insecure` retry). Zero deps beyond
  `curl`/`awk`/`sed`; `openssl` is used when present to compute the
  WebSocket accept handshake. Exit 0 if all pass, 1 on any failure,
  2 on usage error — safe to wire into a CI pre-deploy job.
  Verified locally against a live relay: 7/7 checks green.

- **Audit C1 round-16 follow-up** — AccountBackup migration tests.
  Adds `HorcruxTests/AccountBackupMigrationTests.swift` (4 tests)
  covering: (a) legacy v3 JSON (no `peerRegistry` key) decodes with
  `peerRegistry == nil`, (b) v4 encode→decode preserves the
  registry verbatim, (c) nil-registry round-trip is symmetric, and
  (d) `BackupPreview.peerRegistry` accessor returns the registry on
  `.account` variants and `nil` on `.legacy` variants. Closes the
  round-16 "does the registry actually survive export/import?" gap.

- **Audit H8 follow-up** — iOS FFI binding smoke tests for
  `horcruxEip712Digest`. Adds `HorcruxTests/Eip712BindingTests.swift`
  with 7 tests covering determinism, chain_id replay-binding,
  verifyingContract replay-binding, struct-hash binding, hex parsing
  with/without `0x` prefix, and propagation of the Rust-side guards
  (zero chain_id, zero verifyingContract, non-hex input) as Swift
  throws. Proves the uniffi surface is reachable end-to-end before
  building the consumer UI.

- **Audit P0 round 16** — Refresh explicit peer-registry (eliminates
  TOFU residual risk for C1). `Wallet` now carries an optional
  `peerRegistry: [String: UInt16]?` populated at DKG time from the
  `dkgPeerPartyIndex` map built by `autoAssignPartyIndex`. On every
  refresh, `RefreshShardCoordinator` loads this registry and enforces
  it in strict mode — inbound messages from a `peer.id` outside the
  DKG roster are rejected, and index mismatches are still flagged as
  impersonation. `AccountBackup` v4 carries the registry so restored
  accounts inherit the strict roster. Legacy wallets created before
  this round (`peerRegistry == nil`) fall back to the round-14 TOFU
  path and, on the first successful refresh, have the observed map
  persisted via `WalletStore.setPeerRegistryIfAbsent`, so every
  subsequent ceremony runs in strict mode with no TOFU window.

- **Audit P0 round 15** — Cold-signing v2 scan-session TOFU + fingerprint.
  Closes the round-14 follow-up for `ColdSigningCoordinatorV2`:
  - **sessionId enforcement**: `feedInbound` rejects any inbound
    message whose `sessionId` does not match the coordinator's
    active ceremony. Previously only Rust session-state machine
    would catch mismatches, which produced a confusing error; the
    coordinator-level check gives a clear `walletMismatch`
    diagnostic and avoids feeding off-ceremony payloads into the
    MPC engine at all.
  - **Per-party sessionId stickiness (TOFU)**: the first inbound
    message from each `fromParty` within a ceremony binds that
    party's asserted `sessionId`. Any later message from the same
    party with a different `sessionId` is treated as a ceremony
    splice (attacker re-using a valid party slot to inject traffic
    from a parallel ceremony) and rejected.
  - **Scan-session fingerprint**: on first contact with each party
    the coordinator computes
    `SHA256(sessionId ‖ fromParty_be ‖ first_payload)` and writes
    the first 8 bytes + metadata to SecureLog. Audit-export
    consumers can cross-reference fingerprints between devices to
    verify that both ends of a cold ceremony observed the same
    party set. State is wiped on every `startAsInitiator` /
    `startAsCosigner` entry.
  iOS build green on arm64 simulator. No behaviour change on happy
  path — only hostile / bug paths observe the new rejections.

- **Audit P0 round 14** — C1 iOS call-site migration to
  `handleAuthenticatedMessage`. The core-side rejection (round 1)
  only fires if call-sites actually pass the channel-authenticated
  party index; round 14 completes the circuit across all five
  signing / DKG / refresh / cold-signing surfaces.
  - Online signing (`SigningViewModel`): resolves
    `authenticatedFrom` from the per-session
    `peerPartyIndex[peer.id]` map populated by `SignPresenceDTO`
    harvesting; rejects unknown-peer and party-mismatch before
    dispatch.
  - DKG (`CreateShardViewModel`): builds a deterministic
    `dkgPeerPartyIndex` during `autoAssignPartyIndex()`
    (sorted-identity → 1-based index) and enforces the same
    two-stage check in the round-loop handler.
  - Refresh (`RefreshShardCoordinator`): TOFU-per-session — first
    inbound `fromParty` from each peer is frozen; subsequent
    divergence or self-impersonation is rejected. Stronger binding
    (explicit peer-registry) is tracked as a separate hardening
    pass since refresh lacks an explicit roster.
  - Cold signing v1 (`ColdSigningCoordinator`): 2-of-2 only —
    counterparty index is unambiguous (`3 - wallet.partyIndex`
    for initiator, `i.initiatorParty` for cosigner); every
    `handleAuthenticatedMessage` call binds to this
    pre-established expectation. QR-scan visual hand-off is the
    channel authentication.
  - Cold signing v2 (`ColdSigningCoordinatorV2`): t-of-n
    star-topology — rejects `msg.fromParty == myIndex`
    (self-impersonation), then binds
    `authenticatedFrom = msg.fromParty`. Stronger cross-QR
    binding (scan-session fingerprint tracking) tracked as a v2
    follow-up.
  All five remaining audit findings (C1 iOS, C4 SignBegin,
  H4 cert-pin, H8 EIP-712) are now closed; internal audit matrix
  is fully green.

- **Audit P0 round 13** — H8 EIP-712 domain separator validation.
  No EIP-712 code path existed at audit time, but to prevent a
  future integrator from skipping domain binding, added a
  sanctioned validation-first entry point
  `chain::evm::eip712_digest(&Eip712Domain, [u8;32]) ->
  Result<[u8;32], ChainError>` that hard-fails on `chain_id == 0`
  (cross-chain replay), `verifying_contract == 0x0`
  (cross-contract replay), and empty `name` (cross-dApp replay).
  Hard-coded `EIP712Domain` type-hash string to defeat typo-
  induced malleability. Exposed via FFI as `horcrux_eip712_digest`
  with `FfiEip712Domain` record. Six unit tests cover rejection
  paths + chain-id/contract/struct binding properties +
  determinism. Before any iOS wiring, the UI must display decoded
  `name / version / chainId / verifyingContract` and obtain
  explicit user consent — the Rust layer only enforces the
  cryptographic binding.

- **Audit P0 round 12** — C4 EVM signing second gate. After
  `buildSignHash()` returns `messageHash` in
  `SigningViewModel.startSigning`, the view model now recomputes
  `keccak256(pendingEvmRawData)` and asserts equality before
  handing the hash to the MPC ceremony. Closes the gap between
  round 4's decoder/consent UI (first gate) and the actual bytes
  fed into `bridge.startSigning`: by collision resistance, a
  matching digest cryptographically binds what the signer signs
  to what the UI decoded and displayed. On mismatch the signing
  throws `SigningError.sighashMismatch` surfaced to the user as
  "Transaction payload changed between approval and signing —
  signing aborted for your safety". Scope is EVM-only (the chain
  where blind-signing risk from `data`-field misrepresentation is
  the stated C4 concern); BTC / Solana / Tron cold-signing flows
  have their own sighash derivations and separate review paths.

- **Audit P0 round 11** — iOS H4 cert-pin rotation. Split
  `CertificatePinner` pinning policy into known vs TOFU hosts.
  `registerKnownPins()` now freezes a `knownHosts: Set<String>`
  at init; `validate()` HARD-FAILS when a known host's SPKI chain
  is disjoint from stored pins (previously re-pinned silently,
  defeating the entire pinning guarantee). TOFU hosts
  (user-configured endpoints) still auto-rotate with a warning
  since the user explicitly chose the URL. Dual-pin structure
  (leaf CA + backup root CA) was already in place per host;
  file-level doc block now spells out the operational rotation
  process (obtain next-gen SPKI, add as backup, ship, promote
  after rotation day). Verified via `xcodebuild` arm64 sim.

- **Audit P0 round 10** — iOS batch: M7 / M9 / H5 / M6+M10 verified.
  First iOS-side round (rounds 1-9 were Rust/infra). Verified via
  `xcodebuild` against an arm64 simulator; pre-existing target
  membership bug for `DecodedCallView.swift` (dangling from round 4)
  fixed by registering the file in `Horcrux.xcodeproj`.
  - **M7** (medium) — Deep-link handlers (`joinSession`) require no
    confirmation. `DeepLinkRouter` now routes `joinSession` URLs
    into a new `pendingConfirmation` slot instead of activating
    them. `HorcruxApp` shows a two-button alert ("Cancel" /
    "Continue") whose message warns the user that an external link
    is trying to open a signing / DKG ceremony. Only
    `confirmPending()` promotes the link to `pendingLink`.
    Read-only deep links (`transactionDetail`, `receive`)
    still auto-activate since they can't trigger MPC work.
  - **M9** (medium) — Clipboard 60 s auto-clear unreliable when
    app backgrounds. `CopyFeedback.copy` — the app-wide copy entry
    point — now delegates to `SecureClipboard.copy`, giving every
    call site the OS-level `UIPasteboard.expirationDate` auto-clear
    (60 s default). Three remaining direct
    `UIPasteboard.general.string = …` sites (audit-export JSON,
    per-chain RPC URL copy, signing recipient-address copy) were
    routed through `SecureClipboard.copy`. Because expiration is
    enforced by the pasteboard daemon, auto-clear survives app
    backgrounding — unlike a GCD / Timer approach.
  - **H5** (high) — Keychain ACL not uniformly passcode-gated.
    `AppState.setPin`, `changePin` (new-PIN write path), and
    `persistFailedAttempts` now route through
    `KeychainManager.storeSecure` — passcode-gated ACL via
    `SecAccessControlCreateWithFlags(kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, [])`
    with the existing no-passcode fallback
    (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`). Existing
    installs migrate opportunistically on the next successful
    `verifyPin` by re-storing the hash through `storeSecure`. The
    only Keychain entries still on plain `.store` are user config
    (relay URL, RPC endpoints) — intentional, not security-critical.
  - **M6** (medium — verified already closed) Screenshot /
    screen-recording blur on sensitive screens. `HorcruxApp.swift`
    already applies `.blur(radius: 30)` on
    `UIApplication.willResignActiveNotification` and clears on
    `didBecomeActive`, with an accessibility label swap.
  - **M10** (medium — verified complete, no changes needed)
    `PrivacyInfo.xcprivacy` manifest. Swift tree scan confirms only
    `NSPrivacyAccessedAPICategoryUserDefaults` / `CA92.1` applies.
    No uses of file-timestamp, system-uptime, disk-space, or
    active-keyboard Required-Reason APIs; no third-party SPM /
    CocoaPods dependencies.

- **Audit P0 round 9** — M4/M8 secret-type hygiene + BTC fee-rate unit safety.
  - **M4** (medium) — MPC structs derive `Debug` could leak secret material
    into logs. `MpcMessage`, `KeygenResult`, `Round2Share`,
    `FrostShardData`, and `EcdsaShardData` now derive
    `Zeroize` + `ZeroizeOnDrop` and have a hand-written `Debug` that
    prints `<redacted: N bytes>` in place of any secret payload while
    still showing benign metadata (party indices, session ids,
    serializable pubkey packages). Non-secret fields are marked
    `#[zeroize(skip)]`. The two FFI `From` impls that consumed these
    structs by field move (`FfiMpcMessage`, `FfiKeygenResult`) were
    updated to use `std::mem::take` so the owned buffers escape the
    `Drop` cycle into the C ABI without a copy.
  - **M8** (medium) — BTC fee-rate unit confusion. Added
    `chain::bitcoin::SatPerVbyte` newtype with `new`,
    `from_sat_per_kvbyte` (rounds up via `u64::div_ceil` so we never
    underpay), `from_sat_per_byte`, and `as_sat_per_vbyte` /
    `as_sat_per_kvbyte` accessors plus `Display` (`"42 sat/vB"`).
    Currently no API surface consumes it — adopted proactively so any
    future fee-rate parameter lands as a unit-encoded type rather
    than a bare `u64`. 4 unit tests cover construction, kvB rounding,
    Display, and `u64::MAX` saturation on conversion.

- **Audit P0 round 1** (internal audit `docs/security-audit-2026-04.md`).
  - **C1** (critical) — MPC sender identity binding. Added
    `HorcruxSessionManager::handle_authenticated_message(msg, authenticated_from)`
    which rejects messages whose claimed `from_party` does not match the
    transport-authenticated peer's party index. Closes the rogue-party
    impersonation window where peer `i` could forge messages claiming
    `from: j` within the same ceremony. The legacy `handle_message` entry
    point is retained but marked `@available(*, deprecated)` in Swift and
    documented as unsafe for production use in both Rust and FFI.
    Callsite migration (iOS `SigningViewModel`, `CreateShardViewModel`,
    `RefreshShardCoordinator`, `ColdSigningCoordinator*`) tracked as a
    follow-up — requires the peer registry to plumb the Noise-authenticated
    party index through to each MPC handler invocation.
  - **C4** (critical) — EVM calldata decoder + cosigner approval-sheet
    integration. `chain::evm::decode_evm_calldata` +
    `horcrux_decode_evm_calldata` FFI export recognise
    `transfer(address,uint256)`,
    `transferFrom(address,address,uint256)`, `approve(address,uint256)`,
    and `setApprovalForAll(address,bool)`, flagging unlimited approvals
    (`is_unlimited` set when the uint256 has bit 255 set). Unknown
    selectors surface as `DecodedCall::Unknown`. iOS:
    `SignRequestDTO` now carries an optional `dataHex` so the initiator
    commits its intended calldata at invite-time; the cosigner's
    `JoinSigningView` decodes it via a new `DecodedCallView` that
    renders the contract call as human-readable intent and hard-blocks
    the Approve button behind an explicit-consent toggle for
    `erc20Approve(isUnlimited: true)` and `setApprovalForAll(true)`.
    The consent toggle is reset on every fresh DTO so a dismissed
    warning cannot carry over between requests.
  - **H2** (high) — DoS hardening in `HorcruxConfig::new`. Reject
    `total_parties == 0` and `total_parties > 20` (`MAX_TOTAL_PARTIES`)
    before any allocation. CGGMP21 / FROST costs scale super-linearly;
    unbounded `n` would let a malicious peer pin CPU and exhaust memory
    on every device that accepts the config.
  - **H3** (high) — verified all production-path
    `serde_json::from_slice` calls across `horcrux-core/src/mpc/*.rs` use
    `.map_err(…)?` rather than `.unwrap()` / `.expect()`. Test-only
    `.unwrap()`s gated by `#[cfg(test)]` left as-is.
  - **C2** (critical) — PIN zeroization. `SecureKeyVault` gained a
    byte-oriented API (`provision(pinBytes:)`, `unwrapWithPin(pinBytes:)`,
    `rewrapPinWrapped(swk:newPinBytes:)`) that lets callers own PIN
    lifetime and wipe the buffer with `memset_s` via the new
    `SecureKeyVault.zeroize(_:)` helpers. `AppState.setPin` /
    `verifyPin` / `changePin` and `SecurityDetailView` backup flow
    migrated; each wraps the PIN in a local `[UInt8]` and `defer`s a
    zeroize. The String-based entry points remain as
    `@available(*, deprecated)` shims for source compat; full
    mitigation still requires the SwiftUI PIN field to hand the byte
    buffer down directly (tracked as a follow-up — Swift `String` is
    copy-on-write and cannot be reliably zeroed).
  - **C3** (critical) — legacy v1 PIN-wrap cleanup. A successful v2
    unwrap now proactively deletes any lingering v1 blob so the 100k
    PBKDF2 offline-attack surface closes the moment the user unlocks
    once under v2. Previously a partial-migration edge case (v2
    stored, v1 delete failed) could leave the weak blob on-device
    indefinitely.
  - **C5** (critical) — Solana `recent_blockhash` freshness enforced at
    sign time. New `SolanaBlockhashMode::Recent { fetched_at_unix_ms,
    now_unix_ms }` vs `DurableNonce` in `chain::solana` makes the
    replay-protection source explicit; `SolanaTransactionBuilder::build`
    rejects with `ChainError::BlockhashExpired` when the blockhash is
    older than `MAX_BLOCKHASH_AGE_MS` (90 s). `DurableNonce` mode opts
    out of the freshness check (caller is responsible for nonce-account
    state). Legacy callers that pass `blockhash_mode = None` still
    succeed but log a warning so the fallback path is telemetered.
    `FfiSolanaTxParams` gains `blockhash_fetched_at_unix_ms`,
    `now_unix_ms`, `durable_nonce` so iOS can plumb the RPC fetch
    timestamp through to the signing core.
  - **H9** (high) — Bitcoin UTXO provenance verification. `BtcInput`
    gains an optional `prev_tx_raw: Vec<u8>` field; when supplied,
    `BtcTransactionBuilder::build` re-derives the txid via double-SHA256
    of the non-witness serialization and confirms both the claimed txid
    and the vout's value match the raw prev-tx bytes. Closes the
    SegWit "trusted-amount" footgun where a malicious PSBT producer
    lies about the input value to donate the difference as miner fee.
    New `verify_utxo_provenance` helper is also exposed for eager PSBT
    import-time validation. Legacy inputs without `prev_tx_raw` still
    build but log a telemetered warning.
  - **H10** (high) — EVM checked fee / value arithmetic. New
    `chain::evm::max_total_cost_wei` helper computes
    `gas_limit * max_fee_per_gas + value` with `checked_mul` /
    `checked_add`, returning `ChainError::ArithmeticOverflow` on
    overflow. `EvmTransactionBuilder::build` calls it as a pre-sign
    guardrail and additionally rejects transactions where
    `max_priority_fee_per_gas > max_fee_per_gas` per EIP-1559.
- **Audit P0 round 6** — P2 Rust/infra batch.
  - **M1** (medium) — Relay admin endpoint IP allowlist. New
    `RelayConfig::admin_allowed_ips` (env `RELAY_ADMIN_ALLOWED_IPS`,
    comma-separated IPs) gates `/metrics` and `/admin/rooms` behind an
    L4 peer-address check in addition to the existing `x-admin-token`.
    The allowlist is intentionally evaluated against the TCP peer —
    not `X-Forwarded-For` — because any downstream client can forge
    the latter; operators behind a reverse proxy must allowlist the
    proxy's loopback or scope admin to bastions that speak directly
    to the relay. Fails closed when the allowlist is configured but
    `ConnectInfo` is unavailable.
  - **M2** (medium) — Room TTL now uses a monotonic clock.
    `horcrux-relay` previously anchored `Room.last_activity_ms` to
    `SystemTime::now()` (unix wall-clock), which is susceptible to
    NTP slews and operator clock adjustments. A new
    `monotonic_now_ms()` helper anchored on a process-local
    `Instant` epoch replaces both the constructor's initial stamp
    and every `touch()` / `is_expired()` read, so TTL eviction is
    robust against wall-clock movement.
  - **H7** (high) — Relay broadcast buffer is now configurable.
    New `RelayConfig::broadcast_buffer` (env
    `RELAY_BROADCAST_BUFFER`, default 1024, clamped `[64, 65536]`)
    replaces the previous hard-coded 256 for the per-room
    `tokio::sync::broadcast` channel. The prior value risked
    `Lagged` drops on large ceremonies with slow peers; the larger
    default plus tunability lets operators trade RSS for fan-out
    headroom per deployment.
  - **L1** (low) — RNG hygiene unification. Every `rand::thread_rng()`
    callsite in `horcrux-core` (`mpc::signing`, `mpc::keygen`,
    `shard::crypto`, `transport::e2e`) now uses `rand::rngs::OsRng`
    directly. `thread_rng` is already seeded from `OsRng` and
    cryptographically secure, but auditors previously had to verify
    that fact every time it appeared; the unification removes the
    whole class of "is this the right RNG?" questions from review.
- **Audit P0 round 7** — P2 supply-chain + concurrency batch.
  - **M3** (medium) — Paillier prime-pool filename collision. Two
    background producers calling `mpc::prime_pool::generate_one()`
    on the same wall-clock nanosecond previously collided on the
    `tmp` filename, risking clobbered writes. Nonce now combines
    the nanosecond timestamp with a 64-bit `OsRng` salt so
    collisions are cryptographically unlikely; the atomic
    `tmp → final` rename remains so partially-written files are
    never observed by `try_take`.
  - **L3** (low) — `Dockerfile` builder stage now runs as a
    non-root user (`builder`, uid 1000). Eliminates the
    malicious-build-script-as-root surface inside the build
    container; runtime image was already non-root. No build
    artefact change.
  - **L4** (low) — GitHub Actions workflows pinned to commit SHAs
    instead of mutable `@v3` / `@v4` tags. Each `uses:` line in
    `.github/workflows/{ci,relay-image}.yml` now references a
    SHA-pinned action with a trailing `# vN` comment for human
    readability. Closes the supply-chain window where a maintainer
    of a dependent action could ship a malicious release under an
    existing tag.
- **Audit P0 round 8** — P2 error-hygiene batch.
  - **M5** (medium) — FFI error sanitizer. New `sanitize_ffi_msg()`
    helper sits at every `From<…> for HorcruxError|ChainError`
    conversion: emits the full original message via
    `tracing::error!` (operators keep diagnostic detail), then
    strips control bytes / newlines, truncates to 256 chars, and
    redacts contiguous hex runs ≥ 64 chars before crossing into
    Swift. Closes the leak class where transient cipher-suite
    strings, library version stubs, or accidental key / digest
    bytes could surface in a UI toast. Four unit tests cover the
    pass-through, control-byte, truncation, and hex-redaction
    paths.
  - **L2** (low) — Three production sites in `mpc::keygen` +
    `mpc::ecdsa` that previously embedded party indices in
    `MpcError::ProtocolError` strings now log the index via
    `tracing::warn!` and return a generic message — party
    identifiers no longer cross the FFI boundary in error text.

### Added

- `docker-compose.yml` + `Caddyfile` at the repo root for turnkey
  self-host deployment with automatic Let's Encrypt TLS.
- `.github/workflows/relay-image.yml` publishing multi-arch
  (`linux/amd64` + `linux/arm64`) relay container images to
  `ghcr.io/horcrux-lab/horcrux-relay` on every push to `main` and on
  release tags, with SLSA provenance + SBOM attestations.
- `docs/push-notifications.md` design document describing the planned
  APNs wake-up architecture (Option B — separate Horcrux-Labs push
  gateway, self-hosted relays remain first-class). Implementation
  deferred to 0.5.1, post-audit.
- `docs/security-audit-2026-04.md` — internal pre-external-audit review
  (5 CRITICAL, 10 HIGH, 10 MEDIUM, 4 LOW, verification legend, three-tier
  remediation plan).

### Changed

- `Dockerfile` Rust base image bumped from `1.78` → `1.80` to match
  the workspace `rust-version`. `curl` added to the runtime image so
  the `HEALTHCHECK` directive actually works.

## [0.5.0-rc.1] - 2026-04-23

Pre-audit release candidate. Consolidates everything shipped between
`v0.3.0` and the `v0.5.0-dev.1` … `v0.5.0-dev.6` tag series, plus two
phases of engineering-quality and security hardening done on top of
`dev.6` to make the codebase audit-ready.

Individual `v0.4.x` and `v0.5.0-dev.x` git tags are preserved for
granular history, but changelog entries below are consolidated.

### Added

- **Vault Mode** (institutional display) — Settings-configurable layout
  rendering wallets as institutional vaults (square badge + vault code +
  env tag + health meta), with optional "hide balances by default" and
  per-vault USD in the header. Individual users keep the default
  Standard layout. (`v0.5.0-dev.1` … `dev.3`)
- **Per-vault metadata** — name, notes, role tag (Treasury / Hot / Cold
  / Operating / Personal) rendered as chip + subtitle in both Standard
  and Vault group headers, editable from "Edit Vault Info". (`dev.3`)
- **Approval Queue** — new "Approvals" tab (checkmark.seal icon) with
  pending / stale / recent sections, badge count, and a tap-to-open
  detail sheet with full tx metadata. `ApprovalRequestStore` persists
  decisions to Documents JSON with 24h pending TTL + 180-day retention
  sweep. JoinSigningView now offers "Save for later" alongside
  Approve / Reject; pending rows show "Resume signing" that reroutes
  the cosigner back into `JoinSigningView` via DeepLink. (`dev.4`, `dev.5`)
- **Audit Log export** — Settings → Diagnostics → Export Audit Log.
  Two share-sheet cards (Transactions, Approvals) each with CSV +
  JSON. CSV is RFC-4180-quoted UTF-8 BOM; JSON is pretty-printed with
  sorted keys + ISO-8601 dates matching the on-disk schema so auditors
  can diff raw stores. (`dev.6`)
- **Testnet badges** — amber "flask" capsule on wallet list rows, chain
  detail hero, and Portfolio Breakdown rows when the current network is
  testnet (Ethereum Sepolia, BTC/LTC testnet, Solana Devnet, TRON
  Shasta/Nile). (`dev.5`, `dev.6`)
- **Post-broadcast balance refresh** — force-refresh sender native
  balance (+ selected token) immediately and again at 12s after every
  successful broadcast on all chains. (`dev.5`)
- **Paid RPC providers** — added Tenderly Gateway, 1RPC, GetBlock to
  the EVM/Solana picker; one-tap preset chips for Tron
  (TronGrid / TronStack / Shasta / Nile) and BTC/LTC (Esplora
  mainnet/testnet). Infura / Alchemy API keys now share across
  EVM + Solana. (`v0.4.x`)

### Changed

- **Portfolio metrics unified** across Standard + Vault banners
  (sparkline + 24h), extracted into a reusable `PortfolioMetrics`
  component. (Phase 1b)
- **Transaction History** distinguishes incoming vs outgoing records:
  "Send SYMBOL" / "Receive SYMBOL" labels, signed amounts with green
  tint on incoming, flipped counterparty arrow. (`dev.5`)
- **Compose flow** prefetches balance on screen open (not on amount
  entry); shows current-asset balance inline on the transfer screen.
  (`v0.4.x`)
- **Settings layout** — lifted API keys to the top section, merged
  status badges, collapsed advanced fields; chain picker on its own
  row; import/export moved to a sub-screen. (`v0.4.x`)
- **Wallet header avatar** (plan F) — when the user hasn't picked an
  emoji, the fallback renders the MPC threshold as a typographic
  fraction (e.g. `2⁄3` via U+2044). The separate threshold capsule is
  removed, folded into the name's accessibility label. Earlier header
  experiments (plans D/E) were reverted. (`v0.4.2` … `v0.4.5`)

### Fixed

- **Signing — control-plane DTO decode noise** (`dev.6`): MPC receive
  loop was decoding every relay payload as `MpcMessageDTO`, turning
  normal control-plane re-broadcasts (`SignRequestDTO`,
  `SignBeginDTO`, `SignPresenceDTO`, `RoomPresenceDTO`,
  `SessionBeginDTO`) into decode errors that ate the
  `decodingFailures` budget and spuriously tripped "Protocol
  communication failure". Ported the `MagicPeek` filter from the
  DKG loop — 5 control magics (`HSP-v1`, `HSG-v1`, `HSQ-v1`,
  `HRP-v1`, `HSB-v1`) now silently bypass the `MpcMessageDTO` path.
- **Signing — cosigner FROST round stalls** — closed a subscription
  race where `signingTask` subscribed to `mpcStream` *after*
  broadcasting `SignBeginDTO`, so the first round-0 messages were
  dropped by `yielding to 0 subscriber(s)`. Subscription now happens
  at the top of the task before any broadcast. (`v0.4.x`)
- **Signing — duplicate tasks + iterator eviction** on cosigner, LAN
  peer id mapping for inbound-stub presence, `SignBeginDTO`
  participant list source of truth. (`v0.4.x`)
- **Approvals — reactive tab badge**, clean resume path (dismiss-first,
  per-code sheet identity, `prefillJoinCode` cleared on dismiss),
  auto-resolve on MPC complete, wipe on factory reset. (`dev.5`)
- **RPC / pinning** — poller uses fallbacks; stale SPKI pins
  auto-rotate; gas-estimation failures surface with retry in the EVM
  flow; fee preview shown when wallet has zero native balance.
  (`v0.4.x`)
- **Localization** — `SecureKeyVault` error messages localized;
  chain-aware token empty-state copy; Vault Mode + Portfolio Breakdown
  strings (zh / en); dropped "US$" prefix from USD amounts (pinned
  `en_US` locale). (`v0.4.x`)

### Security

- **PBKDF2 iteration bump** — iOS `SecureKeyVault` PIN-wrap
  key-stretching moved from 100 000 → **600 000** iterations per
  OWASP 2023 guidance. Legacy `swk.pin.v1` keychain blobs are silently
  re-wrapped as `swk.pin.v2` on first successful unlock and the v1
  entry deleted; migration failure leaves v1 intact so the next unlock
  retries. (Phase 2a — `81ccfe5`)
- **FFI doc correctness** — `horcrux_encrypt_shard` /
  `horcrux_decrypt_shard` doc comments now accurately state that the
  `pin` parameter carries the SWK (not the user's numeric PIN) on iOS,
  and that the KDF is HKDF-SHA256, not PBKDF2. The ABI name is
  preserved for UniFFI Swift-binding compatibility. (`81ccfe5`)
- **Auditor-ready docs** — new top-level `SECURITY.md` (disclosure
  policy, scope, safe-harbor language, response SLAs); new
  `docs/code-tour.md` (17 FFI entry points mapped, trust boundaries,
  Mermaid keygen/signing state-machine diagram, first-hour reading
  order); refreshed `docs/security-model.md` Layer 3 diagram to show
  the real SWK + SE + PBKDF2 architecture. (Phase 2b — `a61c1e3`)
- **RUSTSEC-2025-0127 (cggmp21 presignature misuse)** — added to the
  CI `cargo audit` ignore list with explicit rationale: both exploit
  paths require calling `Presignature::set_derivation_path` or
  `Presignature::issue_partial_signature` with hash-only inputs; our
  signing flow never instantiates presignatures. (`3acb043`)

### Engineering Quality

- **CI green-up** — fmt + Clippy + cargo-audit + iOS xbuild +
  tarpaulin coverage + release build all stable on macOS / Linux
  runners. Independent Clippy gate (`if: ${{ !cancelled() }}`) so a
  fmt blip no longer hides lint regressions. (Phase 1a)
- **iOS test coverage** — 60 new unit tests covering
  `PortfolioMetrics`, `RelayConfig`, `AddressFormatter`, and
  `NodeErrorMapper`. `PortfolioMetrics` extracted out of
  `WalletHomeView` for testability. (Phase 1b — `44457be`)
- **Relay end-to-end test** — `horcrux-relay/tests/dkg_end_to_end.rs`
  runs a 2-party FROST Ed25519 DKG over a real in-process relay bound
  to `127.0.0.1:0`. (Phase 1c — `3157523`)
- **Codecov gate** — `codecov.yml` with project threshold 2% / patch
  target 70% (5% informational), `only_pulls: true` to suppress noise
  on `main`, `third_party/` + `target/` + `tests/` + `build.rs`
  ignored. Badge added to `README.md`. (Phase 1d — `110dae8`)
- **Security tests** — 6 new `SecureKeyVaultTests` covering provision
  / unwrap roundtrip, wrong-PIN failure, not-provisioned, rewrap with
  new PIN, wipe, and the v1 → v2 PBKDF2-iteration migration path using
  a test-only legacy-blob fixture. (Phase 2a)

### Known Limitations

- **Formal audit**: not yet started. This is the release candidate
  *for* audit, not a post-audit build.
- **Reproducible build** manifest is published for this RC (see
  `docs/reproducible-build.md`) but has only been verified on macOS
  hosts. Linux cross-build parity is on the post-audit roadmap.
- **Approval-queue resume** requires live co-signers on the same
  relay session; stashed DTOs cannot reactivate offline.
- **CGGMP21 key_refresh** still limited to 2-of-2 wallets; N-of-M
  refresh is tracked on the 0.5.x roadmap.



## [0.3.0] - 2026-04-21

First stable release of the Horcrux MPC wallet. Consolidates everything
shipped across `dev.1`–`dev.101` since `0.2.0`: the full P0/P1/P3
product roadmap, the 15-item Tier 1/2/3 product polish batch, and
dozens of multi-device cosigning bug fixes.

Detailed per-dev-build notes are preserved below this section.

### Highlights

- **Threshold MPC signing** — 2-of-3 default with CGGMP21 (secp256k1 ECDSA) + FROST (ed25519) across EVM / BTC / LTC / SOL / TRX.
- **Key recovery** — import any valid shard → match `groupPublicKey` → restore the wallet from remaining co-signers.
- **Built-in relay** — zero-config DKG / signing over `wss://relay.horcrux.app`; fully self-hostable via `horcrux-relay`.
- **Multi-transport** — BLE / Wi-Fi Direct / Wi-Fi LAN / QR / Relay, all wrapped in Noise_XX E2E encryption.
- **Multi-chain** — single shard set serves ETH/ERC-20 (USDT/USDC), BTC, LTC, SOL/SPL, TRX via per-curve derivation.
- **Hardware-wallet co-signing** — pair a Ledger as one of the `n` parties.
- **Cold-signing** — 2-of-2 fully air-gapped signing over animated QR fountain codes.
- **Encrypted backup** — AES-256-GCM + Secure Enclave for at-rest shards; encrypted cloud / QR export for disaster recovery.
- **BIP39 3-word room codes** — human-friendly DKG / signing session codes with scanner + paste entry + system share sheet (`horcrux://join?session=…` deep link).
- **Transaction simulation** — decode ERC-20 transfers / calldata + gas preview before signing.
- **Address book + ENS** — resolve `.eth` names; store frequent recipients; picker wired into send sheet.
- **Portfolio UX** — fiat pricing (CoinGecko), sparklines, grouped multi-chain view, collapsible empty wallets, pending-broadcast queue with retry/discard.
- **Hardened settings** — PIN-gated shard deletion, mandatory post-DKG backup gate, auto-lock, biometric unlock.
- **Invite / co-sign flow** — PEP8-tier device identity, ID shortId tagging, presence opt-in gating (no ghost devices in invite list), auto-dismiss on completion, device-name aware last-signed-with shortcuts.

### Breaking Changes

- Relay URL setting moves from hardcoded default to a user-editable field in Settings (was: `ws://localhost:3210`; is now: `wss://relay.horcrux.app`). Existing installs inherit the default.
- Shard encryption envelope revved (AES-GCM-256 + Secure-Enclave-sealed device key); re-enroll PIN on first launch.
- Protocol v2 peer announce now carries `deviceName`; older peers are compatible but render as `iPhone` in the invite list.

### Known Limitations

- Official `wss://relay.horcrux.app` public deployment pending; `horcrux-relay` image in `Dockerfile` is production-ready, operators can self-host now.
- CGGMP21 key_refresh is limited to 2-of-2 wallets in this release; N-of-M refresh is on the 0.3.x roadmap.
- Cosigner UI treats the `lastError` on a pending broadcast as a red pill only; retry UX is on the 0.3.x roadmap.




## [0.3.0-dev.101] - 2026-04-21

### Added

- **iOS (DKG/Signing)**: **房间码系统分享**。房间码卡片和大图弹窗新增 ShareLink，可通过 iMessage / AirDrop / 微信 等渠道一键分享 `horcrux://join?session=CODE` 深链——对方点链接即自动打开 Horcrux 跳转到加入页。分享预览带二维码缩略图，正文包含房间码文本作为后备。DKG 创建流程和签名邀请流程均已覆盖（复用 `RoomCodeShareHelper`）。

### Changed

- **iOS (UI)**: **钱包首页去大标题**，`.navigationTitle("")` + 隐藏 toolbar 背景让 hero 卡片更聚焦。
- **iOS (UI)**: **创建钱包入口从右下 FAB 迁到右上导航栏**（`plus.circle.fill`，紫色主题），与左上的"加入签名"按钮对称。
- **iOS (UI)**: **设备 / 设置 Tab 标题改为 inline**，统一全局 nav 风格。
- **iOS (UI)**: **待广播交易区可折叠**。队列中 ≥2 笔时默认收起为单行蓝色徽章（有错误则带警告三角），点击展开；单笔时保持展开。
- **iOS (UI)**: **房间码大图弹窗 detent 支持 medium/large**，分享按钮放到左上 toolbar 防止被底部裁剪。

### Fixed

- **iOS (UI)**: **加速/丢弃弹窗点击无反应**。根因是 SwiftUI 嵌套 ObservableObject 观察丢失——`AppState.pendingBroadcastQueue` 的 `@Published` 变化不会冒泡到 `@EnvironmentObject appState` 的消费者。在 `AppState.init` 中补上 `pendingBroadcastQueue.objectWillChange → self.objectWillChange` 桥接（镜像原有的 walletStore bridge）。



## [0.3.0-dev.100] - 2026-04-21

### Fixed

- **iOS (Signing)**: **邀请列表"幽灵设备"修复**。`SigningViewModel.joinedSigners` 之前直接从 `connectedPeers` 派生，任何 LAN 邻居或上次房间遗留的 peer 都会显示为"已加入"。现在严格要求 peer 发过带 `partyIndex` 且 `sessionId == roomCode` 的 `SignPresenceDTO`（即对方点过"批准"）才入列，`regenerateRoomCode` / kick / 断连均即时刷新。
- **iOS (Signing)**: **共签方进度环卡在 "第 0/4 轮"**。签名协议双方都完成后，`JoinSigningView` 的 `.signing(vm)` 之前不监听 `viewModel.step`，无法在 `.complete` 时自动关闭。新增 `JoinSigningProgressBridge` 包装层，成功后触发 haptic + 900ms 延迟自动 dismiss。
- **iOS (Signing)**: **签名卡在 round 0**。发起方广播 `SignBeginDTO` 后 sleep 400ms 才订阅 `mpcStream`，共签方第一批 r=0 消息在此窗口内到达即被丢弃（log 显示 `yielding to 0 subscriber(s)`）。现将订阅移到 `signingTask` 顶部，DTO 广播前就已订阅。
- **iOS (Signing)**: **gas 估算缺失时"下一步"按钮被锁死**，`estimateGas` revert 的交易无法进入手动 gas 逃生通道——取消对 `gasEstimate != nil` 的硬性依赖。
- **iOS (Relay)**: **加入者退出房间后再进报错**。`JoinSigningView` dismiss 时未 `leaveRelayRoom`，且重进前没清理老 WebSocket delegate callback，导致陈旧回调污染新连接。现在 sheet dismiss + 重连前都主动 tear down。
- **iOS (DKG)**: **跨房间 presence 串扰**，`RoomPresence` 监听没过滤 `roomCode`。
- **iOS (UI)**: **"我的 ID" 胶囊与别人看到的 shortId 不一致**；`displayName` 现在一律附加 8 位 hex shortId；DeviceList 把 ID 行叠在角色标签之上。


### Changed

- **iOS (UI)**: **设备列表同时显示"设备名"和"ID"两行**，方便用户直观区分。
  - 新增 `DeviceIdentity.split(_:)`：把 `"iPhone-7F3A9B21"` 这类自动生成名切成 `(label: "iPhone", shortId: "7F3A9B21")`；用户自定义昵称（不含 8 位 hex 尾缀）保持原样、`shortId` 为 `nil`。
  - 迁移列表 UI：
    - `CreateShardFlow` 房间内参与方列表（presenceList）+ 传输层发现列表（foundPeers）：主标题显示 `label`，副标题加一行 `ID: 7F3A9B21`（等宽字体）。
    - `SigningView` 邀请阶段已加入共签方列表：同格式，`label` + `ID: …`。
    - `JoinSigningView` 附近可加入的发起人列表：副标题显示 `ID: 7F3A9B21 · Wi-Fi LAN`。
  - 签名进行中的 `CosignerStatusRow` 保持单行紧凑（只显示 label，省略 ID 以留出进度徽标空间）。

## [0.3.0-dev.98] - 2026-04-21

### Fixed

- **iOS (多机协同)**: **设备列表不再显示成一串 "iPhone"**——修复 iOS 16+ 下 `UIDevice.current.name` 的隐私屏蔽导致的参与方身份碰撞。
  - 现象：iOS 16 起，第三方应用读 `UIDevice.current.name` 一律得到通用字符串 `"iPhone"`（Apple 去个性化隐私改动）。Horcrux 之前把它直接当参与方标识用，导致两台真机或三台模拟器在 DKG / 协同签名中：
    - 邀请页 / 已加入共签方 / 设备发现列表全是 `iPhone / iPhone / iPhone`，无法区分；
    - presence 消息过滤 "排除自己" 时也过滤掉了别人；
    - `participantIds.firstIndex(of: "iPhone")` 把两台设备都解析成 party 0，DKG 协议直接错位，后续 FROST 签名无法进行。
  - 修复：新建 `Core/DeviceIdentity.swift`，集中封装：
    - `stableId`：UUID，`UserDefaults` 持久化（key `com.horcrux.deviceId.v1`），首次读取时懒生成；App 重启不变，卸载后重置（模拟器 reinstall 视同新钱包，符合心智模型）。
    - `shortId`：`stableId` 头 8 位 hex 大写，例如 `7F3A9B21`。
    - `displayName`：优先取 Settings 里用户填的 `deviceNickname`；否则用 `"{UIDevice.model}-{shortId}"`（如 `iPhone-7F3A9B21`）——保证同机型两台设备始终可区分。
  - 迁移 19 处 `UIDevice.current.name` 调用到 `DeviceIdentity.displayName`：`CreateShardViewModel`（participant 身份 + presence 过滤 + party 索引）、`SigningViewModel.initiatorDeviceName`、`JoinSigningView`（cosigner presence + SignRequestDTO）、`RelayTransport.localDeviceName`、`WiFiLANTransport.ownServiceName` / Bonjour 服务名、`SettingsView` 昵称输入框 placeholder。
  - 用户可继续在"设置 → 设备昵称"里覆盖默认名；留空则恢复成 `iPhone-XXXXXXXX`。

## [0.3.0-dev.97] - 2026-04-21

### Fixed

- **iOS (Signing)**: **`estimateGas` revert 时的"自定义 gas"逃生通道**。
  - 现象：用 ERC-20（如 USDT）发起转账且发送方链上 token 余额为 0 时，`eth_estimateGas` 被合约 revert（日志里 `RPC error: invalid opcode: INVALID`），`composeBlocker = "无法估算手续费"` 触发"下一步：邀请共签方"按钮 disable；此时即使切 GAS→"自定义"手填 gwei，按钮依然点不动——完全无法进入邀请页，协同签名走不下去。
  - 修复：新增 `SigningViewModel.hasCustomGasOverride`（`feeTier == .custom && customGasPriceGwei > 0`），`SigningView` 的"下一步"按钮 gate 条件改为 `composeBlocker != nil && !hasCustomGasOverride`——有手填 gas 时就放行。离线签名 / 先签后广播 / 合约 probe 余额为 0 这些场景都能继续往下走；无 override 时原行为不变。

## [0.3.0-dev.96] - 2026-04-21

### Added

- **iOS (Tests)**: **单元测试覆盖 dev.91–94 新功能**。
  - 新建 `RecentCoSignersStoreTests`（9 个用例）：覆盖 `record` / `mostRecent` 时间序排序、5 条上限淘汰、按钱包隔离、`forget` 精确移除、`UserDefaults` 持久化往返、空 peerId 被忽略。
  - 扩展 `SigningViewModelTests` 5 个用例：`kickPeer`（黑名单 + 从 `joinedSigners` 同步剔除）、`regenerateRoomCode`（新房号 + 清空 kick list）、`tickRoomCodeExpiry`（未到期/已过期两条分支）、`resignToSameRecipient`（保留收款人/代币，清掉金额/费用/会话）。
  - 顺带修掉两条历史失败：`testStartSigningSetsIsRunning` / `testCancelStopsSigning` 因 `amount` 为空被 guard 提前拦成 `.error`，补 `vm.amount = "0.1"`；取消用例同时接受中英文"取消/cancel"以适配模拟器默认 zh-Hans 语言环境。
  - `SigningViewModel.sessionId` / `kickedPeerIds` / `peerPartyIndex` 由 `private` 放宽为 internal，附注释说明仅为 `@testable` 可见性；无对外 API 变更。
  - 全部 22 个用例通过，为后续 DKG / 签名协同的重构提供回归网。

### Fixed

- **iOS (Tests)**: **修复遗留测试编译失败**，解锁测试目标整体 CI。
  - `ModelTests.swift`：`Wallet(...)` 初始化补 `isHidden: nil`；`XCTAssertEqual(decoded.chain, .bitcoin)` 加 `Chain.` 显式限定（原先推导成 `Equatable` 导致报错）。
  - `WalletStoreTests.swift`：`makeWallet` 辅助工厂补 `isHidden: nil`。
  - `CreateShardViewModelTests.swift`：整体 API 已过期（`selectedChain` / `generatedAddress` / `.ble` 等都已不存在），暂用 `#if false` 包住，留 TODO 等下一轮 DKG UI 迭代时重写，避免阻塞其他测试目标编译。

## [0.3.0-dev.95] - 2026-04-21

### Added

- **iOS (QA)**: **`HORCRUX_SKIP_BIOMETRIC=1` scheme env bypass in DEBUG builds**。
  - 之前在模拟器跑端到端回归时，`LAContext.evaluatePolicy` 会弹出无法真正匹配的 Face ID 对话框，一直压在 PIN 键盘上，签名流程根本走不到。现在 DEBUG 构建检测到该环境变量就直接跳过自动 biometric 提示，落到 PIN 解锁，模拟器 QA 才跑得起来。
  - 仅 `#if DEBUG` 生效，发布构建依然正常走 Face/Touch ID，无安全影响。

### Notes

- **发现**：`ColdSigningView` / `ColdSigningViewV2` 当前在 iOS 工程中没有任何调用方（自 dev.50 起从未接入主签名入口）。冷签名特性代码完整但不可达——建议下一步评审：是否接入 SigningTransportPicker 作为第三种传输模式，或显式移除。

## [0.3.0-dev.94] - 2026-04-20

### Added

- **iOS (Signing)**: **签名完成后一键"再签一笔给同一收款人" + 最近对端长按忘记**。
  - `SigningViewModel.resignToSameRecipient()`：保留 `recipientAddress` + `selectedToken`，清掉 amount / fee / round state / session / 参与方列表，回到 `.compose`。签完立刻还想给同一个地址再打一笔（补齐零头、分批转、测试回路）这种场景过去要重新粘地址、重选代币，现在一键就行。
  - `SigningCompleteView` 在 Done 按钮前加 "再签一笔给同一收款人"；仅当有 `txHash` 且未 broadcasting 时可点。
  - invite 界面 "上次签名对端" 提示条加 `.contextMenu`，长按可 `忘记此设备`（调 `RecentCoSignersStore.forget`）——设备换了/丢了时不会误以为对方还会上线。

## [0.3.0-dev.93] - 2026-04-20

### Added

- **iOS (Signing)**: **"上次签名对端" 记忆 + 房间码复制 toast + 换码时主动释放中继房间**。
  - 新增 `RecentCoSignersStore`（`ios/Horcrux/Core/RecentCoSignersStore.swift`）：按 `(walletId, peer.id)` 维度记录最近 5 位共签人，JSON 存 UserDefaults。签名成功那一刻在 `SigningViewModel` 最终分支里批量写入。
  - invite 界面"没人加入"的空窗期显示小提示：`上次与「某某设备」签名` + 时钟图标，给发起方一个心理对齐目标；一旦真有 peer 加入就让位给 cosigners 列表 + 指纹。
  - 房间码复制按钮现在显示房间码专属 toast（`房间码已复制` / `Room code copied`）而非通用"已复制"，和 dev.91/92 的可换码叙事更连贯。
  - **工程债清理**：`RelayTransport.leaveRoom()` 显式关闭 WebSocket + 清 state；`PeerManager.leaveRelayRoom()` 暴露它；`regenerateRoomCode()` 换新码前先释放旧房间，中继 server 侧可立即回收而不必等空闲 GC。

## [0.3.0-dev.92] - 2026-04-20

### Added

- **iOS (Signing)**: **踢人 + 传输模式标签**。
  - 发起方 invite 界面的已加入 cosigner 行新增小号 `×` 移除按钮，点了会弹确认对话框（"%@ 将从本次签名中移除"），确认后 VM 把该 peer 丢进本地黑名单 `kickedPeerIds`，下一个 `connectedPeers` tick 立刻把人滤掉。和 dev.91 的 `regenerateRoomCode` 组合用：单次仪式内踢出用「移除」，想让同一个 peer 彻底进不来再叠一个「生成新码」（regenerate 会清空黑名单，因为"新码 = 新仪式 = 干净起点"）。注意这是单方面驱逐，被踢方仍在底层房间里（没有带签名的 kick 消息），所以 UI 文案上明确建议配合换码。
  - 传输选择卡片标题行右侧多了个 pill，根据勾选状态显示 `自动（中继 + 局域网）` / `仅中继（跨网络）` / `仅局域网（更私密）`。给默认的"都开"配一个名字，用户一眼知道自己处在哪种模式，不用靠心算两个 checkbox。

## [0.3.0-dev.91] - 2026-04-20

### Added

- **iOS (Signing)**: **房间码 5 分钟 TTL + 倒计时 + 一键重生**。防止截屏里/消息记录里留下的旧房间码被人再次使用，也避免 invite 界面挂一晚上之后还照旧放人进来。新增行为：`prepareInvite` 设置 `roomCodeExpiresAt = now + 5min`；invite 卡片下方持续显示 "有效期剩余 4:32"（mono 倒计时），最后 60 秒起旁边出现小号 "生成新码" 按钮；到期后房间码置灰、announce beacon 立刻停、出现完整重生 CTA。`regenerateRoomCode()` 丢弃旧码、清 `peerPartyIndex`、重新 `joinRelayRoom`——已经按老码进来的 peer 被要求重新加入新码房间，避免"我以为都对齐但其实有人沿用旧码"混用问题。新 L10n 键：`signing.roomCodeExpired` / `roomCodeRegenerate` / `roomCodeValidFor` (zh-Hans + en)。

## [0.3.0-dev.90] - 2026-04-20

### Added

- **iOS (Security UX)**: **钱包指纹对读验证**——共签方的 review 卡新增 4 项信息：钱包昵称、8-char groupPubKey 指纹、付款全地址（chunked）、ERC-20 合约短哈希；发起方的 invite 界面在至少有 1 个共签方加入后也展示**同一指纹**。双方口头对一下这 8 个十六进制字符，就能确认是同一个钱包/同一笔交易，防御"攻击者知道房间码、但想让你用不同钱包/代币签名"的场景。现有 `Wallet.name` 被尊重，没昵称时 fallback 到链名；`AddressFormatter.chunked` 已有，复用即可。新增 L10n：`joinSigning.walletFingerprint` / `fromAddress` / `tokenContract`，`signing.walletFingerprintLabel`（zh-Hans + en）。

## [0.3.0-dev.89] - 2026-04-20

### Fixed

- **iOS**: **`participants` 列表在 party-1 发起 2-of-N 时永远是 `[1, 1, 1, ...]`**——bridge.startSigning 收到的 party 索引全是发起方自己的，导致 MPC 协议根本不认识谁是谁。旧代码：`joinedSigners.prefix(k-1).enumerated().map { UInt16($0.offset + 1) }`，每个共签方都被硬编码成 "1, 2, 3..."，完全忽略对方真实的 partyIndex。现在：共签方在 `approve` 之后再发一轮 `SignPresenceDTO`，携带自身 `partyIndex`；发起方在 `.invite` 阶段订阅 MPC 流抓取 presence ping、建立 `peer.id → partyIndex` 映射；`startSigning` 据此构造正确 sorted+dedup 的 `participants`，未收到 presence 的槽位回退到 "最小未用索引" 兜底（保证老客户端仍能工作，并且两端兜底策略一致不会错位）。扩展 `SignPresenceDTO` 新增 optional `partyIndex: UInt16?` 字段，pre-dev.89 对端忽略不影响兼容性。

### Added

- **iOS**: **"等待共签方加入" 超时引导卡**。30 秒仍未凑齐 threshold 时，spinner 替换为带警告边框的 troubleshooting 卡片，列出 3 条最常见的失败排查项：房间码是否一致、中继是否能访问、是否在同一 Wi-Fi；并根据当前 transport 选择动态显示相应项（未开中继的情况会提示开启）。新增 6 个本地化键 `signing.waitingTroubleshootTitle` / `waitingCheckCode` / `waitingCheckRelay` / `waitingCheckLAN` / `waitingEnableRelayHint`，zh-Hans + en 齐全。计时器在 peer 加入时自动重置。

## [0.3.0-dev.88] - 2026-04-20

### Fixed

- **iOS**: **共签双方 nonce/gas 各算一份，可能导致 sighash 不一致**——即便 MPC 协议跑完，产出的签名对不上 chain，交易直接被拒；若两端参数差异过大 bridge 还可能卡住（疑似 R1 0 responses 的潜在成因）。
  修法：扩展 `SignBeginDTO` 携带一组 `AuthoritativeTxParams`（chainId / nonce / gasLimit / maxFeePerGas / maxPriorityFeePerGas / to / valueWei / dataHex）。初始方在 `bridge.startSigning` 前调用新的 `preresolveTxParams()` 一次性从 RPC 取值 + 记录到 `PendingNonceTracker`，写入 `authoritativeTx` 字段并广播；共签方的 begin-listener 落地为自己的 `authoritativeTx`，`computeMessageHash` EVM 分支优先读共享值，保证两端 hash 同源。向后兼容：cosigner 若收到旧版无 `tx` 字段的 Begin，仍走本地重算路径。

### Added

- **iOS**: **compose 阶段 gas/余额预检**。RPC estimateGas 失败时按错误关键字分类：含 `insufficient funds/balance` → "余额不足，无法支付此笔交易"；其他 → "无法估算手续费"。文案显示在金额块下方警告行，并 disable "下一步" 按钮，避免用户走完 MPC 才知道签名没用。新增 `composeBlocker` published 字段、`signing.insufficientBalance` / `signing.cannotEstimateFee` 本地化。

### Deferred

- **P0-2 initiator-side 附近设备主动邀请**：需要新增 LAN 级邀请协议 + cosigner 端自动弹 JoinSigningView 的路径（类似 `horcrux://join` deep link），属独立 feature，留待 dev.89+。

## [0.3.0-dev.87] - 2026-04-20

### Fixed

- **iOS**: **初始方误丢共签方一半 round-0 消息**。dev.86 新装的 `[signing]` NSLog 把实锤打出来了：
  - 共签方 (party 2) r=0 发两条给初始方：`13559B (from=2, to=1)` + `21695B (from=2, to=2)`；
  - 初始方过滤器 `msg.toParty != myPartyIndex` 把第二条（`to=2`，"不是给我 party 1 的"）直接 skip，bridge 只收到一半输入。
  根因：CMP/GG18 bridge 常用 `toParty == fromParty` 编码"来自 party X 的广播 round output"语义，所有对手方都必须处理，不是字面上的点对点。
  修法：skip 只在 `toParty != 0 && toParty != 我 && toParty != 发送方` 时触发。自广播放行。
- 追加三条 `NSLog [signing]` 诊断（rx / dup-drop / skip-p2p / handleMessage from/to/r / produced N responses），以后查 bridge 行为再也不用摸黑。

## [0.3.0-dev.86] - 2026-04-20

### Fixed

- **iOS**: **签名卡在 R0/4，slow-signing 警告**（dev.84 引入的去重 bug）。日志显示 R1 的 13559B + 21667B 两条 Paillier 消息正常到达对端，但协议不再前进。
  根因：dev.84 我用 `(fromParty, round, toParty)` 三元组去重，目的是过滤 relay + wifi-lan 双传输带来的重复包。但 **CMP/GG18 每轮本身会产多条不同消息**（Paillier commit + proof 分两条走），它们的 `(from, round, to)` 完全一样——被我的 dedup 无差别丢掉，bridge 只拿到一半 round-1 输入，永远产不出 round-2 输出，两端空转直到 slow-signing 告警。
  修法：dedup key 换成**消息字节的 SHA-256**。只有真正 byte-for-byte 重复（多传输 fan-out 的副本）会被丢弃；同轮多条 legit 不同消息照常通过。
- **共签方 UI 仍显示"3/2"**。dev.84 的 name 去重不够：relay 那头拿 UIDevice 名（"iPhone 16"），wifi-lan Bonjour 服务名常被系统附后缀（"iPhone 16 (iPhone)"），字符串不等，过不了 Set 去重。
  现在 `joinedSigners` sink 在比较前先 regex 剥掉末尾 ` (…)` 括号子串，两种命名规范化成同一个 key。

### Technical

- `import CryptoKit` 到 SigningViewModel 以用 `SHA256.hash`，哈希对比保持 Set 有界（32B/entry）而不是存整条消息。
- 名字归一化：`replacingOccurrences(..., options: .regularExpression)` 匹配 `\s*\([^)]*\)\s*$`。

## [0.3.0-dev.85] - 2026-04-20

### Fixed

- **iOS**: **签名卡在 R1/4，共签方列表里对端显示红叉 ❌**。dev.84 加了 per-peer 容错后 bug 从崩溃变成静默卡住。日志里每次 send 都打 `broadcastMpc: skipping peer wifi-lan:iPhone… — Horcrux.FfiE2eError.HandshakeIncomplete`。
  根因：`PeerManager.connect(to:)` 不分传输一律调 `performNoiseHandshake(asInitiator: true)`。对 wifi-lan 来说，本端往对端 NWConnection 写了一个 Noise init 消息，但对端的 inbound 走的是 `handleIncomingMessage` 的 raw 分支（`handleHandshakeMessage` 根本不会被调到），于是握手响应永远到不了，`noiseChannels[peer.id]` 停在半初始化状态；之后 `sendMpcMessage` 看到 noise 条目优先走加密路径，`noise.seal` 抛 `HandshakeIncomplete`。
  修复：`connect(to:)` 只对 ble / wifi-direct 做 Noise 握手；relay / wifi-lan 这两种本地可信传输直接跳过，`sendMpcMessage` 自然落到 raw 分支。

### Technical

- `peerStates[peer.id] == .failed` 的 ❌ 渲染只是表象——underlying 是所有 send 都被 skip 了，接收端没收到任何对己方的 response，也就永远停留在"等待"状态，UI 把对端标红。修好握手即可恢复。

## [0.3.0-dev.84] - 2026-04-20

### Fixed

- **iOS**: **签名失败 "Not connected to peer"** + 共签方显示 "3/2 加入"。dev.83 把 relay 和 wifi-lan 的 `discoveredPeers` 都 mirror 进 `connectedPeers`，但：
  1. wifi-lan 为 NWListener 入站连接注册的 `inbound-<endpointId>` 只是"接收侧 stub"，`WiFiLANTransport.connections` 里没对应条目，发送时直接 `throw .notConnected`——但之前 dev.82 的 raw-path 登记也会把它加进 `connectedPeers`，`broadcastMpcMessage` 一遍历就炸。
  2. 同一台对端会同时出现两次（wifi-lan 出站 + relay），`joinedSigners` 计数直接 ×2（"1 本机 + 2 对端 = 3"）。
  3. FROST 协议消息被 relay 和 wifi-lan 同时投递两次，bridge 判重后 `handleMessage` 抛 "party N tried to overwrite"。
  
  三处修复：
  - **`PeerManager.broadcastMpcMessage`** 改为容错——逐 peer `try`，只有**全部失败**才向上抛；`inbound-*` stub 直接 skip。
  - **`PeerManager.handleIncomingMessage`** 的 dev.82 登记分支跳过 `inbound-*` 前缀，不再把只接收的 stub 塞进 `connectedPeers`。
  - **`SigningViewModel.joinedSigners`** sink 里按 `peer.name` 去重，relay + wifi-lan 同设备只计一次。
  - **`SigningViewModel.runSigningRounds`** 新增 `(fromParty, round, toParty)` 三元组去重 `seenMessages` 集合，多传输 fan-out 的重复包在进 bridge 前丢弃。

### Technical

- 去重 key 选 `peer.name` 而不是构造 deviceId：SignRequestDTO 里已经带了 `initiatorDeviceName`，其他场景 `UIDevice.current.name` 也有值，命名冲突要两台同名 iPhone 才会发生，远期可以换成 DKG 里分发的 partyId。
- `NSLog("[PM] broadcastMpc: skipping peer …")` 方便后续排查单 peer 发送失败。

## [0.3.0-dev.83] - 2026-04-20

### Fixed

- **iOS**: **dev.82 修了一半**——presence ping 那招其实有竞态。共签方 `joinRelayRoom` 之后立刻 `sendPresencePing` 时，自身的 `allPeers` 还没被发起方的 `announce_ack` 填上（WebSocket round-trip 还在路上），`broadcastMpcMessage` 拿到的目标列表为空，ping 就直接丢进虚空了。发起方从未收到任何 inbound → `connectedPeers` 一直空 → joinedSigners = 0 → "开始签名"按钮永不亮。
  真正的修法是去掉 presence ping 这条绕路——对 relay / wifi-lan 这两种没 Noise 的本地传输，**发现 == MPC 可达**，直接把 `discoveredPeers` 镜像到 `connectedPeers` 即可。`PeerManager.setupTransportObservers()` 里新增 `CombineLatest(wifiLAN, relay)` 的 sink：任何新出现的 peer 立刻追加，任何消失的 relay/wifi-lan peer 立刻移除（保留 BLE/wifi-direct 的 Noise 登记不动）。共签方一入房，两端的 invite 页就同时翻到"1 加入"，不用等任何一条 inbound 消息。
- `SignPresenceDTO` 的 ping 现在是多余的（discovery observer 已经覆盖它的职责），但保留不删——它对 QR / BLE 路径仍是轻量的"我到了"信标，删掉没收益。

### Technical

- `PeerManager.connectedPeers` 的语义从此**对 relay/wifi-lan 透明**：一上房就满员，一掉线就清除。BLE/wifi-direct 仍走 Noise 握手才进 connectedPeers，两套机制互不干扰（去重 by peer id）。
- `NSLog("[PM] connectedPeers += …")` 留下来方便下次出问题时 `log show --predicate 'process == "Horcrux"'` 一眼看到拓扑变化。

## [0.3.0-dev.82] - 2026-04-20

### Fixed

- **iOS**: **发起方一直显示"等待共签方加入"，即使共签方已经收到 DTO**（dev.78 以来的隐藏 bug）。根因是 `PeerManager.connectedPeers` 只在 Noise 握手完成时追加（`handleHandshakeMessage`），但 wifi-lan / relay 这两种"可信本地传输"走的是 raw-data 路径，从不触发 Noise，所以即使消息一来一回流通，两端的 `connectedPeers` 都永远是空的，`SigningViewModel.joinedSigners` 也就永远是 0，Start Signing 按钮永不可点。
  修复分两步：
  1. `PeerManager.handleIncomingMessage` 在 wifi-lan / relay 分支里，收到任何一条来自新 peer 的消息时把发送方加进 `connectedPeers`（去重）。从此"能收到消息" == "已连上"，符合本地传输的语义。
  2. 光加第 1 步还不够，因为 announce 信标是发起方单向发给所有人的——共签方默不作声时，发起方那头没 inbound 消息可触发。所以新增 `SignPresenceDTO`（magic `HSP-v1`），共签方在 relay 入房或 LAN 连接成功后立刻 `broadcastMpcMessage` 一发 "I'm here" ping；发起方收到这条 ping 就触发第 1 步的登记，invite 页立刻从"等待共签方加入"变成"1 加入"。

### Technical

- `SignPresenceDTO` 结构只包含 `sessionId`、`deviceName` 两字段 + magic。发起方和其他共签方的 listener 见到非 `HSQ-v1` / `HSG-v1` magic 自然忽略，不影响协议流。
- `JoinSigningView.sendPresencePing(sessionId:)` 在 `joinRoom()`（relay + 房间码路径）和 `connectToNearby(_:)`（LAN 直连路径）两处分别调用，双通道都能让发起方尽快感知到共签方。

## [0.3.0-dev.81] - 2026-04-20

### Fixed

- **iOS**: **共签方批准后卡在 R1/4 无限等**（dev.78 引入的协议排序 bug，在 dev.80 两台模拟器联调时现形）：
  之前共签方在 `JoinSigningView` 点"批准"后立刻 `vm.step = .signing; vm.startSigning()` 本地跑 FROST 第一轮，但发起方此时还在 invite 步骤（等阈值），并没有订阅 MPC 消息流——共签方的 round-1 消息发出去落到空订阅者上被丢掉，之后发起方再点"开始签名"已经晚了，共签方在 3-4 分钟的 slow-signing 警告里干瞪眼，两端都看起来"卡住"。
  现在加了一次握手：
  1. 新增 `SignBeginDTO`（magic `HSG-v1`, 只携带 sessionId），作为发起方"我要开始了"的同步 barrier。
  2. 共签方批准 → `SigningViewModel.awaitInitiatorStart()`：UI 切到 signing 显示"等待发起方开始签名…"，后台订阅 MPC 流专门等 `SignBeginDTO`。
  3. 发起方点"开始签名" → `startSigning()` 先广播 `SignBeginDTO` → 睡 400ms（给共签方时间收包 + 订阅 MPC 流）→ 再调 `bridge.startSigning` 产出 round-1。
  两边在同一个 barrier 之后才进入真正的 FROST 协议，round-1 消息不再丢失。

### Technical

- `SigningViewModel` 新增 `isCosigner` / `beginListenerTask` 私有态；`cancelSigning()` 一并取消 listener；`startSigning()` 进入时也会 cancel listener（避免同一个 VM 上双订阅）。
- `SignBeginDTO` 的 magic 检查 (`HSG-v1`) 防止把 invite 阶段仍在循环广播的 `SignRequestDTO`（`HSQ-v1`）误判为"go"信号——JSON 超集解码能成功，但 magic 字符串不匹配就短路返回。
- 本地化新增 `signing.waitingForInitiator`（中/英）。

## [0.3.0-dev.80] - 2026-04-20

### Added

- **iOS**: **发起交易时可选择传输方式**（dev.79 的 UX 补完）。邀请步骤的房间码卡片上方新增"传输方式"选择器，两档开关：
  - **中继服务器**：默认开。走 relay room + 三词房间码，供远程共签方使用。关掉后整个仪式不上中继（隐私模式），房间码卡片同步隐藏。
  - **同一 Wi-Fi**：默认开。走 Bonjour `_horcrux._tcp`，同一局域网内的共签方直接点设备名加入，省口令、不经服务器。
  至少保留一个——两个都关会被防御性地重新勾上 relay。用户切换开关会实时触发 `prepareInvite()`，LAN 发现和 relay 入房会按当前集合启动/停止。

## [0.3.0-dev.79] - 2026-04-20

### Added

- **iOS**: **加入签名的三种新姿势**（dev.78 的补完，把签名从"只能手输房间码"扩展成"扫码 / 点链接 / 浏览局域网"）：
  1. **扫描二维码加入**：`JoinSigningView` 输入框旁新增 "qrcode.viewfinder" 按钮，打开 `QRScannerView`。识别两种载荷：
     - `horcrux-room:<code>`（`SigningRoomCodeQR` 已生成的格式，复用 `InviteSignersView` 里展示的那张 QR）；
     - `horcrux://join?session=<code>` 深链格式。
     扫描成功 → 房间码自动填充 → 自动触发"加入房间"。
  2. **深链一键加入**：`HorcruxApp.onOpenURL` → `DeepLinkRouter.parseURL` → `.joinSession(sessionId:)` 已有链路，现在 `WalletHomeView` 监听 `deepLinkRouter.pendingLink`，收到 `joinSession` 时自动弹 `JoinSigningView(prefilledCode:)`，用户点一次链接就能进到交易审阅步骤。支持 iMessage / 微信 / 邮件转发 `horcrux://join?session=ABC-DEF-GHI` 链接。
  3. **局域网直连（Wi-Fi LAN，免中继免房间码）**：
     - 发起方 `SigningViewModel.prepareInvite()` 除了入 relay room，也调用 `peerManager.wifiLAN.startDiscovery()`，通过 Bonjour `_horcrux._tcp` 在本地网络广播自己。
     - 共签方 `JoinSigningView` onAppear 同样启动 LAN 发现；输入框下方新增 "同一局域网内的设备" 区域，显示发起方设备名 + "Wi-Fi LAN" 徽标。
     - 点击设备 → `peerManager.connect(to:)` 走 Noise 握手 → 进入 `.waiting` 状态 → 收到 `SignRequestDTO` beacon → 同样的审阅卡 → 授权签名。
     - MPC 消息收发层 (`broadcastMpcMessage`) transport-agnostic：无论 relay / LAN / BLE，已连接的 peer 都会收到包。初始化方同时在 relay 和 LAN 上广播，两边任选其一即可。
     - 安全性：LAN 直连跳过房间码口令，但 `SigningProgressView` 前必须通过**审阅卡 + PIN 解锁**两道闸门，且对方的设备名 + 交易详情都会展示供用户核对；BonjourFake 的攻击者无法伪造一个与你本地钱包 `groupPublicKey` 匹配的 DTO。

### Technical

- `JoinSigningView.startListening` 增加 `expectedCode: String?` 参数。输入房间码走严格匹配（防止串扰），LAN 直连走 nil（信任用户已通过设备名人眼核对 + 审阅卡）。
- 复用已有 `SignRequestDTO` magic `HSQ-v1`，无协议变更，新老设备混用兼容。
- `SigningViewModel.prepareInvite()` 现在同时打开 `wifiLAN` 发现以做到同时可达 relay + LAN，两条路并行；断开只停 browsing，已建立连接继续存活到签名结束。
- 扫描路径解析由 `handleScannedPayload` 统一处理，支持 `horcrux-room:` 前缀 + `horcrux://sign?session=` / `horcrux://join?session=` 两种 URL host。

### Known limitations (unchanged from dev.78)

- `SigningViewModel.startSigning()` participant-index 仍用 offset-based 伪索引，3-of-3+ 需要后续协议把 partyIndex 声明出来。
- cosigner 仍各自从本地 RPC 取 nonce / gas——下一版把 initiator 侧完整 unsigned tx 塞进 `SignRequestDTO` 彻底消除不一致风险。

## [0.3.0-dev.78] - 2026-04-20

### Added

- **iOS**: **共签方加入签名会话**完整闭环（dev.77 只补了发起方；本版把 cosigner 那一侧也建好）。新增 `JoinSigningView`，入口在钱包首页顶栏左上角的 "person.badge.key.fill" 图标。流程：
  1. 输入 / 粘贴发起方的三词房间码（复用 `RoomCode.normalize` + `.isValid`）；
  2. 点 "加入房间" → `peerManager.joinRelayRoom(roomId:)` + 启动中继 discovery；
  3. 监听发起方周期广播的 `SignRequestDTO`（magic `HSQ-v1`，携带 sessionId / groupPublicKey / chain / recipient / amount / token / feeDisplay / initiatorDeviceName），收到后匹配本地 `walletStore.wallets` 的 `groupPublicKey`；
  4. 匹配成功 → 渲染审阅卡片（钱包 / 收款地址 / 金额 / 预估手续费 / 初始化设备名 + 线下核对警告）；
  5. 点 "同意并开始签名" → 走 `PinUnlockSheet` → 用 cached SWK 初始化新的 `SigningViewModel` → `applySignRequest(dto)` 同步参数 → 直接进入 `.signing` 步骤并启动 MPC 轮次；
  6. 匹配不上 → 显示 "没有匹配的钱包" + group key 前缀提示。
- **iOS**: 发起方侧 `SigningViewModel.startAnnounceLoop()` — 进入 `.invite` 步骤后每 300ms 广播 6 次 `SignRequestDTO`（捕获同时加入的 cosigner），之后降到 2s 间隔；`.signing` 步骤进入后自动停止广播。载荷随 tx 信息实时变化（包含当前 feeDisplay），保证 cosigner 看到的和发起方一致。
- **iOS**: L10n `JoinSigning.*` 中英双语（title / intro / joinButton / waitingForRequest / reviewTitle / wallet / recipient / amount / verifyWarning / approve / reject / unmatchedTitle / fromDevice / unmatchedBody / homeButton）。

### Known limitations

- `SigningViewModel.startSigning()` 里 `participants = [self.partyIndex] + joinedSigners.prefix(...).enumerated().map { offset + 1 }` 的计算仍用 offset 伪索引——只在发起方 `partyIndex == 1` 且两方钱包恰好拿到连续索引时巧合工作。正式多方（3-of-3、非连续 partyIndex）需要让 peer 在加入时把自己的 `partyIndex` 声明出来（拟在下一版 `RoomPresenceDTO` 扩展字段，或新增 `SignerManifestDTO`）。
- cosigner 侧的 gas / nonce / 链 ID 等链特定参数目前由 cosigner 自己从本地 RPC 拿——如果 cosigner 与发起方的 RPC 节点 nonce 同步有差异（极少见），哈希会不一致导致签名失败。后续将把 initiator 侧构建好的 unsigned tx 原文直接塞进 `SignRequestDTO`。

## [0.3.0-dev.77] - 2026-04-20

### Added

- **iOS**: 热签名**房间码邀请 UI**（发起方侧）。此前 `InviteSignersView` 只显示一个"等待共签方加入…"的转圈，既不生成也不显示房间码，也不加入中继房间——多方热签名事实上无法从 UI 发起。本版在进入邀请步骤时：
  - `SigningViewModel.prepareInvite()` 生成三词房间码（`RoomCode.generate()`），把它同时作为 MPC `sessionId` 和中继 `roomId` 使用，保证所有参与方落在同一会话；
  - 自动调用 `peerManager.joinRelayRoom(roomId:)`，失败时给出错误提示 + 重试按钮；
  - 邀请卡片复用 DKG/refresh 风格：明文房间码 + 复制按钮 + 轻点展开二维码（`CIQRCodeGenerator`，`horcrux-room:<code>` 载荷）。
  - 加入中继前显示"正在加入中继房间…"，加入成功后显示"把这组房间码分享给你的共签方…"。
- **iOS**: `estimateGas()` 全链路 `SecureLog` 埋点（入口参数、early-return 分支、EVM 成功值、RPC 失败原因），便于诊断 dev.76 仍偶发的 "—" 显示问题。

### Notes

- 共签方侧目前仍依赖既有的"已连接对端"自动列表——即**已经**通过 DKG/refresh 保持连接的设备会自动出现在 `joinedSigners`。真正的共签方"接受签名请求"入口（主屏幕进入 + 扫码/输入房间码 + 审阅交易后确认）是下一个里程碑的独立任务，需要新 UI + 新协议消息（`sign_request_announce`）。

## [0.3.0-dev.76] - 2026-04-20

### Fixed

- **iOS**: **真正**修复 EVM 发送页 gas / fee 不显示问题。dev.74 的 `@State Task` + `onChange` 手动 debounce 在某些场景下不触发（怀疑是 `@State Task?` 与 ObservedObject published 属性的交互时序）。改用 SwiftUI 原生的 `.task(id: estimateKey) {…}`，`estimateKey` 由 recipient / amount / feeTier / selectedToken 组合而成；任何一个字段变化都会让 SwiftUI 自动取消上一次并 500ms 后重跑 `estimateGas()`。代码更短、更少状态，且首次进入页面时也会触发一次（空字段被 VM 内部 guard 丢弃，无副作用）。

## [0.3.0-dev.75] - 2026-04-20

### Fixed

- **iOS**: 交易历史页首次打开时自动同步一次（`TransactionHistoryView` 原先只有 `refreshable` 下拉刷新，用户点"查看全部历史"进去会先看到陈旧数据直到手动下拉）。沿用既有的 `isSyncing` 去抖，重复进出不会重复拉。

## [0.3.0-dev.74] - 2026-04-20

### Fixed

- **iOS**: EVM 发送页的 gas 上限与预估手续费不再显示为 `—`。`ComposeTransactionView` 现在会在 `onAppear`（RBF 预填场景）以及 recipient / amount / feeTier / selectedToken 变化时通过 500ms debounce 调用 `estimateGas()`，用户填表时就能看到活的 gas limit 和 fee 估算，而不是等到按 Next 才在后台悄悄跑。BTC/LTC/SOL 的 fee 行也一同受益。

## [0.3.0-dev.73] - 2026-04-20

### Added

- **iOS**: **多方冷签名 v2（beta）**。`totalParties ≥ 3` 的钱包进入冷签名时自动路由到新的 `ColdSigningCoordinatorV2` + `ColdSigningViewV2`，使用星型拓扑 + 批量 payload。发起方做中枢，每张 QR 打包当前持有者寄给某个 peer 的所有 `FfiMpcMessage`；CGGMP21 后端无需改动（路由复用已有的 `toParty` 过滤）。v1 2-of-2 路径保持不动，仍由原 `ColdSigningCoordinator` 承担。带 "Beta" 徽章，尚未做 3-台模拟器端到端 dress rehearsal，生产使用前请先对一笔 3-of-3 ETH 转账做活线演练。

### Fixed

- **Relay tests**: `test_ws_plain_get_rejected` 原先断言 404，但 axum 的 `WebSocketUpgrade` extractor 缺失 upgrade headers 时返回的是 400 Bad Request。修正断言 + 注释。

### Security

- **Relay**: `validate()` 在 `RELAY_ADMIN_TOKEN` 未设置且 bind 在非 loopback 主机时拒绝启动，避免 `/admin/rooms` + `/metrics` 被公开访问。可用 `RELAY_ALLOW_UNAUTHENTICATED_ADMIN=1` 显式覆盖。loopback bind（127.0.0.1/::1/localhost）仍 warn-and-boot。

## [0.3.0-dev.70] - 2026-04-20

### Added

- **iOS**: **RPC 设置页 P0/P1/P2/P3/P4/P5** 一揽子重做。
  - P0: Ethereum & EVM 段把之前 6 个堆叠的 SecureField（Alchemy/Infura/Ankr/BlockPI/dRPC/NodeReal）收拢成 `PaidEVMProvider` 枚举 + 单 Picker + 绑定 SecureField + 单个 "Use X for <chain>" 按钮。换付费服务商只需拨菜单。
  - P1: 点 Mainnet / Testnet 预设不再立即覆盖当前配置，弹 alert 预览 ETH/BTC/SOL 三条目标 URL，已生效的预设直接 no-op。
  - P2: "Test All" 按钮从状态概览行移到导航栏右侧工具项，留给正文更多空间。
  - P3: EVM 网络选择器（Mainnet/Polygon/Base…）合并到 "RPC 地址" 标签右侧内联 `.menu` Picker，取代独立 Form 行。
  - P4: Import/Export 脚注从防御性措辞（"不包含 API 密钥"）改为正向价值 + 兜底说明（"可作为备份在多台设备之间迁移……API 密钥始终留在本机 Keychain"）。
  - P5: Litecoin / Tron 只读段的 header 增加 `eye` 图标视觉提示。
- **iOS**: **动态 DKG 时间估算**。新建 `DkgEstimate` 根据参与方 n + 曲线 + prime-pool 状态预测耗时；2-of-2 ≈ 10s，3-of-3 ≈ 18s，5-of-5 ≈ 45s。
- **iOS**: **Polygon / Arbitrum One / Base** 升为一等链（第 8/9/10 条）。新增 Polygon/Arbitrum/Base 品牌 logo 资产。
- **iOS**: **Rotate Shards** 功能：重命名为"Replace Device"，新增 `RefreshTracker` 记录上次轮换时间、`SecurityDetailView` 展示轮换卡，`RefreshShardSheet` 走 transport picker + room code 预协商。
- **iOS**: **账户头像**：按账户（非钱包）分配 emoji + 渐变背景，多账户 UI 一眼区分。
- **iOS**: `SecurityHealthCard` 作为钱包主页信息架构 P2/P3 的一部分落到 Shards tab；原位置 Wallet Home 改用 QuickActionsRow（Receive/Send/History）再回滚；当前方案：Shards tab 持有 SecurityHealthCard + push 到 `SecurityDetailView`。

### Fixed

- **iOS**: **DKG/Signing/Refresh 跨设备路由修复**（关键 bug）。relay room 是广播，所有参与方都会看到所有包；原来没过滤 `toParty` 就直接 feed 进 state machine，导致 n ≥ 3 时 CGGMP21 抛 "party N tried to overwrite message" 而崩。现在统一加 `msg.toParty != 0 && msg.toParty == myPartyIndex` 过滤。已 3 台模拟器端到端验证：DKG、Sign、Refresh 全通。
- **iOS**: **Refresh 多方协调**系列修复：t==n 走非-VSS keygen、subscribe 先于 broadcast、按 payload 去重而非 (from,round,to) 元组、共享 session id、`allPeers` gate、surface cggmp21 inner error。
- **iOS**: **DKG 进度条**：`currentRound` 改由 `msg.round`（协议真正的轮号）驱动，不再是 msgCount，修复了 n=3 时进度卡 90% 的显示异常。
- **iOS**: **RPC 健康探测防抖**：`NodeHealthStore.refreshAll` 为每条链加 8 秒 cooldown，页面打开 `.task` 不再反复探测；工具栏刷新按钮 + 单行点击仍强制 bypass。
- **iOS**: **FfiMpcMessage @unchecked Sendable** 消除 Swift 6 并发警告（POD 类型安全）。
- **iOS**: **死代码清理**：`BlockchainService.swift` 里 3 处 unused let 绑定升级为真正的 `rpcError(code, message)` 透传。
- **iOS**: `CreateShardFlow` 切换 Creator ↔ Joiner 时 roomCode 残留清空。
- **iOS**: `ProgressRing` 仪式场景下数字被图标遮挡，新增 `showPercentage: Bool` 开关。
- **iOS**: 钱包行 "BNB Smart Chain" + 24h% badge 不再换行。
- **iOS**: `SecurityDetailView` 轮换行按 account 分组，不再按 chain 重复。
- **iOS**: 默认 RPC 更换：Polygon/Sepolia 原公共节点已挂，换成 llama/Ankr 等新源。
- **iOS**: 生物识别本地备份系列修复：SE-seal 在模拟器提前返回带清晰消息、SWK 未缓存时兜底 PIN sheet、失败时 surface underlying error。

### Changed

- **iOS**: **RPC 设置页功能矩阵**大幅扩展（跨 dev.60-dev.69 多个版本）：Infura/Ankr/BlockPI/dRPC/NodeReal 模板、chain-id 校验、provider badge、per-chain reset、JSON 导入/导出、Etherscan 密钥内联、inline latency sparkline、block-lag 多源中位数检测、可选 WebSocket endpoint + 探测。
- **iOS**: **设备标签页**重排版：chain chips 去重（ETH/Polygon/Arbitrum/Base 合并为一个 EVM 快照）、卡片间距紧凑化。
- **iOS**: **Settings 三波审计**（wave A/B/C）：vault 调色板统一、共享组件下沉、动态版本号、子屏 chain 段本地化。
- **iOS**: **Room code 文案** 与 Lobby 卡片改进：非 Relay transport 下隐藏、首屏 CTA 清晰化。
- **iOS**: **签名成功页**带 tx hash reveal 动画。

## [0.3.0-dev.59] - 2026-04-19

### Added

- **iOS**: `WalletHomeView` — **可折叠账户组**（仅当账户数 > 1 时生效）。`WalletGroupHeader` 变成可点 Button，右侧多一个 chevron；收起后 chevron 旋转 -90°，shared-EVM-address chip 被替换为一行摘要 `N 条链中 M 条有余额` / `M 条链 · 全部为空`。`@State collapsedGroups: Set<String>` session-local，不持久化——iOS 原生 disclosure group 的语义：opt-in fold / relaunch 自动展开。单账户用户无感知。新增 i18n：`common.expand` / `common.collapse` / `walletHome.collapsedFundedOfTotal` / `walletHome.collapsedAllEmpty`（zh-Hans + en）。
- **iOS**: `PriceService` — **两级报价源**兜底。原先单源 CoinGecko，429/超时/Cloudflare 挑战就整 App 美元列静默变空。现在 `fetch(symbols:)` 先打 CoinGecko `/simple/price`，再对未返回的 symbol 用 Coincap `/v2/assets?ids=...` 精准补请求（`priceUsd` + `changePercent24Hr` 字段直接映射现有 `Quote` 模型）。两家独立基建、都无需 API Key。Sparkline 仍单源 CoinGecko（装饰性，CG 挂了就静默隐藏，已有行为）。类头注释同步更新说明 fallback 阶梯。

### Fixed

- **iOS**: `CreateShardFlow` — **加入房间时房间码不再残留**。Creator 路径 `onAppear` 会自动生成房间码避免 host 面对空框，但切换到 Joiner 时这串自动码留在输入框里，加入方得先全选删除再粘贴对方房间码。`onChange(of: role)` 里现在检测切到 `.join` 先把 `viewModel.roomCode = ""` 再调用 `autofillRoomCodeIfNeeded()`（对加入方天然 no-op），加入路径永远以空输入框启动。
- **iOS**: `ProgressRing` — 仪式页图标遮挡百分比修复。`ProgressRing` 内置在 ZStack 中心渲染 `"NN%"` Text，仪式 UI（SigningProgressView / DKGProgressView）又把 44pt ChainIcon / `key.horizontal.fill` 叠在中心，两者抢同一位置——数字被盖。加 `showPercentage: Bool = true` 开关，仪式场景传 `false` 让图标独占；独立 ring（发现/lobby）保留默认行为。进度仍由环 trim + round 计数 + elapsed 时间三重可视化。

### Changed

- **iOS**: `PortfolioSummaryCard` 副标题清理。原文 `1 条链 · 实时 USD 报价（来源：CoinGecko）` 精简为 `1 条链`（多账户：`跨 N 个账户 · M 条链`）。"实时 USD 报价" 与上方 $ 金额自解释；CoinGecko 归属属 footer 级信息，不该戳在主要余额下方。将来若 ToS 要求应用内署名，放到 Settings → 关于/数据源一行即可。zh-Hans + en 两份 `.strings` 同步。

## [0.3.0-dev.58] - 2026-04-19

### Added

- **iOS**: `OnboardingView` value-prop 卡片升级为 **ShardOrbit hero 组合**。`valuePropPage(icon:title:subtitle:orbitStates:)` 加入每卡专属的轨道配置，用 `ShardOrbit.DotState` 编码叙事：卡 1（安全）3 个 `.active` 点、卡 2（多设备）4 个 `.active` 点、卡 3（恢复）3 个点中间 `.failed` 两侧 `.active` —— 可视化"一台设备挂了密钥仍在" 的 t-of-n resilience。180pt 紫色径向光晕 + 64pt radius orbit + 44pt SF Symbol 中心 glyph（用 `shieldGradient` + 紫色外发光）。卡 3 图标从通用循环箭头换成 `key.horizontal.fill`，与 DKG/签名仪式 glyph 对齐。Continue 按钮加 `Haptics.selection()`。

## [0.3.0-dev.57] - 2026-04-19

### Added

- **iOS**: `PortfolioBreakdownSheet` —— 点钱包主页 Portfolio 卡片展开**各链分配明细**。`PortfolioSummaryCard` 获得 `@State showBreakdown` + `.contentShape(Rectangle())` + `.onTapGesture { Haptics.selection(); showBreakdown = true }`，`.sheet` 走 `.medium/.large` detents + 顶部拖动指示条。Sheet 内部：按 USD 倒序排的 per-chain row（`ChainIcon` + 链名 + 原生数量 + 美元值 + 24h 涨跌 badge + tinted 分配条），`GeometryReader` 实现的 capsule 分配条宽度 `max(6, geo.size.width * pct)`（≥1pt 最小宽度保证 sub-1% 仓位也可见），每行包 `.tintedGlassCard(color: chain.color, padding: 14)`；空状态兜底。v1 只聚合链级原生资产——ERC-20/SPL 待 BalanceCache 补上跨钱包 token seed。`.numericText` contentTransition 让总额跳数字有动画；NavigationStack + Done 按钮走 accentBlue。

## [0.3.0-dev.56] - 2026-04-19

### Added

- **iOS**: **Send 流程 chain-tint 全覆盖**。`ComposeTransactionView` 加 `liveFiatString` 计算属性（复用 `PriceService.fiatString(amount:symbol:)`，空/零/非法时返 nil），金额 HStack 下方显示 `≈ $X.XX` caption（`compose_amountFiat` identifier），支持 token 路径（走 `viewModel.transferSymbol`）；`GradientButtonStyle` 扩展可选 `tint: Color?` 参数——非 nil 时用 `LinearGradient([tint, tint.opacity(0.7)])` + `tint.opacity(0.45)` 外发光覆盖默认紫色梯度；Next/Sign 按钮传 `wallet.chain.color`。`InviteSignersView` 全面链色化：`SignerSlot` 加 `tint: Color = accentPurple` 参数（默认保留 DKG 场景的紫色），已加入的对端行从 `.glassCard` 升级为 `.tintedGlassCard(color: chain.color)`，等待 ProgressView + Sign Transaction CTA 都走链色。`TransactionPreviewCard` 的放大镜图标、plain-language 摘要 pill 底色（`tint.opacity(0.15)`）、外框 stroke（`tint.opacity(0.25)`）全改为链色；复制/区块浏览器图标**故意保留 accentBlue**——App 全局约定 accentBlue = "可点击的操作"，chain-tint = "这属于此链"，语义分层。

## [0.3.0-dev.55] - 2026-04-19

### Added

- **iOS**: **签名仪式 UI**（`SigningProgressView`）。ZStack 合成：`ShardOrbit`（对端点映射到 `.active` / `.waiting` / `.done` / `.failed`）+ 链色 `ProgressRing`（`showPercentage: false`，由外层 glyph 独占中心）+ 44pt `ChainIcon` 中心 glyph + 链色径向外发光。Round N of M 文字 + 等宽 elapsed 时间下沉到 ring 外。
- **iOS**: **DKG 仪式 UI**（`DKGProgressView`）。同款 ShardOrbit + ProgressRing 合成，`key.horizontal.fill` 为 glyph，根据 `curveTint`（secp256k1 → ETH 蓝、ed25519 → SOL 紫）切颜色。`DKGCompleteView` 新增庆祝 ZStack：脉冲环 + 径向 halo + spring 弹出封印效果。
- **iOS**: `WalletDetailView` 继承主页视觉语言——tinted hero card、balance 大字、PriceChangeBadge + Sparkline 组合、GlassCard 的 Send/Receive CTA。

## [0.3.0-dev.54] - 2026-04-18

### Added

- **iOS**: `PortfolioSummaryCard` 获得 **sparkline + 隐私 toggle**。24h 价格走势来自 `PriceService.sparkline24h(symbol:)`（CoinGecko `/coins/markets?sparkline=true` 取 7d 里最后 24 小时，5min TTL 独立缓存），按总值加权混合成 portfolio-level 走势；长按 card 切换金额可见性（存 UserDefaults）。
- **iOS**: 钱包行 **24h 价格变化 badge** + **链品牌色**。每行右侧显示 `PriceChangeBadge`（↑/↓ + 百分比 + 绿红色），行背景带 `tintedGlassCard(color: chain.color)` 左侧 3pt 色条。`Chain.color` 使用品牌色十六进制（ETH #627EEA / BTC #F7931A / SOL #9945FF / BNB #F0B90B 等）。
- **iOS**: 钱包行**快捷操作**（长按上下文菜单 Copy / Receive / Hide）+ 离线 banner 可收起。
- **iOS**: **账户级地址去重**——组内所有 EVM 钱包共用一个地址时，`WalletGroupHeader` 顶部挂一条可复制的 shared-address chip（`link.circle.fill` + 缩写 hex），每行不再重复显示。
- **iOS**: **空余额链自动折叠**——组内 ≥2 个零余额链且至少 1 个有余额时，空链默认收起并提供 "Show N more chains" 展开按钮；`expandedGroups: Set<String>` session-local。
- **iOS**: 钱包列表视觉层级（Portfolio hero + per-group 卡片 + FAB 间距）重整。

## [0.3.0-dev.53] - 2026-04-18

### Added

- **iOS**: **自定义数字键盘**（`PinKeypad`）—— PIN 输入从系统 number pad 换成全屏 in-app 九宫格，抛掉键盘弹出抖动；`PinDotsField` 统一所有 PIN 录入点（Lock、Settings、Refresh 等）。
- **iOS**: PIN 长度策略统一（默认 6 位、可配置）+ 锁屏 biometric 解锁**默认开启**。
- **iOS**: **App 图标**首次落地（ios/Horcrux/Assets.xcassets/AppIcon）。
- **iOS**: Siri Shortcuts `HorcruxAppIntents` 本地化（见 dev.52）；"更换设备" 入口改造为真实 PIN→refresh→re-encrypt 流程（见 dev.52 详述）。
- **Core perf**: **Paillier 安全素数池** —— `horcrux-core/src/mpc/paillier_pool.rs` 后台线程预生成 2048-bit safe primes（CGGMP21 DKG 的热点成本），需要时从池里 pop 而不是现场生成；N-party DKG 实测冷启提速显著。
- **Core perf**: **aarch64 GMP 手写汇编** —— `third_party/gmp-asm-override/` 补齐 `mpn_addmul_1` / `mpn_submul_1` 两个热函数的 aarch64 汇编版（GMP 默认 C 路径），通过 `build.rs` 钩子覆盖到 `gmp-mpfr-sys` 编译结果；`tests/devel/try.c` harness 跑通验证 ABI 正确。
- **Core tests**: 差分模糊测试 `mpn_{add,sub}mul_1` 汇编 vs 参考实现；DKG perf harness 泛化到 N-party + FROST + prime-pool benchmark。
- **iOS**: DKG 时间预估 + 慢路径提示（等待 >45s 时 banner 提示可能是对端网络问题）；Create Shard 流程 QR 码和房间码在 initiator 等待页保持可见。

### Changed

- **iOS**: **P0-P3 UX polish 批次**：
  - P0：offline banner 不再把 navbar 染成黄色；修复坏掉的 zh 字符串
  - P1：empty-state 减少视觉拥挤，Shards tab 改名
  - P2：hairline token、更粗的 empty-state hero、更温和的 "save for later" 措辞；App 全局强制 dark color scheme
  - P3：empty-state CTA 改读 "Create Your First Wallet"
- **iOS**: DKG/签名按钮统一走 `GradientButtonStyle`；WalletHome 加 FAB；Auto-Lock 去掉 "Never" 选项（留着是安全风险）。
- **iOS**: 语言切换页停止混杂中英；Settings 节点配置页剩余硬编码字符串本地化；从 Settings 隐藏硬件钱包入口（未落地前不展示）。

## [0.3.0-dev.52] - 2026-04-19

### Added

- **Rust + iOS**: 暴露 CGGMP21 **`key_refresh()`** 主动刷新 FFI —— `horcrux-core` 新增 `mpc/refresh.rs::EcdsaRefreshSession`，沿用现有 `EcdsaDkgSession` 模式包一层 driver；`SessionManager::create_refresh()` 校验当前钱包必须是 n-of-n（CGGMP21 的硬约束）+ Secp256k1 + ECDSA，然后 `cggmp21::key_refresh(eid, &key_share, pregen).into_state_machine(rng)` 把所有 round 跑完。完成后 `KeyShare::into_inner()` 拆出 `core: DirtyIncompleteKeyShare<E>` + `aux: DirtyAuxInfo<L>`，分别 `Valid::validate(...)` 重新封装并序列化成现有 `EcdsaShardData`。**关键不变量**：refresh 前后群公钥（钱包地址）必须完全相同 —— Rust 侧 `assert_eq!`，Swift 侧 `RefreshShardCoordinator` 在写回 Keychain 前再次校验。新增 `EcdsaPhase::Refresh` wire-msg 守卫，避免 keygen / auxinfo / sign / refresh 四种协议消息互相串扰；`ExecutionId` 形如 `horcrux-refresh-{session_id}` 与其它流程隔离。
- **iOS**: `RefreshShardCoordinator` + `RefreshShardSheet` —— PIN 解锁 → 取出 SWK 解密现有分片 → `bridge.startRefresh(...)` → 与对端走标准 relay round-loop → 收到新 `KeyShare` → 公钥不变量校验 → 用旧 SWK 重新派生 PBKDF2-AES-GCM 重新加密 → `WalletStore.storeKeyShare(_, accountId:)` 走 Keychain `update` 原子替换（崩溃也不会留下半截密文）。`SettingsView` 的 "更换设备" 入口从 "敬请期待" 占位改造成可实际触发 sheet 的按钮（首个 n-of-n + secp256k1 + 未隐藏的钱包），覆盖现役 2-of-2 BTC/ETH/LTC/SOL/TRON 路径。

### Changed

- **iOS**: `ReplaceDeviceInfoView` 新增 wallet picker 逻辑 —— 自动挑选首个 `threshold == totalParties && curveType == .secp256k1 && !hidden` 的钱包作为 refresh target，避免误碰 ed25519/Solana 这类暂时不能 CGGMP21 refresh 的钱包。



### Added

- **iOS**: `WalletHomeView` 加 **pull-to-refresh** —— 在主页 ScrollView 上挂 `.refreshable`，下拉时通过新增的 `BalanceCache.refreshAll(wallets:service:config:force:)` 工具方法以 `force: true` 并行刷新所有可见钱包的原生余额（绕过 30s TTL）+ 触发 `PriceService.refreshIfNeeded()`。BalanceCache 的 in-flight 合并仍然生效，hero 卡片和列表行共享同一次 RPC，不会出现两次重复请求。`PortfolioSummaryCard.refreshAll()` 同步重构为调用 `BalanceCache.refreshAll(...)`，删掉了重复的 `withTaskGroup` 样板。

## [0.3.0-dev.50] - 2026-04-18

### Added

- **iOS**: 冷签名（air-gapped QR chain）**cosigner 状态机**落地 —— 从 dev.50 起两台设备上同时打开 `ColdSigningView` 即可完成 2-of-2 离线签名（全程飞行模式 / 无中继 / 无任何网络请求）。`ColdSigningCoordinator` 新增 `Role` 枚举（`.initiator` / `.cosigner`）与 4 个协签阶段（`awaitingInvite` / `showingCosignerRound1` / `awaitingInitiatorRound2` / `showingCosignerRound2`），`startAsCosigner(wallet:shardData:)` 先挂起等扫码，`ingestInvite` 用发起方 QR 里带的 sessionId / messageHash / 初始 round1 启动本地 FROST 会话，按 `FfiMpcMessage.round` 把引擎吐出的消息拆到 QR2（round1 回复）和 QR4（round2 shares），`cosignerIngestRound2` 消费发起方 round2 分享同时产出本侧 round2，扫完 QR3 即可在本地拿到完整签名（`getSigningResult`），cleanup 此时立即 zero 掉 shardData（下游只剩公开的签名分享）。新增 `ColdError.walletMismatch`（同一钱包 / 不同分片校验：`wallet.accountId == invite.walletId` && `chain` 一致 && `initiatorParty != wallet.partyIndex`）。`ColdSigningView` 改为先弹出「我是发起方 / 我是协签方」的 role picker（发起方 card 在 messageHash 缺失时 disabled），根据选择决定是进入 4 步发起流程还是 3 步协签流程，`stepLabel` / `content` / `qrGuidance` / `scannerGuidance` / `footerActions` 每条 switch 都覆盖新阶段；完成页在 cosigner 下显示「协签完成，等对方扫最后一张 QR」提示而不是「把签名发回」。新增 `L10n.ColdSign` cosigner 相关 14 条键 + `L10n.ColdSignErr.walletMismatch` 1 条；zh + en .strings 同步。

### Fixed

- **Build**: `ios/build-rust.sh` 加 toolchain 指纹守卫 —— 每次构建前把 `CLANG | target-aarch64 | target-x86_64 | iOS-SDK | iOS-Sim-SDK` 的 SHA 落到 `target/.horcrux-fp/gmp-mpfr-sys.fingerprint`；变动时自动 `cargo clean -p gmp-mpfr-sys --target …` 两个 iOS target 缓存，避免 Xcode 升级 / SDK 切换后 gmp-mpfr-sys 留下不兼容对象文件导致 rebuild 爆出 `undefined symbol ___gmpn_*` 链接错误。首次运行没有 target 目录也安全（`|| true`）。



### Changed

- **iOS**: `HorcruxAppIntents` Siri Shortcuts 本地化 —— `ShowWalletAddressIntent` / `OpenReceiveIntent` 的 `title` / `description` / `categoryName` / `@Parameter(title:)` / `shortTitle` 全改为 `LocalizedStringResource("intents.*", defaultValue:)` 模式；错误对话框 `needsValueError(IntentDialog(LocalizedStringResource…))`；`perform()` 里拼接的 dialog 改走 `NSLocalizedString + String(format:)`（带 `%1$@ %2$@` 占位）。Shortcuts 短语同时保留中英 4 条（中文 2 + 英文 2），Siri 可用任一语言触发。Summary 保持 Chinese literal（AppIntents DSL 约束）。新增 zh + en 14 条键（`intents.showAddr.*` / `intents.openReceive.*` / `intents.category.wallet` / `intents.param.chain` / `intents.error.walletNotFound` / `intents.short.*`）。

## [0.3.0-dev.48] - 2026-04-18

### Changed

- **iOS**: 残留 i18n 扫尾批次 —— `SigningView` + `SigningViewModel`（费率 Picker 4 段、原生代币后缀、Gas 价 gwei label、ENS 解析失败提示、生物识别失败 icon、TRC-20/SPL/ERC-20 代币转账 label、TRX 能量费用格式化、广播失败前缀格式化），`ContentView` 初次启动 3 张教学卡（无需助记词 / 多设备阈值 / 多链一套分片）+ "继续" 按钮，`ShardsViewModel`（PIN 错误 2 条、iCloud RK 不可用 fallback、导出摘要 + 复数格式化），`PortableBackupCrypto` 备份错误 3 条，`ColdSigningCoordinator` 冷签名错误 3 条，`ReceiveView` 请求金额 + 可选占位符，`CopyFeedback` + `SecureClipboard` 默认 toast 文案改为 `L10n.Common.copied`，`CustomTokensView` Solana mint 地址占位符。共替换 37 处；新增 `L10n.SigningExtra`（14 键）/`OnboardingCards`（7 键）/`ShardsVM`（5 键 + 2 复数 formatter）/`BackupCrypto`（3 键，2 formatter）/`ColdSignErr`（3 键，1 formatter）/`ReceiveExtra`（2 键）/`CustomTokensExtra`（1 键）。

## [0.3.0-dev.47] - 2026-04-18

### Changed

- **iOS**: `TransactionHistoryView` + `WalletHomeView` RBF 说明 Sheet / 空钱包 CTA / 总资产卡片 + `SettingsView` 语言 / 设备昵称 / 硬件钱包 Alert / PIN 强度 Label / ReplaceDeviceInfoView 全部文案本地化 —— `L10n.TxHistory` 扩展 11 条（4 段状态过滤、状态 Picker、搜索占位、刷新 / 导出 CSV、加速 RBF Label/Body、已是最新、已同步 N 条格式化），新增 `L10n.RBFSheet` 9 条（加速被卡住的交易标题 / 解释 / 3 条可用操作 / 丢弃重签按钮 / 导航标题 / 关闭），新增 `L10n.WalletEmpty` 10 条（开始使用 / 接收提示 symbol 格式化 / 已复制 / 复制地址 / QR / 自定义代币 / 总资产 / 单多账户 summary 格式化 / 删除确认 message），新增 `L10n.SettingsResidual` 24 条（语言 Section / 行 / 设备昵称 + hint / 硬件钱包 Alert + 副标题 / 简体中文值 / PIN 强度 4 档 / 替换设备 5 段步骤 + 即将推出 + 刷新说明）。共替换 50 处硬编码 CJK；同步 en + zh-Hans .strings

## [0.3.0-dev.46] - 2026-04-18

### Changed

- **iOS**: `AddressBookView` + `CustomTokensView` 全部文案本地化 —— 新增 `L10n.AddressBook`（20 条：空态 / 新建编辑 / 导出导入 / 选择联系人）与 `L10n.CustomTokens`（15 条：空态 / 添加代币表单 / 元数据占位符 / 自动查询错误）。替换 37 处硬编码 CJK；同步 en + zh-Hans .strings

## [0.3.0-dev.45] - 2026-04-18

### Changed

- **iOS**: `ShardsListView` + 账户详情 / 备份 / 导入 / 删除 Sheet 全部文案本地化 —— `L10n.Shards` 追加 ~20 条（派生地址、删除不可逆 Alert、删除双重确认 Toggle、删除链清单模板、PIN 错误），`L10n.ShardBackup` 补 8 条（导出介绍模板、iCloud RK 提示、PIN Header/Footer 分支），`L10n.ShardImport` 补 14 条（账户/链/派生钱包 Label、加密方式分支、旧格式值、RK 信息横幅、恢复/解析错误）。替换 39 处硬编码 CJK；同步 en + zh-Hans .strings

## [0.3.0-dev.44] - 2026-04-18

### Changed

- **iOS**: `CreateShardFlow` + `CreateShardViewModel` 全部文案本地化 —— 向 `L10n.CreateShard` 追加 ~40 条键（角色选择器、价值前言、链类型、高级设置、房间码输入、MPC 解释器 4 组图文、N-of-N 风险 Alert），`L10n.Discovery` 补 9 条（秒后超时、在场设备计数、等待发起人），`L10n.DKG` 补 ~15 条（收尾 / 已用时 / 预计剩余、未备份退出 Alert、保存失败、VM 错误文案），新增 `L10n.Backup` 枚举覆盖强制备份 Gate 的 9 条文本。替换共 63 + 7 处硬编码 CJK；同步 en + zh-Hans .strings

## [0.3.0-dev.43] - 2026-04-18

### Changed

- **iOS**: `SigningView` 全部文案本地化 —— 向 `L10n.Signing` 追加 ~27 条静态键 + 4 个带参格式化（`ensResolving` / `tokenTransferDescContract` / `tokenTransferDesc` / `feeWarnPct`），覆盖地址簿按钮 a11y、资产 / 费用优先级 Picker、自定义 gas 与 sat/vB 占位、共同签名方列表、缓慢 / 等待提示、生物识别 reason、交易预览（操作 / 资产 / 金额 / 合约 / 网络费）、收款地址分段提示、复制 / 浏览器 a11y、余额变化、ENS 解析进度、费率警告等 29 处硬编码 CJK；同步 en + zh-Hans .strings

## [0.3.0-dev.42] - 2026-04-18

### Changed

- **Build**: 修复 `ios/build-rust.sh` 每次都重新编译 `gmp-mpfr-sys` / `rug` / `cggmp21`（约 30 秒）的问题 —— 删除 `third_party/gmp-mpfr-sys/src/C.rs`（该模块仅用于 rustdoc 内联 GMP/MPFR 的 HTML 手册，`doc-c/` 已从 vendored copy 中剥离），以及 `lib.rs` 的 `#[cfg(doc)] pub mod C;` 声明。cargo 的 fingerprint 不再因 49 个 `include_str!` 目标缺失而反复失效；重复运行降至 ~3 秒
- **iOS**: `NodeErrorMapper` + `ShardHealthView` 全部文案本地化 —— 新增 `L10n.NodeErr`（16 条，含广播失败前缀）与 `L10n.ShardHealth`（13 条静态 + `lastCheck` / `resOK` / `resUnreadable` 带参），同步 en + zh-Hans .strings

## [0.3.0-dev.41] - 2026-04-18

### Changed

- **iOS**: `ColdSigningView` 全部文案本地化 — 新增 `L10n.ColdSign` 命名空间（24 条 + 带参 `sigLength`），同步 en + zh-Hans .strings，为 dev.39 的冷签名实验特性提供完整双语支持

## [0.3.0-dev.40] - 2026-04-18

### Added

- **iOS**: 应用内语言切换（设置 → 语言 / Language）— 跟随系统 / 简体中文 / English 三选一，写入 `AppleLanguages` UserDefault，切换后提示重启生效（`LanguageSettingsView`）
- **iOS**: `Info.plist` 声明 `CFBundleLocalizations = [zh-Hans, en]`，使 iOS 系统设置 → Horcrux → 首选语言页面出现语言选项

### Changed

- **iOS**: 抽取 ~30 条高曝光硬编码中文到 L10n + `zh-Hans` / `en` .strings（设置页各分组标题、钱包行为菜单、批量重命名/删除弹窗等）

## [0.3.0-dev.39] - 2026-04-18

### Added

- **iOS**: 冷签名模式（**实验性**）— `ColdSigningCoordinator` + `ColdSigningView`，在两台设备间轮流扫描 QR 完成 FROST 签名，不依赖中继 / 不发网络请求。当前版本仅实装 **2-of-2 钱包的发起方（initiator）** 状态机；对端（cosigner）状态机计划于 dev.40 发布
- **iOS**: `ColdPacket` 编码格式定义 —— invite（会话参数 + 第 1 轮消息）+ round（任一轮消息批）两类包，base64 JSON 承载，单个 QR 容纳 2-of-2 FROST 全部消息

### Notes

- **iCloud 分片备份**：v5 备份格式已使用 iCloud-synced Recovery Key 加密（`AccountBackup` version 5 + `RecoveryKeyManager`），用户在"分片"页导出后可存入 iCloud Drive，于任一登录同 Apple ID 的设备免密码还原 —— 此能力此前已在 dev.13 前落地
- **i18n 全面翻译**：现有 L10n 目录已覆盖 ~80 键值（中 / 英），剩余 352 处硬编码中文将分批在后续 dev tag 抽取

## [0.3.0-dev.38] - 2026-04-18

### Added

- **iOS**: App Intents / Siri Shortcuts — "复制地址" / "收款二维码" 两个意图，支持 Shortcuts app 与语音调用（无需 WalletConnect）
- **Core**: shard crypto 新增 5 个单元测试（错误设备密钥拒绝、nonce/salt 唯一性、密文篡改检测、HKDF 派生稳定性 / salt 发散性）

### Fixed

- **Build**: `third_party/gmp-mpfr-sys` 的 `pub mod C` 增加 `#[cfg(doc)]` gate，避免本地 `cargo test` 因 vendored 副本精简掉 `doc-c/` HTML 而失败

## [0.3.0-dev.37] - 2026-04-18

### Added

- **iOS**: 分片健康自检（设置 → 诊断 → 分片健康自检）；检查每个账户的 keychain 分片是否可读取，提前发现丢失 / 损坏
- **iOS**: 空钱包详情页 CTA 卡片（零余额时引导复制地址、显示 QR、添加代币）

## [0.3.0-dev.36] - 2026-04-18

### Added

- **iOS**: 交易历史导出 CSV（菜单里的"导出 CSV"，遵循当前筛选条件，UTF-8 带 BOM 兼容 Excel）
- **iOS**: 交易历史顶部改为菜单（刷新 / 导出）

## [0.3.0-dev.35] - 2026-04-18

### Added

- **iOS**: 交易确认后自动推送本地通知（接入已有的 `TransactionConfirmationPoller`）
- **iOS**: 交易详情页显示 USD 金额（基于 `PriceService` 已缓存行情）

## [0.3.0-dev.34] - 2026-04-18

### Added

- **iOS**: BTC / LTC 真实 RBF 加速——在待确认交易详情页一键发起替换交易，自动预填收款人/金额并跳到 Fast 费率档；广播成功后原交易在本地历史中标记为已被替换

### Fixed

- **iOS**: `TransactionStore.withUpdatedHash` 在更新哈希时丢失 `confirmedAt` 的潜在 bug

## [0.3.0-dev.32] - 2026-04-18

### Added

- **iOS**: ERC-20 交易历史同步（Etherscan V2 `tokentx`，所有 EVM 链）
- **iOS**: 自定义代币添加 / 删除 UI；支持手动填写或链上 `name()` / `symbol()` / `decimals()` 自动查询
- **iOS**: 签名前生物识别门禁开关（可选，设置里切换）

## [0.3.0-dev.31] - 2026-04-18

### Added

- **iOS**: 钱包重命名 / 本机删除菜单（保留分片）
- **iOS**: 交易历史分状态分段筛选（全部 / 待确认 / 已确认 / 失败）+ 地址/哈希/金额搜索
- **iOS**: 收款 QR 支持请求金额（BIP-21 / EIP-681 / Solana Pay）

## [0.3.0-dev.30] - 2026-04-18

### Added

- **iOS**: BTC / LTC 自定义 sat/vB 费率
- **iOS**: TRC-20 代币交易历史同步

### Changed

- **iOS**: `ExternalTx.deltaSmallest` / `feeSmallest` 由 `Int64`/`UInt64` 迁移至 `Decimal`，避免 >18 ETH 溢出

## [0.3.0-dev.29] - 2026-04-18

### Added

- **iOS**: EVM（Etherscan V2 多链）与 Solana（getSignaturesForAddress + getTransaction）交易历史同步
- **iOS**: Settings 新增 Etherscan API key 配置（Keychain 持久化）

## [0.3.0-dev.28] - 2026-04-18

### Added

- **iOS**: BTC / LTC / TRON 交易历史同步（通过 keyless 公共 explorer API）
- **iOS**: TransactionHistoryView 下拉刷新 + 手动同步按钮 + 结果提示

## [0.2.0] - 2026-04-16

### Added

- **MPC**: CGGMP21 threshold ECDSA for Secp256k1 (Kudelski-audited library)
- **MPC**: IETF FROST (RFC 9591) for Ed25519
- **Relay**: WebSocket relay server with per-IP rate limiting and room management
- **Relay**: `/health`, `/metrics` (Prometheus), `/admin/rooms` endpoints
- **Relay**: Room capacity limits (`max_rooms`) to prevent OOM DoS
- **Relay**: Structured tracing with `#[instrument]` spans
- **Relay**: Config env var clamping with warning logs
- **Core**: Noise Protocol XX E2E encryption for peer communication
- **Core**: AES-256-GCM shard encryption with HKDF key derivation
- **Core**: Session token generation with HKDF (returns `Result`)
- **Core**: Session TTL tracking with automatic cleanup
- **Core**: Bitcoin (BIP-143), EVM (EIP-1559), Solana transaction building
- **Core**: Constant-time comparisons via `subtle` crate
- **iOS**: Full SwiftUI app with MVVM architecture
- **iOS**: Secure Enclave device key + PBKDF2 PIN verification
- **iOS**: Certificate pinning (TOFU + pre-registered SPKI hashes)
- **iOS**: Anti-debug / jailbreak detection
- **iOS**: BLE, Wi-Fi LAN, Wi-Fi Direct, QR, and Relay transport layers
- **iOS**: Shard backup/restore with QR export
- **iOS**: Multi-chain wallet management (ETH, SOL, BTC)
- **iOS**: Transaction signing with threshold co-signing ceremony
- **iOS**: Accessibility support (`@ScaledMetric`, Dynamic Type, VoiceOver labels)
- **iOS**: Localization framework (L10n) with i18n-ready strings
- **iOS**: Background state cleanup (zeroes sensitive memory)
- **iOS**: `PrivacyInfo.xcprivacy` for App Store compliance
- **Infra**: Dockerfile with multi-stage build, non-root user, health check
- **Infra**: CI pipeline (tests, clippy, fmt, cargo-audit, coverage, iOS build)
- **Docs**: Architecture, MPC protocol, security model, deployment guide (803 lines)

### Security

- Replaced custom constant-time comparisons with `subtle::ConstantTimeEq`
- HKDF `expect()` calls converted to proper `Result` error propagation
- `decrypt_shard()` returns `Zeroizing<Vec<u8>>` for automatic memory zeroing
- Mutex poison recovery changed to fatal `expect()` (fail-fast on corruption)
- Config `validate()` returns `Result<(), ConfigError>` instead of panicking
- LAContext explicitly invalidated after biometric operations
- TOFU pins stored with `AfterFirstUnlockThisDeviceOnly` Keychain protection
- NetworkConfig RPC validation uses pinned URLSession
- Room join uses atomic CAS for participant count (no TOCTOU race)
- Relay enforces `from == device_id` (prevents sender spoofing)
- Per-connection token-bucket rate limiting + per-IP connection throttling
- WebSocket origin validation (CSWSH protection)
- Replay protection via per-device sequence number tracking

### Fixed

- Eliminated all `fatalError`, `try!`, `as!` from iOS production code
- ECDSA public key serialization failure now logs error instead of silent empty string
- Config ping/pong timing validation (prevents mass disconnection)
- RPC retry with exponential backoff (3 attempts, 500ms→2s + jitter)

## [0.1.0] - 2026-03-01

### Added

- Initial project structure with workspace (horcrux-core, horcrux-relay, uniffi-bindgen)
- Basic MPC keygen and signing (Feldman VSS Schnorr)
- UniFFI bindings for iOS
- Skeleton iOS app

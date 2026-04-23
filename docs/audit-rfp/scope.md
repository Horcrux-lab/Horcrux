# Audit Scope

**Review tag**: `v0.5.0-rc.2` (subject to bump if further fixes land
before the audit starts — the final tag will be frozen at kickoff).

## In scope

### Cryptographic protocols

| Module | Path | What to review |
|---|---|---|
| **CGGMP21 threshold ECDSA** | `horcrux-core/src/mpc/ecdsa.rs`, `mpc/refresh.rs` | State-machine correctness, share-secrecy preservation, key-refresh protocol integrity, Paillier-proof handling. Upstream library: `cggmp21` (pinned — see `Cargo.lock`). |
| **FROST (Ed25519)** | `horcrux-core/src/mpc/frost.rs` | IETF FROST compliance (RFC 9591), round-2 package handling, commitment binding. Upstream library: `frost-core` / `frost-ed25519` (pinned). |
| **Feldman VSS / Schnorr DKG** | `horcrux-core/src/mpc/keygen.rs`, `mpc/signing.rs` | Legacy secp256k1 DKG retained as a compatibility path; review for deprecation safety and share-recovery correctness. |
| **Noise XX transport** | `horcrux-core/src/transport/e2e.rs` + `ios/Horcrux/Transport/*.swift` | Handshake correctness, payload-length framing, replay / truncation behaviour, peer-identity binding across reconnects. |
| **Shard encryption** | `horcrux-core/src/shard/crypto.rs` | HKDF-Expand domain separation, AES-256-GCM parameter bounds, salt/nonce freshness, wrong-PIN / wrong-DK constant-time behaviour. |

### Transaction signing surfaces

| Chain | Path | Focus |
|---|---|---|
| EVM (Ethereum + EVM-compatible) | `horcrux-core/src/chain/evm.rs` | RLP encoding, EIP-155 chain-id binding, EIP-1559 fee fields, calldata decoder robustness. |
| Bitcoin (P2WPKH) | `horcrux-core/src/chain/bitcoin.rs` | BIP-143 sighash, UTXO-amount provenance verification (audit H9), script construction. |
| Solana | `horcrux-core/src/chain/solana.rs` | Ed25519 signing via FROST, message-hash binding. |
| Tron (read-only, address derivation) | `horcrux-core/src/chain/tron.rs` | Base58Check round-trip, no-signing guarantee. |
| Litecoin (read-only, address derivation) | `horcrux-core/src/chain/litecoin.rs` | Prefix + Base58 correctness. |

### Relay service

| Path | Focus |
|---|---|
| `horcrux-relay/src/ws.rs` | WebSocket framing, size limits, rate-limiting, origin enforcement (CSWSH). |
| `horcrux-relay/src/room.rs` | Sequence-number replay protection, per-room participant bounds, TTL sweep. |
| `horcrux-relay/src/ip_ratelimit.rs` | Sliding-window fairness, eviction policy. |
| `horcrux-relay/src/config.rs` | `RELAY_ADMIN_TOKEN` exposure gate, `/metrics` / `/admin/*` allowlist. |
| `Caddyfile` + `scripts/relay-smoke.sh` | TLS termination, HSTS, Prometheus ACL. |

### iOS application

- Secure Enclave usage (`ios/Horcrux/Security/SecureKeyVault.swift`,
  `SecureKeyStore.swift`).
- Biometric gates (Face ID / Touch ID) for shard unwrap.
- Certificate pinning (`CertificatePinner.swift`) — TOFU model.
- Anti-debug / anti-simulator checks.
- Sensitive-log redaction (`SecureLog.swift`).
- Background / lockscreen screenshot suppression.
- Keychain ACL and `kSecAttrAccessible*` choices.
- Transaction preview UI — the "display what you sign" guarantee.
- **Audit log export** (`AuditExportView.swift`) — what bytes leave
  the device.

### Supply chain

- `deny.toml` policy (advisories / bans / licenses / sources).
- `Cargo.lock` vendor tree — no patches, no git deps other than the
  listed upstream `cggmp21` fork pinned by SHA.
- `ios/Horcrux/Core/Generated/horcrux_core.swift` — auto-generated
  UniFFI bindings; review for drift only.
- `Dockerfile` + base image provenance.
- Reproducible-build claim in `docs/reproducible-build.md`.

## Out of scope

- **dApp browser / WalletConnect / EIP-712 typed-data signing** —
  retired in round 18 (v0.5.0-rc.1 onwards). Horcrux only signs raw
  transfer transactions. Any audit finding in this direction should
  be marked "retired" and closed.
- **Apple platform weaknesses** — Face ID bypass, Secure Enclave
  breakage, iOS kernel CVEs, App Store review bypass. These are
  Apple's scope; we assume their primitives work as documented.
- **Physical device attacks beyond Secure Enclave** — cold-boot,
  decapping, fault injection. Out of our threat model
  (`docs/security-model.md §Adversary Model`).
- **DoS on the public relay** — rate-limiting is in scope but
  "attacker floods Layer 3 with 100 Gbps of UDP" is not.
- **Third-party block-explorer API correctness** — we assume their
  responses can be malicious and verify on-device (H9 closes this).
- **User-in-the-loop phishing** — "user scans a malicious QR code" is
  mitigated by the visual-verification requirement (`docs/security-model.md`);
  reviews should assume a *competent and attentive* cosigner.

## Explicit questions we want answered

1. **Rogue-party identity binding (audit C1)** — do the round-17 iOS
   triad tests + round-19 Rust proptest together cover every
   practical attacker reachable via a compromised first-contact
   channel? See `docs/security-audit-2026-04.md §C1`.
2. **CGGMP21 pinning** — is the pinned fork / SHA of the upstream
   library still the most conservative choice given any CVEs disclosed
   during the audit window?
3. **PSBT trust-the-amount footgun (audit H9)** — have we closed every
   code path where a malicious PSBT producer can lie about input
   `value`? The mitigation is opt-in for back-compat callers.
4. **iOS Secure Enclave migration** — can an attacker force the SWK
   to re-derive without biometric re-auth?
5. **Relay poisoning** — if the relay operator is malicious, what's
   the maximum damage? We claim zero-knowledge at the payload level
   (everything is Noise ciphertext); please try to break that claim.

## Artefacts to review alongside the code

- `docs/security-audit-2026-04.md` — self-audit, ~430 lines.
- `docs/security-model.md` — threat model and security goals.
- `docs/mpc-protocol.md` — protocol description.
- `docs/architecture.md` — system diagram, trust zones.
- `docs/code-tour.md` — entry-point map, §7 fuzz+proptest register.
- `CHANGELOG.md` — full history since `v0.3.0`.
- `SECURITY.md` — disclosure policy (firm must honour during audit).
- `horcrux-core/fuzz/README.md` — coverage-guided harness instructions.

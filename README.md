# Horcrux — MPC Threshold Wallet

[![CI](https://github.com/Horcrux-lab/Horcrux/actions/workflows/ci.yml/badge.svg)](https://github.com/Horcrux-lab/Horcrux/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/Horcrux-lab/Horcrux/branch/main/graph/badge.svg)](https://codecov.io/gh/Horcrux-lab/Horcrux)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Rust 1.80+](https://img.shields.io/badge/Rust-1.80%2B-orange.svg)](https://www.rust-lang.org)
[![Version](https://img.shields.io/badge/version-0.3.0-green.svg)](CHANGELOG.md)

> Your keys are your horcruxes. Split them. Guard them. No single point of failure.

Horcrux is a **face-to-face MPC (Multi-Party Computation) wallet** where private keys
never exist in complete form. Each key shard — a "horcrux" — lives on a separate device.
Transactions require **t-of-n** participants to cooperatively sign.

## Architecture

- **horcrux-core** — Rust library implementing MPC protocols (CGGMP21 / FROST),
  multi-chain tx building, and shard encryption. Exposes Swift & Kotlin bindings via UniFFI.
- **horcrux-relay** — Lightweight WebSocket relay for remote DKG and co-signing.
  All messages are E2E encrypted; the relay is a zero-knowledge dumb pipe.

See [docs/architecture.md](docs/architecture.md) for the full system design.

## MPC Protocols

| Chain | Curve | MPC Protocol | Reference |
|-------|-------|-------------|-----------|
| Ethereum / EVM | secp256k1 (ECDSA) | CGGMP21 | [Paper](https://eprint.iacr.org/2021/060) — Kudelski-audited impl |
| Bitcoin | secp256k1 (ECDSA) | CGGMP21 | Same |
| Solana | ed25519 (EdDSA) | FROST | [RFC 9591](https://www.rfc-editor.org/rfc/rfc9591) |

See [docs/mpc-protocol.md](docs/mpc-protocol.md) for protocol details and round counts.

## Communication Channels

| Channel | Use Case |
|---------|----------|
| BLE | Near-field device discovery and pairing |
| Wi-Fi Direct | P2P direct connection (no router needed) |
| Wi-Fi LAN | Same-network high-speed (mDNS auto-discovery) |
| QR Code | Parameter exchange, offline fallback (animated fountain codes) |
| Relay WS | Remote DKG and co-signing (E2E encrypted) |

All channels use **Noise Protocol** (Noise_XX_25519_ChaChaPoly_SHA256) for E2E encryption.

## Security

- Private keys **never exist** — MPC signing uses only shards.
- **Noise Protocol** E2E encryption with forward secrecy on all channels.
- **AES-256-GCM** shard encryption at rest (PIN-derived key via HKDF).
- **Secure Enclave** — device key sealed via ECIES (P-256 hardware ECDH).
- **PBKDF2** PIN hashing (100k iterations HMAC-SHA256 + random salt).
- **Certificate pinning** (SPKI SHA-256) on all RPC endpoints.
- **Traffic padding** — message bucket sizes + timing jitter.
- **Anti-debug** — ptrace denial + environment checks (release builds).
- **Zero-knowledge relay** — server forwards ciphertext only.
- **Identifiable abort** — malicious participants are detected.
- **MPC secret zeroization** — Drop impls zero all key material on session end.
- **Replay protection** — per-device sequence numbers reject out-of-order messages.
- **IP rate limiting** — per-IP connection throttle with auto-eviction circuit breaker.
- **Jailbreak detection** — blocks DKG and signing on compromised devices.
- **CORS origin restriction** — relay rejects unauthorized WebSocket origins.
- **Config validation** — startup-time bounds checking with clamped env vars.

See [docs/security-model.md](docs/security-model.md) for the full threat model.

## iOS App Features

- **Multi-wallet** — create and manage wallets across Ethereum, Bitcoin, and Solana.
- **ERC-20 / SPL tokens** — view token balances with built-in token registry.
- **Transaction signing** — threshold co-signing with real-time progress UI.
- **Transaction history** — persistent local store with broadcast status tracking.
- **Offline signing** — queue transactions for later broadcast.
- **Shard backup/restore** — encrypted iCloud-ready shard export.
- **QR code** — scan-to-pay and receive address display with share sheet.
- **Fee estimation** — per-chain gas/fee preview before signing.
- **Push notifications** — signing request alerts via APNs, plus
  local notifications when a signing request sits idle with no
  co-signer joined for 60 seconds.
- **Siri & Shortcuts** — read-only voice intents for address
  lookup ("Copy my ETH address"), balance query ("How much do I
  have in Horcrux"), and receive QR. Signing is intentionally
  excluded — ceremonies always require a full app-open for
  biometrics + MPC round-trips.
- **Fault-aware RPC routing** — per-URL cooldown registry (30 min
  for auth failures, 5 min for transient errors) with automatic
  fallback across the user's configured endpoints plus a public
  free pool. Settings surfaces a per-endpoint red-dot badge and a
  self-hiding "Endpoints in cooldown" diagnostic panel with a
  Retry affordance for users who just fixed their API key.
- **Deep linking** — `horcrux://` URL scheme for sign requests.
- **VoiceOver accessibility** — full screen reader support.
- **Internationalization** — L10n-ready with locale-aware number formatting.
- **Background broadcast retry** — BGProcessingTask resends failed transactions.

## Building

```bash
# Build the workspace
cargo build

# Run all tests
cargo test --workspace

# Run clippy (expect 0 warnings)
cargo clippy --workspace

# Run the relay server
cargo run -p horcrux-relay
```

### iOS App

See [ios/README.md](ios/README.md) for full setup instructions.

```bash
cd ios
./build-rust.sh          # Cross-compile Rust → XCFramework
xcodegen generate        # Generate Xcode project
open Horcrux.xcodeproj   # Build & run (⌘R)
```

### Generate Mobile Bindings

```bash
# Generate Swift bindings
cargo run -p uniffi-bindgen generate \
  horcrux-core/uniffi/horcrux.udl \
  --language swift --out-dir ./generated/swift

# Generate Kotlin bindings
cargo run -p uniffi-bindgen generate \
  horcrux-core/uniffi/horcrux.udl \
  --language kotlin --out-dir ./generated/kotlin
```

## Project Status

| Phase | Status |
|-------|--------|
| 1. Core crypto (CGGMP21 + FROST) | ✅ Complete |
| 2. Relay server (Noise E2E) | ✅ Complete |
| 3. UniFFI mobile bindings | ✅ Complete |
| 4. iOS app (Swift/SwiftUI) | ✅ Complete |
| 5. Security hardening (7 rounds) | ✅ Complete |
| 6. Android app (Kotlin/Compose) | 🔜 Planned |

### Test Coverage

- **173+ Rust tests** (123 core + 36 relay + 14 bindgen) — 0 clippy warnings
- **19 Swift test files** — ViewModels, services, security, crypto

## CI/CD

GitHub Actions runs on every push and PR:
- **Rust**: `cargo test` + `cargo clippy` + `cargo fmt --check` + `cargo audit`
- **Rust coverage**: `cargo-tarpaulin` with Codecov upload
- **iOS**: Xcode build + unit tests on simulator

## Documentation

Full index: [docs/README.md](docs/README.md).

- [Architecture](docs/architecture.md) — system design, module overview, data flow
- [MPC Protocol](docs/mpc-protocol.md) — CGGMP21 and FROST protocol details
- [Security Model](docs/security-model.md) — threat model, mitigations, trust assumptions
- [Security audit record](docs/security-audit-2026-04.md) — round-by-round close-out of 28 C/H/M/L findings

## License

MIT

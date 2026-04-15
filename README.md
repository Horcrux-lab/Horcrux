# Horcrux — MPC Threshold Wallet

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
- **AES-256-GCM** shard encryption at rest (PIN-derived key).
- **Zero-knowledge relay** — server forwards ciphertext only.
- **Identifiable abort** — malicious participants are detected.

See [docs/security-model.md](docs/security-model.md) for the full threat model.

## Building

```bash
# Build the workspace
cargo build

# Run all tests (109 tests: 90 core + 19 relay)
cargo test --workspace

# Run the relay server
cargo run -p horcrux-relay
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
| 4. iOS app (Swift/SwiftUI) | 🔜 Planned |
| 5. Android app (Kotlin/Compose) | 🔜 Planned |

## Documentation

- [Architecture](docs/architecture.md) — system design, module overview, data flow
- [MPC Protocol](docs/mpc-protocol.md) — CGGMP21 and FROST protocol details
- [Security Model](docs/security-model.md) — threat model, mitigations, trust assumptions

## License

MIT

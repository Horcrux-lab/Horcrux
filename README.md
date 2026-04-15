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

## Communication Channels

| Channel | Use Case |
|---------|----------|
| BLE | Near-field device discovery and pairing |
| Wi-Fi Direct | P2P direct connection (no router needed) |
| Wi-Fi LAN | Same-network high-speed (mDNS auto-discovery) |
| QR Code | Parameter exchange, offline fallback (animated fountain codes) |
| Relay WS | Remote DKG and co-signing (E2E encrypted) |

## Supported Chains

| Chain | Curve | MPC Protocol |
|-------|-------|-------------|
| Ethereum / EVM | secp256k1 (ECDSA) | CGGMP21 |
| Bitcoin | secp256k1 (ECDSA) | CGGMP21 |
| Solana | ed25519 (EdDSA) | FROST |

## Building

```bash
# Build the workspace
cargo build

# Run tests
cargo test

# Run the relay server
cargo run -p horcrux-relay
```

## License

MIT

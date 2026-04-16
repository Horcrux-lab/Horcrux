# Horcrux Architecture

## Overview

Horcrux is a threshold-signature MPC wallet where private keys **never exist in
complete form**. Each key is split into *n* shards across devices; any *t* of
those shards can cooperate to produce a valid signature without ever
reconstructing the key.

```
┌──────────────────────────────────────────────────┐
│                  Mobile App (iOS / Android)        │
│  ┌──────────┐  ┌──────────┐  ┌────────────────┐  │
│  │  Wallet   │  │  Signing │  │  Shard Manager │  │
│  │  Manager  │  │  Session │  │  (backup/PIN)  │  │
│  └─────┬─────┘  └────┬─────┘  └───────┬────────┘  │
│        └──────────────┼────────────────┘           │
│                       │                            │
│  ┌────────────────────┴───────────────────────┐    │
│  │            Transport Abstraction            │    │
│  │  BLE │ Wi-Fi Direct │ Wi-Fi LAN │ QR │ WS  │    │
│  └────────────────────┬───────────────────────┘    │
│                       │                            │
│  ┌────────────────────┴───────────────────────┐    │
│  │     horcrux-core  (Rust, via UniFFI)        │    │
│  │  CGGMP21 · FROST · Chain builders · Shard  │    │
│  └────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────┐
│           horcrux-relay  (optional)               │
│   Axum WebSocket relay — forwards E2E-encrypted   │
│   messages between devices. Cannot decrypt.       │
└──────────────────────────────────────────────────┘
```

## Workspace Layout

```
Horcrux/
├── horcrux-core/          # Rust library crate
│   ├── src/
│   │   ├── lib.rs         # crate root + UniFFI scaffolding
│   │   ├── ffi.rs         # UniFFI proc-macro bindings
│   │   ├── mpc/           # MPC protocols
│   │   │   ├── ecdsa.rs   # CGGMP21 (secp256k1) DKG + signing
│   │   │   ├── frost.rs   # IETF FROST (ed25519) DKG + signing
│   │   │   ├── session.rs # SessionManager — dispatches per curve
│   │   │   ├── keygen.rs  # Legacy Feldman VSS keygen
│   │   │   ├── signing.rs # Legacy threshold Schnorr signing
│   │   │   └── types.rs   # MpcMessage, KeygenResult, SigningResult
│   │   ├── chain/         # Transaction builders
│   │   │   ├── evm.rs     # RLP-encoded EVM transactions
│   │   │   ├── bitcoin.rs # Bitcoin PSBT builder
│   │   │   └── solana.rs  # Solana transaction builder
│   │   ├── shard/         # Shard management & encryption
│   │   │   ├── storage.rs # ShardManager — list, import, delete
│   │   │   └── crypto.rs  # AES-256-GCM shard encryption (PIN-derived)
│   │   └── transport/     # Communication primitives
│   │       ├── e2e.rs     # Noise Protocol (Noise_XX_25519_ChaChaPoly_SHA256)
│   │       └── protocol.rs# Message types (TransportMessage, Handshake, etc.)
│   ├── uniffi/
│   │   └── horcrux.udl    # FFI interface reference (documentation)
│   └── build.rs
│
├── horcrux-relay/         # Binary crate — relay server
│   ├── src/
│   │   ├── main.rs        # Axum bootstrap, /health, /metrics
│   │   ├── ws.rs          # WebSocket upgrade + message routing
│   │   ├── room.rs        # Room lifecycle, token-gating, expiry
│   │   ├── config.rs      # Server configuration
│   │   └── metrics.rs     # Prometheus-style counters
│   └── Dockerfile
│
└── docs/                  # You are here
```

## Module Details

### horcrux-core

| Module | Responsibility |
|--------|---------------|
| `mpc::ecdsa` | CGGMP21 4-round DKG + 4-round signing for secp256k1 (EVM, BTC). Computes recovery_id for EVM `ecrecover`. |
| `mpc::frost` | IETF FROST (RFC 9591) 3-part DKG + 2-round signing for ed25519 (Solana). |
| `mpc::session` | `SessionManager` dispatches `create_keygen` / `create_signing` to the correct protocol based on `CurveType`. |
| `chain::evm` | Builds RLP-encoded EVM transactions, derives addresses from secp256k1 public keys via Keccak-256. |
| `chain::bitcoin` | Constructs Bitcoin transactions (PSBT format, P2PKH and P2WPKH). |
| `chain::solana` | Builds Solana transactions with ed25519 signatures, derives base58 addresses. |
| `shard::storage` | `ShardManager` — in-memory shard store with import/export/delete. |
| `shard::crypto` | AES-256-GCM encryption of shards. Key derived from PIN via HKDF-SHA256. |
| `transport::e2e` | Noise Protocol E2E encryption. 3-message handshake → encrypted transport. |
| `ffi` | UniFFI proc-macro bridge — adapts all internal types for Swift/Kotlin consumption. |

### horcrux-relay

| Module | Responsibility |
|--------|---------------|
| `ws` | Handles WebSocket connections, authenticates into rooms, routes messages between devices. |
| `room` | Room lifecycle: create (with optional token), join, leave, broadcast. Configurable expiry TTL. |
| `config` | Server parameters: max rooms, max participants per room, timeouts. |
| `metrics` | Connection and message counters for operational monitoring. |

## Key Dependencies

| Crate | Version | Purpose |
|-------|---------|---------|
| `cggmp21` | 0.6 | Kudelski-audited CGGMP21 ECDSA (state-machine mode) |
| `frost-ed25519` | 2.2 | IETF RFC 9591 FROST for ed25519 |
| `snow` | 0.10 | Noise Protocol Framework (XX pattern) |
| `k256` | 0.13 | secp256k1 curve operations, ECDSA verify for recovery_id |
| `generic-ec` | 0.4 | Elliptic curve abstraction used by cggmp21 |
| `uniffi` | 0.28 | FFI binding generation for Swift / Kotlin |
| `axum` | 0.7 | Async web framework for relay server |
| `tokio` | 1.x | Async runtime |

## Data Flow

### Distributed Key Generation (DKG)

```
Device A                    Device B                    Device C
   │                           │                           │
   ├─ create_keygen() ─────────┤                           │
   │                           ├─ create_keygen() ─────────┤
   │                           │                           │
   │◄── MpcMessage round 1 ──►│◄── MpcMessage round 1 ──►│
   │◄── MpcMessage round 2 ──►│◄── MpcMessage round 2 ──►│
   │         ...               │         ...               │
   │                           │                           │
   ├─ KeygenResult ────────────┤                           │
   │  (shard + group_pubkey)   ├─ KeygenResult ────────────┤
```

Messages are exchanged via **any** transport (BLE, Wi-Fi, QR, or Relay).
All messages are E2E encrypted — the relay server (if used) sees only ciphertext.

### Threshold Signing

```
Device A                    Device B
   │                           │
   ├─ create_signing(msg) ─────┤
   │                           │
   │◄── MpcMessage rounds ───►│
   │                           │
   ├─ SigningResult ───────────┤
   │  (signature + recovery_id)│
```

Only *t* of *n* devices need to participate.

## Security Boundaries

1. **horcrux-core** — runs entirely on-device. No network access. All secrets
   stay in process memory (zeroized on drop where possible).
2. **Transport layer** — all inter-device messages are encrypted with Noise_XX.
   The relay server is **zero-knowledge** — it cannot read message contents.
3. **Shard storage** — shards at rest are AES-256-GCM encrypted. The key is
   derived from a user PIN via HKDF, ideally combined with hardware keystore.

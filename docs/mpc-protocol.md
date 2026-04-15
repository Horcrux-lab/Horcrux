# MPC Protocol Design

## Protocol Selection

| Chain | Signature | MPC Protocol | Crate | Reference |
|-------|-----------|-------------|-------|-----------|
| EVM (ETH, Polygon…) | ECDSA / secp256k1 | **CGGMP21** | `cggmp21` 0.6.3 | [Canetti et al. 2021](https://eprint.iacr.org/2021/060) |
| Bitcoin | ECDSA / secp256k1 | **CGGMP21** | `cggmp21` 0.6.3 | Same paper |
| Solana | EdDSA / ed25519 | **FROST** | `frost-ed25519` 2.2 | [RFC 9591](https://www.rfc-editor.org/rfc/rfc9591) |

**Why two protocols?** ECDSA and EdDSA have fundamentally different algebraic
structures. CGGMP21 is the state-of-the-art for threshold ECDSA; FROST is the
IETF standard for threshold Schnorr / EdDSA.

---

## CGGMP21 — Threshold ECDSA

### Overview

CGGMP21 (*Canetti, Gennaro, Goldfeder, Makriyannis, Peled — 2021*) is the
latest generation of threshold ECDSA. Key properties:

- **Identifiable abort**: if a party cheats, the honest parties learn *who*.
- **No trusted dealer**: fully distributed key generation.
- **UC-secure**: proven secure under Universal Composability.
- **Audited**: the `cggmp21` crate was audited by Kudelski Security.

### DKG (Distributed Key Generation)

DKG runs as **two sequential sub-protocols**:

#### 1. Key Generation (4 rounds)

Each party *i* generates a secret share *xᵢ* such that the implicit full key
*x = Σ xᵢ* is never reconstructed. At the end, every party holds:

- Their secret share *xᵢ*
- The group public key *X = x·G*
- Commitments to verify other parties' shares

#### 2. Auxiliary Info Generation (3 rounds)

Generates the Paillier encryption keys and ring-Pedersen parameters needed for
the zero-knowledge proofs in signing. This involves generating safe primes,
which is computationally expensive (~1–3 seconds per party).

```
Total DKG: 7 rounds of message exchange
```

### Signing (4 rounds)

Given a message hash *m* and threshold *t*, any *t* parties can sign:

1. **Round 1**: Each party broadcasts commitments to their nonce share.
2. **Round 2**: Parties exchange encrypted nonce shares via Paillier.
3. **Round 3**: Parties exchange partial signatures with ZK proofs.
4. **Round 4**: Combine partial signatures → `(r, s)` ECDSA signature.

The protocol outputs a standard ECDSA signature indistinguishable from a
single-signer signature. For EVM chains, we also compute the **recovery ID**
(*v* ∈ {0, 1}) needed for `ecrecover`:

```rust
// Try v=0 and v=1, compare recovered pubkey to group pubkey
for v in [RecoveryId::new(false), RecoveryId::new(true)] {
    let recovered = VerifyingKey::recover_from_prehash(msg, &sig, v);
    if recovered == group_public_key { return v; }
}
```

### Implementation Notes

- State machines use `Box::leak()` to satisfy cggmp21's `'static` lifetime
  requirements for `ExecutionId`, `OsRng`, and `KeyShare`.
- The `AnyDriver` trait is **not `Send`** (uses `Rc` internally). We wrap in
  `Mutex` and manually implement `Send + Sync` for the FFI layer.
- `PregeneratedPrimes::<SecurityLevel128>::generate(&mut OsRng)` is used for
  aux-info generation to amortize prime generation cost.

---

## FROST — Threshold EdDSA

### Overview

FROST (*Flexible Round-Optimized Schnorr Threshold signatures*) is the IETF
standard (RFC 9591) for threshold Schnorr and EdDSA signatures.

- **2-round signing**: faster than CGGMP21's 4 rounds.
- **IETF standard**: interoperable specification with test vectors.
- **Simple algebra**: Schnorr signatures are naturally linear → simpler MPC.

### DKG (3-Part Protocol)

FROST uses Pedersen's DKG adapted for the threshold setting:

```
All parties                          All parties
    │                                    │
    ├─ dkg::part1()                      │
    │  → Round1Package (commitment)      │
    │                                    │
    │──── broadcast Round1Packages ─────►│
    │                                    │
    │                    dkg::part2() ───┤
    │  ← Round2Package (per-party share) │
    │                                    │
    │◄──── send Round2Packages ──────────┤
    │                                    │
    ├─ dkg::part3()                      │
    │  → (KeyPackage, PublicKeyPackage)   │
```

- **Part 1**: Generate random polynomial, broadcast commitment.
- **Part 2**: Evaluate polynomial at each other party's index, send share.
- **Part 3**: Verify received shares, derive final key package.

### Signing (2 rounds)

```
Signers (t of n)                     Coordinator
    │                                    │
    ├─ round1::commit()                  │
    │  → (nonces, commitments)           │
    │                                    │
    │──── send commitments ─────────────►│
    │                                    │
    │◄─── signing_package ───────────────┤
    │                                    │
    ├─ round2::sign(signing_pkg, nonces) │
    │  → SignatureShare                  │
    │                                    │
    │──── send shares ──────────────────►│
    │                                    │
    │              aggregate(shares) ────┤
    │              → Signature           │
```

### Implementation Notes

- `Identifier` is created from `u16` via `try_into()`. Internally serialized
  as a little-endian Ed25519 scalar (32 bytes).
- `frost-ed25519` v2.2 requires `frost-core` v2.2 (must version-match).
- The `VerifyingKey` (group public key) is used directly as the Solana address
  (base58-encoded 32-byte Ed25519 point).

---

## Protocol Comparison

| Property | CGGMP21 (ECDSA) | FROST (EdDSA) |
|----------|----------------|---------------|
| DKG rounds | 7 (keygen 4 + aux 3) | 3 (single protocol) |
| Signing rounds | 4 | 2 |
| Identifiable abort | ✅ Yes | ✅ Yes |
| Trusted dealer | Not needed | Not needed |
| Curve | secp256k1 | ed25519 |
| ZK proofs | Paillier + range proofs | Schnorr (simpler) |
| Computation cost | Higher (safe primes) | Lower |
| Standard | Academic paper | IETF RFC 9591 |

## Message Format

All MPC messages use the same envelope:

```rust
pub struct MpcMessage {
    pub session_id: String,    // unique DKG/signing session
    pub from: u16,             // sender party index
    pub to: Option<u16>,       // None = broadcast, Some(i) = unicast
    pub round: u16,            // protocol round number
    pub payload: Vec<u8>,      // serialized protocol data
}
```

Messages are transported over any channel (BLE, Wi-Fi, QR, Relay). When using
the relay server, messages are additionally wrapped in a Noise Protocol
encrypted envelope — the relay cannot read `payload`.

## Why Not Presigning?

CGGMP21 supports an offline presigning phase that reduces online signing to
1 round. We **chose not to use it** because:

1. **Nonce reuse = key extraction**: if a presignature is accidentally used
   twice (same nonce *k* for two different messages), an attacker can compute
   the private key: `k = (m₁−m₂)/(s₁−s₂)`, then `x = (s₁·k−m₁)/r`.
2. **Face-to-face context**: our primary use case is devices in physical
   proximity — the extra latency of 4-round online signing is acceptable
   when communication is via BLE/Wi-Fi (milliseconds, not seconds).
3. **Simplicity**: fewer code paths = smaller attack surface.

Rust's move semantics (`self` consumption) on presignature types do prevent
compile-time reuse, but we prefer the defense-in-depth of not having
presignature state at all.

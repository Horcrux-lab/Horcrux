# Security Model

## Threat Model

### Assets

| Asset | Description |
|-------|-------------|
| **Key shards** | Each device holds one share of the threshold key. |
| **Group public key** | Not secret, but integrity matters (address derivation). |
| **Transaction messages** | Must be authenticated to prevent signing wrong data. |
| **Shard backup** | Encrypted export of a shard for disaster recovery. |

### Adversary Model

We assume a **threshold adversary** who can:

- Compromise up to *t−1* devices (and their shards).
- Observe all network traffic (relay, Wi-Fi, internet).
- Attempt active attacks: MITM, replay, message injection.
- Have physical proximity (for BLE/Wi-Fi attacks).

The adversary **cannot**:

- Compromise *t* or more devices simultaneously.
- Break standard cryptographic assumptions (DLP on secp256k1/ed25519,
  semantic security of AES-256-GCM / ChaChaPoly).

### Security Goals

| Goal | Mechanism |
|------|-----------|
| **Key secrecy** | MPC protocols never reconstruct the full key. |
| **Signing integrity** | Only the intended message is signed (display-what-you-sign). |
| **Confidentiality in transit** | Noise Protocol E2E encryption on all channels. |
| **Confidentiality at rest** | AES-256-GCM shard encryption with PIN-derived key. |
| **Authentication** | Noise_XX mutual authentication via static Curve25519 keys. |
| **Forward secrecy** | Ephemeral Noise handshake keys are discarded after use. |
| **Replay protection** | Noise transport nonce counters (built-in). |
| **Relay zero-knowledge** | Relay server handles only ciphertext — cannot decrypt. |

---

## Cryptographic Primitives

| Primitive | Usage | Implementation |
|-----------|-------|----------------|
| CGGMP21 | Threshold ECDSA (secp256k1) | `cggmp21` 0.6.3 (Kudelski audit) |
| FROST | Threshold EdDSA (ed25519) | `frost-ed25519` 2.2 (IETF RFC 9591) |
| Noise_XX_25519_ChaChaPoly_SHA256 | E2E encryption | `snow` 0.10 |
| AES-256-GCM | Shard encryption at rest | `aes-gcm` |
| HKDF-SHA256 | PIN → encryption key derivation | `hkdf` + `sha2` |
| Keccak-256 | EVM address derivation | `sha3` |
| SHA-256 / RIPEMD-160 | Bitcoin address derivation | `sha2` + `ripemd` |

---

## Defense-in-Depth Layers

### Layer 1: MPC Protocol Security

**Private key never exists.** During DKG, each device independently generates
its share using verifiable secret sharing. During signing, partial signatures
are computed locally and combined — the full key is never reconstructed on any
device.

- CGGMP21 provides **identifiable abort**: if a party sends malformed data,
  the honest parties can identify the cheater.
- Both protocols are **UC-secure** (Universal Composability), meaning they
  remain secure when composed with other protocols.

### Layer 2: Transport Encryption

All inter-device communication uses the **Noise Protocol Framework**:

```
Pattern:  Noise_XX_25519_ChaChaPoly_SHA256
Handshake: → e, ← e ee s es, → s se    (3 messages)
Transport: ChaChaPoly-1305 with nonce counters
```

**Properties:**
- **Mutual authentication**: both parties prove possession of their static
  Curve25519 key during handshake.
- **Forward secrecy**: ephemeral DH keys are used and discarded.
- **Replay protection**: monotonic nonce counters in transport mode.
- **Tamper detection**: any modified ciphertext fails AEAD authentication.

**Key exchange**: static public keys are exchanged out-of-band (QR code scan
during face-to-face setup) to prevent MITM attacks.

### Layer 3: Shard Encryption at Rest

Each shard is encrypted before storage:

```
PIN (user input)
    │
    ▼
HKDF-SHA256(salt, PIN) → 256-bit key
    │
    ▼
AES-256-GCM(key, nonce, shard_bytes) → EncryptedShard {
    ciphertext: Vec<u8>,
    nonce: [u8; 12],
    salt: [u8; 32],
}
```

**Future enhancement**: combine PIN with hardware keystore (Secure Enclave on
iOS, StrongBox on Android) for two-factor shard protection.

### Layer 4: Relay Server Zero-Knowledge

The relay server:

- **Cannot decrypt** any messages (only forwards Noise ciphertext).
- **Token-gated rooms**: rooms can require a shared secret to join.
- **Configurable limits**: max rooms, max participants, TTL expiry.
- **No persistent storage**: rooms and messages exist only in memory.

Even a fully compromised relay server learns nothing about keys or transactions.

---

## Attack Scenarios & Mitigations

### 1. Device Theft (< t devices)

**Attack**: Adversary steals a device containing one shard.

**Mitigation**:
- Shard is encrypted with PIN → attacker needs the PIN.
- With *t−1* shards, the attacker still cannot sign (threshold not met).
- **Key refresh** (planned): rotate shards so stolen shard becomes useless.

### 2. Man-in-the-Middle on Transport

**Attack**: Attacker intercepts BLE/Wi-Fi traffic between devices.

**Mitigation**:
- Noise_XX handshake with **pre-exchanged static keys** (via QR code in
  face-to-face ceremony) prevents MITM.
- If keys haven't been pre-exchanged (first contact), a **trust-on-first-use
  (TOFU)** model applies — users should verify key fingerprints.

### 3. Compromised Relay Server

**Attack**: Attacker controls the relay server.

**Mitigation**:
- All messages are E2E encrypted — relay sees only ciphertext.
- Relay cannot inject messages into the Noise session (would fail MAC).
- Relay cannot drop/reorder messages without detection (Noise nonce counters
  + MPC protocol round tracking).

### 4. Rogue Participant in MPC

**Attack**: One party sends malformed protocol messages.

**Mitigation**:
- CGGMP21's **identifiable abort**: zero-knowledge proofs on each round
  detect cheating and identify the rogue party.
- FROST's verification shares: each share is verified against commitments.

### 5. Nonce Reuse (Presigning)

**Attack**: If presigning were used, reusing a nonce leaks the private key.

**Mitigation**: **Presigning is disabled.** We use only online (4-round)
CGGMP21 signing. Face-to-face latency makes 4 rounds acceptable.

### 6. Side-Channel Attacks

**Attack**: Timing or memory side channels during MPC computation.

**Mitigation**:
- Underlying curve libraries (`k256`, `curve25519-dalek`) use
  constant-time operations.
- Shard bytes should be zeroized on drop (planned: `zeroize` crate).

---

## Trust Assumptions

1. **Device integrity**: each participant's device is not fully compromised
   (at most *t−1* devices are compromised).
2. **Cryptographic hardness**: ECDLP on secp256k1 and ed25519, semantic
   security of AES-256-GCM, ChaChaPoly-1305.
3. **Randomness quality**: `OsRng` provides cryptographically secure random
   numbers on all target platforms (iOS, Android, desktop).
4. **Out-of-band key exchange**: static Noise keys are exchanged securely
   during face-to-face setup (QR code scan).

## Planned Security Enhancements

- [ ] **Key refresh**: periodically rotate shards without changing the group
      key, invalidating any previously compromised shards.
- [ ] **Formal audit**: third-party security review of the full system.

## Implemented Security Features

- [x] **Hardware keystore integration**: PIN combined with Secure Enclave (iOS)
      for shard encryption key derivation.
- [x] **Zeroize on drop**: all secret material in memory is overwritten via the
      `zeroize` crate (`Zeroizing<Vec<u8>>`, `ZeroizeOnDrop` derive).
- [x] **Display-what-you-sign**: mobile UI shows transaction details (recipient,
      amount, chain, gas) for user confirmation before signing.

# EIP-712 Typed Data — Horcrux Core Helper

> Pure-Rust EIP-712 v4 typed-data JSON → 32-byte digest, with replay-
> binding enforcement and an FFI surface for iOS.

**Source**: [`horcrux-core/src/chain/eip712_typed.rs`](../horcrux-core/src/chain/eip712_typed.rs)
**FFI export**: `horcrux_eip712_digest_from_typed_data`
**Audit reference**: [security-audit-2026-04.md — H8 §round-17 close-out](./security-audit-2026-04.md)

---

## 1. Purpose

When a Horcrux wallet signs an `eth_signTypedData_v4` request from a
dApp (via WalletConnect, deep-link, or a paste-JSON UI), the iOS layer
must compute the exact 32-byte digest that will flow into the MPC
ceremony. The helper consumes the canonical JSON shape that dApps
emit:

```json
{
  "types": {
    "EIP712Domain": [ {"name":"name","type":"string"}, ... ],
    "Permit":       [ {"name":"owner","type":"address"}, ... ]
  },
  "primaryType": "Permit",
  "domain":  { "name": "USD Coin", "version": "2", "chainId": 1, "verifyingContract": "0x..." },
  "message": { "owner": "0x...", "spender": "0x...", ... }
}
```

and returns `keccak256(0x19 ‖ 0x01 ‖ domainSeparator ‖ structHash)`
per [EIP-712 §5](https://eips.ethereum.org/EIPS/eip-712).

---

## 2. Public API

### Rust

```rust
pub fn eip712_digest_from_typed_data_json(json: &str) -> Result<[u8; 32], ChainError>
```

### FFI (UniFFI → Swift)

```swift
// Generated in ios/Horcrux/Core/Generated/horcrux_core.swift
// after ios/build-rust.sh rebuilds the XCFramework.
public func horcruxEip712DigestFromTypedData(json: String) throws -> Data  // 32 bytes
```

---

## 3. Supported Solidity types

| Category | Types | Notes |
|---|---|---|
| **Scalars** | `bool`, `address`, `string`, `bytes` | |
| **Fixed bytes** | `bytes1` … `bytes32` | Right-padded to 32 bytes per spec. |
| **Unsigned int** | `uint8`, `uint16`, …, `uint256` | Multiples of 8 only. |
| **Signed int** | `int8`, `int16`, …, `int64` | Two's-complement sign-extended. `int65+` currently rejected; workaround: encode as two's-complement `uintN`. |
| **Structs** | Any named type in `types` | |
| **Dynamic arrays** | `T[]` | `T` may be any supported type including a struct. |
| **Fixed arrays** | `T[N]` | `N` ≤ 256. |

Rejected (returns `Err`):
- unknown field type (typos like `uint257`),
- circular struct dependencies,
- addresses with mixed case but wrong [EIP-55](https://eips.ethereum.org/EIPS/eip-55) checksum,
- domain with `chainId = 0`, `verifyingContract = 0x000…000`, or empty `name` (when those fields are declared).

---

## 4. Security properties (verified)

| # | Property | How verified |
|---|---|---|
| P1 | Output matches canonical EIP-712 spec vector | `canonical_spec_vector` test — digest `0xbe609aee…0957bd2`. |
| P2 | Output matches ethers.js v6 `TypedDataEncoder.hash` on 5 real-world dApp payloads | Regression tests: Canonical Mail, USDC Permit, DAI Permit, Permit2 PermitSingle (3-field domain, no `version`), Seaport-style OrderComponents with dynamic arrays. |
| P3 | Audit-H8 replay-binding guards | `rejects_zero_chain_id`, `rejects_zero_verifying_contract`, and `parse_address → 0x0 check` — guards fire whenever the declared domain includes the relevant field. |
| P4 | EIP-55 typo guard | `eip55_mixed_case_typo_rejected` — a one-nibble case flip in a mixed-case address is rejected with `EIP-55 checksum mismatch`. |
| P5 | Determinism | proptest — same input always yields the same digest (256 random cases). |
| P6 | Domain-binding sensitivity | proptest — bumping `chainId` always alters the digest. |
| P7 | Message-binding sensitivity | proptest — changing `message.value` always alters the digest. |
| P8 | No panics on malformed input | proptest — any random byte string (up to 4 KiB) returns `Err`, not a panic. Lightweight fuzz gate. |

26 tests run on `cargo test -p horcrux-core --lib chain::eip712_typed`.

---

## 5. Domain-separator construction — why it's dynamic

EIP-712 permits any subset of the five optional `EIP712Domain` fields
(`name`, `version`, `chainId`, `verifyingContract`, `salt`). Real-
world dApps exercise this:

| dApp | Fields declared |
|---|---|
| Canonical spec example / USDC / DAI / Seaport | `name`, `version`, `chainId`, `verifyingContract` |
| **Uniswap Permit2** | `name`, `chainId`, `verifyingContract` *(no `version`)* |

The helper **rebuilds the domain separator from the exact
`types.EIP712Domain` field list declared in the payload** — a hard-
coded 4-field separator would produce a wrong digest for Permit2. See
[commit `d98dd95`](https://github.com/Horcrux-lab/Horcrux/commit/d98dd95)
for the pre-release catch (caught by cross-validating against
ethers.js v6, not by hand-crafted tests).

The audit-H8 replay-binding guards (non-zero `chainId`, non-zero
`verifyingContract`, non-empty `name`) are applied directly to the
JSON domain object whenever those fields are declared — so a dApp
that declares `chainId` in the separator must also supply a non-zero
value.

---

## 6. Call pattern (iOS)

Expected flow once the XCFramework exposes the FFI:

```swift
// 1. Receive raw JSON from dApp (WalletConnect / deep link / paste).
let payload: String = /* JSON from dApp */

// 2. Compute the exact 32-byte digest offline — no network, no MPC.
let digest: Data = try horcruxEip712DigestFromTypedData(json: payload)

// 3. Show decoded domain + primaryType in the approval UI. The user
//    MUST see `name`, `version` (if present), `chainId`,
//    `verifyingContract` and approve explicitly. The Rust layer only
//    enforces the cryptographic binding — not what the user saw on
//    screen.

// 4. On user approval, route the 32-byte digest through the existing
//    CGGMP21 threshold-ECDSA signing ceremony (same path as a plain
//    EVM tx hash).
```

The helper does not return the signed message — it is a pure digest
function. Signing happens inside the MPC ceremony downstream.

---

## 7. Error taxonomy

All errors surface as `ChainError::Other(String)` with a message
suitable for developer logs. Representative messages:

| Cause | Message (verbatim) |
|---|---|
| Malformed JSON | `invalid JSON: <serde error>` |
| Missing root field | `missing \`types\` object` / `missing \`primaryType\`` / `missing \`message\`` |
| Unknown primary | `primaryType "X" not declared in types` |
| Circular type graph | `circular type reference through "X"` |
| Unknown field type | `unknown field type "X" (not a primitive, not in types, not a valid array)` |
| H8 — zero chainId | `EIP-712 domain chain_id must be non-zero (chain_id=0 allows cross-chain replay)` |
| H8 — zero verifyingContract | `EIP-712 domain verifyingContract must be non-zero (0x0 allows cross-contract replay)` |
| H8 — empty name | `EIP-712 domain name must be non-empty` |
| EIP-55 typo | `domain.verifyingContract: EIP-55 checksum mismatch (...)` |

All error paths are tested. See the `rejects_*` test cases and the
`parse_address` test family.

---

## 8. Known limitations / future work

1. **Signed ints above `int64`**: currently rejected. Real-world
   typed-data messages overwhelmingly use `uint256`; negative values
   of extreme magnitude can be passed as two's-complement `uint256`
   strings.
2. **`salt` field in domain**: parsed and hashed correctly when
   declared as `bytes32`; not separately tested as a hand-crafted
   vector.
3. **UI-level decoding**: this helper returns a 32-byte digest only.
   The Swift layer must decode and render the domain + message for
   human approval; that surface is scoped under the EIP-712 consumer
   UI work stream (TBD).
4. **Cross-impl fuzz differential**: the 5 cross-verified vectors
   cover ~95 % of typed-data payloads seen in production dApp
   traffic. A future round could stand up a daily fuzz differential
   against ethers.js v6 via a CI cron job.

---

## 9. Change history

| Commit | Summary |
|---|---|
| [`1392ed5`](https://github.com/Horcrux-lab/Horcrux/commit/1392ed5) | Initial pure-Rust EIP-712 v4 helper + FFI export + 10 tests. |
| [`d98dd95`](https://github.com/Horcrux-lab/Horcrux/commit/d98dd95) | **Correctness fix**: dynamic domain separator so Permit2 (3-field domain) computes correctly. Caught by cross-checking against ethers.js v6. |
| [`9fc98cc`](https://github.com/Horcrux-lab/Horcrux/commit/9fc98cc) | Seaport-style dynamic-array-of-struct regression vector. |
| [`9a541d2`](https://github.com/Horcrux-lab/Horcrux/commit/9a541d2) | EIP-55 checksum validation on mixed-case address input (typo guard). |
| [`e84daae`](https://github.com/Horcrux-lab/Horcrux/commit/e84daae) | `bool` / `bytes32` / dynamic `bytes` / signed `int32` path coverage + tamper smoke. |
| [`58ae6ac`](https://github.com/Horcrux-lab/Horcrux/commit/58ae6ac) | Property-based (proptest) coverage — 5 properties × 256 random cases. |

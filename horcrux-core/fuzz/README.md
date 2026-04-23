# Horcrux — cargo-fuzz harnesses

Coverage-guided fuzz targets for the attacker-reachable parsers /
deserializers in `horcrux-core`. These catch memory-safety, panic, and
state-machine bugs that unit tests + proptests can't exhaustively hit.

Every target has a companion **proptest** in the main crate that runs
on every CI build as a fast regression gate; this directory adds
libFuzzer coverage-guided exploration for deeper reach.

## Installing

```bash
cargo install cargo-fuzz              # one-time
rustup toolchain install nightly      # libFuzzer needs nightly
```

## Running

```bash
cd horcrux-core/fuzz
cargo +nightly fuzz run evm_calldata       # EVM calldata decoder
cargo +nightly fuzz run shard_decrypt      # shard backup deser + decrypt
cargo +nightly fuzz run noise_handshake    # Noise XX responder read path
cargo +nightly fuzz run mpc_payload        # MPC wire payload parsers (9 types)
```

Add `-- -max_total_time=300` to cap individual runs at 5 minutes.

## Targets

| Target | Entry point | Threat model |
|---|---|---|
| `evm_calldata` | `chain::evm::decode_evm_calldata` | UI previews attacker-supplied tx calldata |
| `shard_decrypt` | `serde_json::from_slice::<EncryptedShard>` + `decrypt_shard` | Malformed backup import |
| `noise_handshake` | `NoiseChannel::responder(...).read_handshake` | Network-delivered handshake bytes |
| `mpc_payload` | `serde_json::from_slice::<{SignRound1, SignRound2, Round1Broadcast, Round2Share, FrostDkg{Round1,Round2}, FrostSign{Round1,Round2}, EcdsaWireMsg}>` | Peer-delivered MPC wire payloads (9 parsers, selected by 1-byte tag) |

## Corpus

No seed corpus is checked into git. libFuzzer writes discovered inputs
into `fuzz/corpus/<target>/` as it runs — keep these locally, and
commit only minimized reproducer cases for regressions (under
`fuzz/regressions/<target>/`, referenced from the fix commit).

## What to do on a crash

1. `cargo +nightly fuzz run <target>` reproduces it against the
   captured artifact under `fuzz/artifacts/<target>/`.
2. File a security-sensitive issue via `SECURITY.md` — these reach
   maintainer-controlled routes, not the public tracker.
3. Land the fix + a unit test that reproduces the crash
   deterministically (don't rely on fuzz re-discovery).

## Rationale

See `docs/security-audit-2026-04.md` — fuzzing is listed as a
round-18 supply-chain / robustness posture item alongside
`cargo-deny`, the relay deploy smoke script, and property-based
round-trip tests.

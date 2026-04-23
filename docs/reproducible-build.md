# Reproducible Build

Horcrux's iOS Rust core (`horcrux-core` compiled into
`HorcruxCore.xcframework`) can be verified byte-for-byte against a
committed manifest. This lets auditors — and security-conscious users —
confirm that the binary shipping inside the IPA matches source.

## TL;DR

```bash
# Verify the working tree produces the committed artefact hashes.
scripts/verify-build.sh

# Maintainer: regenerate the manifest after a legitimate change.
scripts/verify-build.sh --update
```

A successful verification prints `✅ build matches committed manifest
(byte-identical)` and exits 0. A divergence prints a unified diff of
expected-vs-observed hashes and exits 1.

## What gets hashed

The manifest ([`reproducible-build.manifest`](reproducible-build.manifest))
covers:

| Artefact                                              | Determinism |
|-------------------------------------------------------|-------------|
| `horcrux_core.swift` (UniFFI-generated bindings)      | ✅ fully    |
| `horcrux_coreFFI.h`                                   | ✅ fully    |
| `horcrux_coreFFI.modulemap`                           | ✅ fully    |
| `libhorcrux_core.a` — iOS device slice (`ios-arm64`)  | ✅ on same host / toolchain |
| `libhorcrux_core.a` — simulator slice (`ios-arm64-simulator`) | ✅ on same host / toolchain |
| XCFramework `Info.plist`                              | ⚠️ excluded |

`Info.plist` is excluded from the hash set because
`xcodebuild -create-xcframework` emits its `AvailableLibraries` array
in non-deterministic order — the bytes differ run-to-run even when every
embedded binary is byte-identical. The plist's **structure** is still
verifiable:

```bash
plutil -p ios/Horcrux/Core/Frameworks/HorcruxCore.xcframework/Info.plist
```

…should list exactly two libraries with identifiers `ios-arm64` and
`ios-arm64-simulator`, each pointing at `libhorcrux_core.a`. Anything
else is a red flag.

## Toolchain

Reproducibility across runs is only guaranteed when the toolchain is
pinned. The currently-committed manifest was produced on:

```
Darwin arm64 — rustc 1.90.0 — Xcode 26.4
```

(See the metadata header at the top of
`docs/reproducible-build.manifest` for the active pin — the
`--update` subcommand captures it automatically.)

A different host OS, Rust version, or Xcode SDK may produce different
`libhorcrux_core.a` bytes. The generated Swift bindings + C header
remain deterministic regardless of host because UniFFI emits them from
the UDL schema using deterministic templates.

Across **the same** toolchain + committed tree, we have verified that
two sequential clean builds produce identical bytes for every file in
the manifest (see commit `a4…` — the `verify-build.sh` script's own
introduction). This means:

- Cargo's fingerprint cache invalidation in `build-rust.sh` works as
  intended — no stale cross-compile objects leak into a release build.
- Rust's static-lib output for the iOS targets is deterministic on
  modern toolchains (contrary to older reputation — `rustc >= 1.75`
  writes archive timestamps as zero).
- `uniffi-bindgen` generates stable Swift + C output for a given
  `horcrux-core` source snapshot.

## Caveats

- **Cross-host determinism is not yet verified.** The manifest should be
  reproduced on a second independent macOS host running the same
  pinned toolchain before external audit sign-off. Linux cross-build
  parity (via `cargo xbuild` or a zig/cctools toolchain) is
  post-audit work.
- **Dependencies are pinned via `Cargo.lock`**, but build-time macros
  (`uniffi_macros`, `thiserror-impl`, etc.) expand differently if a
  newer proc-macro host crate lands. Always build from a checked-out
  release tag, not `main`.
- **`gmp-mpfr-sys` is the largest non-Rust dependency** (MPFR+GMP C
  sources are compiled via `build.rs`). Our script carries a
  toolchain-fingerprint guard that purges its cross caches when the
  SDK changes; verify the purge is effective by running
  `scripts/verify-build.sh` immediately after an Xcode update.
- **IPA signing is out of scope** for this manifest. The XCFramework
  covered here is pre-signing. iOS code-signing adds per-build
  entropy that is covered by Apple's own transparency infrastructure
  (receipt validation), not here.

## Adding a reproducible-build CI check

To make a build-manifest divergence fail CI, add this step to
`.github/workflows/ci.yml` after the iOS xbuild step:

```yaml
- name: Reproducible-build check
  run: scripts/verify-build.sh
```

This is not currently wired up because CI's macOS runner has a
different Xcode SDK pin than the maintainer workstation. Unifying the
two pins is tracked for a follow-up PR.

<!--
Thanks for the contribution!

Before submitting, please confirm:
- [ ] Does NOT contain secrets / credentials / real mainnet keys.
- [ ] If this touches cryptography, MPC ceremonies, chain code, or
      the FFI boundary, the corresponding audit doc
      (docs/security-audit-2026-04.md) has been reviewed and
      updated if necessary.
- [ ] For security-sensitive changes, please follow SECURITY.md
      for the private disclosure path instead of opening a public PR.
-->

## What

Short description of the change. One paragraph is plenty.

## Why

What problem does this solve? Link to the issue this closes with
`Closes #NN` if applicable.

## How (approach / trade-offs)

Any non-obvious design decisions, rejected alternatives, or trade-offs.

## Verification

How did you verify this works? Include the exact commands you ran and
paste the green output (or summarize, e.g. "21/21 chain::eip712_typed
tests pass, clippy clean, workspace cargo test --workspace green").

- [ ] `cargo test --workspace` passes
- [ ] `cargo clippy --workspace --tests -- -D warnings` passes
- [ ] iOS Xcode test plan passes (if iOS change)
- [ ] CHANGELOG.md `[Unreleased]` has a new bullet (or N/A for pure
      refactors / docs / tests)
- [ ] Security-relevant changes cross-referenced in
      `docs/security-audit-2026-04.md`

## Screenshots / logs (if relevant)

<!-- Drop any before/after screenshots, log excerpts, or cross-impl
verification output here. -->

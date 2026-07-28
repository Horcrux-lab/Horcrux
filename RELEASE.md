# Release Checklist

This document captures the exact sequence for cutting a Horcrux
release. Follow it top-to-bottom; skipping a step has historically
produced unsigned artifacts, broken TOFU pins, or a CHANGELOG that
lies about what shipped.

> **Current state** — the repository is at `v0.5.0-rc.2`. The next
> tag will be either another `-rc.N` (if the audit turns up must-fix
> findings) or `v0.5.0` (if the audit passes clean). The procedure
> below is identical; pick the tag at step 3.

---

## 0 — Pre-flight

Run **every item**; do not skip on "but it was green yesterday":

```bash
cargo test --workspace --lib
cargo clippy --workspace --lib --tests -- -D warnings
cargo fmt --check
cargo deny check
cargo build --workspace --release
```

- [ ] `cargo test --workspace --lib` — all green
- [ ] `cargo clippy --workspace --lib --tests -- -D warnings` — zero
      warnings
- [ ] `cargo fmt --check` — exits 0
- [ ] `cargo deny check` — advisories / bans / licenses / sources all
      pass. If `advisories` fails, triage each CVE; do not cut the
      release on a vulnerable dep.
- [ ] `cargo build --workspace --release` — succeeds
- [ ] `./scripts/validate-codeowners.sh` — passes
- [ ] **Multi-party MPC suite green.** Dispatch it and wait — do not
      tag until it passes:

    ```bash
    prev=$(gh run list --workflow=mpc-e2e.yml --limit 1 --json databaseId -q '.[0].databaseId')
    gh workflow run mpc-e2e.yml

    # The dispatch returns before the run object exists. Poll until a
    # new id appears — otherwise `--limit 1` yields the PREVIOUS run,
    # and `gh run watch` exits 0 immediately on an already-green one.
    for _ in $(seq 60); do
      sleep 5
      run=$(gh run list --workflow=mpc-e2e.yml --limit 1 --json databaseId -q '.[0].databaseId')
      [ -n "$run" ] && [ "$run" != "$prev" ] && break
    done
    [ "$run" != "$prev" ] || { echo "dispatch never registered"; exit 1; }

    gh run watch "$run" --exit-status
    ```

    Runs the three `#[ignore]`d ceremonies in
    `horcrux-core/tests/multi_party_ecdsa.rs` (3-of-3 DKG + sign,
    3-of-3 refresh, 5-of-5 DKG + sign). Nothing else in CI covers
    proactive refresh at all, or CGGMP21 past n=2 through the real
    `SessionManager` — `cargo test --workspace` skips all three.
    Budget 30-50 min.

    > Run it **here**, not by relying on the tag trigger. The
    > workflow also fires on `v*` tags (excluding `-dev.N`), but by
    > then the tag exists, and a failure means deleting and
    > re-cutting it.

    Locally the equivalent is:

    ```bash
    cargo test -p horcrux-core --release --test multi_party_ecdsa -- \
      --ignored --nocapture --test-threads=1
    ```

    `--release` is required; a debug build is roughly an order of
    magnitude slower.

- [ ] No hand-written `TODO` / `FIXME` / `HACK` in `horcrux-core/src`
      or `horcrux-relay/src`
      (`git grep -nE '(TODO|FIXME|HACK)' horcrux-core/src horcrux-relay/src`
      should be empty).

## 1 — Freeze the changelog

Move everything under `## [Unreleased]` into a new versioned section.

```md
## [0.5.0] - YYYY-MM-DD
```

- [ ] `[Unreleased]` is now empty (keep the heading for the next cycle).
- [ ] New version heading uses ISO date `YYYY-MM-DD`.
- [ ] Entries are grouped in the KeepAChangelog order:
      `Added` → `Changed` → `Deprecated` → `Removed` → `Fixed` →
      `Security` → `Governance` → `Documentation`.

## 2 — Bump version strings

Every crate in the workspace, plus the UniFFI bindgen.

```bash
# Workspace version (inherited by horcrux-core, horcrux-relay)
#   Cargo.toml:[workspace.package].version
# UniFFI bindgen
#   uniffi-bindgen/Cargo.toml:[package].version
```

- [ ] `Cargo.toml` — `[workspace.package] version = "X.Y.Z"`
- [ ] `uniffi-bindgen/Cargo.toml` — `[package] version = "X.Y.Z"`
- [ ] Re-run `cargo build --workspace` so `Cargo.lock` updates.
- [ ] `ios/project.yml` — `CFBundleShortVersionString` set to the
      **`X.Y.Z` core only**, then `cd ios && xcodegen generate` to
      propagate into `Horcrux/Resources/Info.plist` and
      `Horcrux.xcodeproj` (both are tracked). Do not hand-edit the
      generated files.

    > Apple constrains `CFBundleShortVersionString` to at most
    > three dot-separated integers, so a prerelease tag such as
    > `0.5.0-rc.2` is **not** a legal value and is rejected at
    > submission. Strip the `-dev.N` / `-rc.N` suffix here and let
    > `CFBundleVersion` carry prerelease/build identity. Bump
    > `CFBundleVersion` only when a build is actually uploaded —
    > it must increase monotonically per upload and can never be
    > reused.

- [ ] README badges — the `version-` badge tracks the full version
      (suffix included; escape `-` as `--` for shields.io) and the
      `Rust N.NN+` badge matches `[workspace.package].rust-version`.
- [ ] Re-run pre-flight (§0) after the bump.

## 3 — Commit + tag

```bash
git add Cargo.toml Cargo.lock uniffi-bindgen/Cargo.toml CHANGELOG.md \
        ios/Horcrux/Info.plist
git commit -m "release: bump to X.Y.Z

Promote [Unreleased] to [X.Y.Z] in CHANGELOG; bump workspace +
uniffi-bindgen crate versions; sync iOS Info.plist.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git tag -a vX.Y.Z -m "Horcrux X.Y.Z"
git push origin main
git push origin vX.Y.Z
```

- [ ] Commit message uses the `release: bump to X.Y.Z` subject.
- [ ] Tag is **annotated** (`-a`), not lightweight.
- [ ] Both `main` and the tag are pushed.

## 4 — Reproducible-build verification

Publish the build-manifest evidence so users can reproduce the
artifacts byte-for-byte.

```bash
./scripts/verify-build.sh > build_out/vX.Y.Z.txt
git add build_out/vX.Y.Z.txt docs/reproducible-build.manifest
git commit -m "release: vX.Y.Z reproducible-build manifest ..."
git push origin main
```

- [ ] Hashes in `docs/reproducible-build.manifest` match what
      `verify-build.sh` emits on a clean container.
- [ ] Manifest covers: horcrux-core (release rlib), horcrux-relay
      binary, Dockerfile image digest, iOS XCFramework (if rebuilt).

## 5 — Relay container release

Only if relay code changed this release.

- [ ] `relay-image.yml` workflow built and tagged the image
      `ghcr.io/horcrux-lab/horcrux-relay:X.Y.Z`.
- [ ] Image digest recorded in `CHANGELOG.md` under the versioned
      section (so downstreams can pin by digest).
- [ ] `relay-smoke.yml` green on the new tag.

## 6 — iOS release (if bumping app store)

> **Blocker**: the Apple Developer Team ID and signing certificate
> live outside this repo. Only a maintainer with the credentials
> can run this step.

- [ ] Archive built in Xcode against the tagged commit.
- [ ] Notarization staple attached (`xcrun stapler validate`).
- [ ] TestFlight upload succeeds.
- [ ] Hash of the `.xcarchive` recorded in
      `docs/reproducible-build.manifest`.
- [ ] Certificate-pinner's TOFU database is **unchanged** — this is a
      client update, not a relay TLS rotation.

## 7 — GitHub release

```bash
gh release create vX.Y.Z \
  --title "Horcrux X.Y.Z" \
  --notes-file /dev/stdin << 'EOF'
## Highlights
- ...

## Security
- ...

(Copy from CHANGELOG § [X.Y.Z])
EOF
```

- [ ] Release body is a copy of the CHANGELOG versioned section.
- [ ] Any security-relevant changes carry the audit-finding ID
      (C1 / C5 / H9 / …) for downstream auditors.
- [ ] Reproducible-build txt attached as an asset.
- [ ] Relay Docker image digest referenced in the release body.

## 8 — Communication

- [ ] Security advisory posted for any finding that reached `High`
      or higher (per `SECURITY.md`).
- [ ] Disclosure lag honoured: 7 days for Critical, until-release
      for High, immediate for Medium/Low/Info (per
      `docs/audit-rfp/severity-rubric.md`).
- [ ] If relay TLS changed: users must reinstall or accept the new
      TOFU pin. This is a breaking change and MUST be called out in
      the release body.

## 9 — Post-release

- [ ] `## [Unreleased]` restored as the top section of `CHANGELOG.md`.
- [ ] Version bump for the next cycle (e.g. `0.5.0` → `0.6.0-dev.0`)
      if following the dev-series convention.
- [ ] Open a tracking issue for each deferred item (TODOs marked
      "post-vX.Y.Z" during the release freeze).

---

## Release-name conventions

| Tag pattern | Meaning |
|---|---|
| `vX.Y.Z-dev.N` | Rolling development snapshot. No stability promise. |
| `vX.Y.Z-rc.N` | Release candidate. API frozen; only critical fixes allowed before `vX.Y.Z`. |
| `vX.Y.Z` | Stable release. |

Only `rc.*` and final releases get GitHub Releases + Docker image
tags. `dev.*` tags live for CI reproducibility only.

## Emergency hotfix

Critical security fix on a released minor? Branch from the tag, not
main:

```bash
git checkout -b hotfix/0.5.1 vX.Y.Z
# fix + test
git tag -a vX.Y.1 -m "Horcrux X.Y.1 (hotfix: …)"
```

Then cherry-pick the fix onto `main` separately — never fast-forward
main onto a hotfix branch.
